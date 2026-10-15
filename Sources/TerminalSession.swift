import AppKit
import SwiftTerm

/// SwiftTerm's view is also its own delegate, so these overrides are where
/// Nocci learns that the screen changed and that the user typed. What the
/// emulator sends on its own (a cursor position, device attributes, a focus
/// report) arrives through `send(source: Terminal, ...)` first and is not the
/// user.
final class NocciTerminalView: LocalProcessTerminalView {
    var onScreenChange: (() -> Void)?
    var onUserInput: (() -> Void)?
    private var replying = false

    override func send(source: Terminal, data: ArraySlice<UInt8>) {
        replying = true
        defer { replying = false }
        super.send(source: source, data: data)
    }

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        if !replying { onUserInput?() }
        super.send(source: source, data: data)
    }

    override func rangeChanged(source: TerminalView, startY: Int, endY: Int) {
        super.rangeChanged(source: source, startY: startY, endY: endY)
        onScreenChange?()
    }

    /// Command-click on a link, or an OSC 8 hyperlink a program printed. Only
    /// web links open: SwiftTerm's default opens any scheme and any existing
    /// path, so a link reading https://… could run a downloaded script.
    override func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        NSWorkspace.shared.open(url)
    }
}

/// One cell of a session's screen as the mini view draws it. Each keeps its
/// grid column, so a glyph from a fallback font, which is rarely exactly one
/// cell wide, never shifts the rest of the row away from the cursor.
struct ScreenCell: Equatable {
    var column: Int
    /// 2 for a wide character such as an emoji.
    var width: Int
    var character: String
    var foreground: NSColor
    /// Nil is the terminal's own black.
    var background: NSColor?
    var bold: Bool
    var underline: Bool
}

/// One row of a session's screen, and the cursor's column when it is on it.
struct ScreenRow {
    var cells: [ScreenCell]
    var cursor: Int?
}

/// One tab's pseudo-terminal, child process and screen.
/// SwiftTerm keeps a terminal's screen inside its view, so the session owns
/// that view and the window only shows it. Main thread only.
final class TerminalSession: TerminalProcess, LocalProcessTerminalViewDelegate {
    let view: NSView
    let label: String
    var onChange: (() -> Void)?
    /// Set by the mini view showing this session.
    var onScreenChange: (() -> Void)? {
        get { terminalView.onScreenChange }
        set { terminalView.onScreenChange = newValue }
    }
    private(set) var markerSeen = false
    private(set) var exited = false
    private(set) var waitingSince: Date?
    /// The child's process ID, which is also its process group's.
    private(set) var processID: pid_t = 0
    var agentRunning: Bool { TerminalRules.agentRunning(markerSeen: markerSeen, exited: exited) }
    /// Something other than the idle shell holds the terminal: the agent, or
    /// an editor or server the user started after it.
    var programRunning: Bool {
        guard !exited, processID > 0 else { return false }
        let foreground = tcgetpgrp(ptyDescriptor)
        return agentRunning || (foreground > 0 && foreground != processID)
    }
    /// The pseudo-terminal's primary side, as Nocci holds it.
    var ptyDescriptor: Int32 { terminalView.process.childfd }
    private let terminalView: NocciTerminalView
    private let copy: (String) -> Void
    private let now: () -> Date

    static func live(_ start: TerminalStart, fontSize: Double, tab: UUID) -> TerminalProcess {
        let account = TerminalRules.accountShell(recordedShell(), runnable: FileManager.default.isRunnableFile(atPath:))
        let locale = TerminalRules.locale(identifier: Locale.current.identifier,
                                          available: { FileManager.default.fileExists(atPath: "/usr/share/locale/" + $0) })
        return TerminalSession(start: start, shell: TerminalRules.launchShell(account: account),
                               environment: TerminalRules.environment(base: ProcessInfo.processInfo.environment, start: start,
                                                                      accountShell: account, locale: locale, tab: tab),
                               fontSize: fontSize)
    }

    init(start: TerminalStart, shell: String, environment: [String], fontSize: Double,
         copy: @escaping (String) -> Void = TerminalSession.copyToPasteboard, now: @escaping () -> Date = Date.init) {
        terminalView = NocciTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 468))
        view = terminalView
        label = start.label
        self.copy = copy
        self.now = now
        terminalView.nativeBackgroundColor = .black
        terminalView.nativeForegroundColor = NSColor(white: 0.9, alpha: 1)
        terminalView.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        // Off by default in SwiftTerm; the mini view redraws from it.
        terminalView.notifyUpdateChanges = true
        let terminal = terminalView.getTerminal()
        terminal.silentLog = true
        terminal.registerOscHandler(code: TerminalRules.agentExitedCode) { [weak self] _ in self?.agentExited() }
        // Replaces SwiftTerm's own OSC 52 handling, which answers clipboard queries.
        terminal.registerOscHandler(code: 52) { [weak self] data in
            if let text = TerminalRules.clipboardText(osc52: Array(data)) { self?.copy(text) }
        }
        // Only a Codex tab asked for notifications. Claude
        // Code's waits come from hooks, and its OSC 9 keeps SwiftTerm's meaning.
        if start.agent == .codex {
            terminal.registerOscHandler(code: 9) { [weak self] data in self?.notified(Array(data)) }
        }
        terminalView.onUserInput = { [weak self] in self?.clearWait() }
        terminalView.processDelegate = self
        terminalView.startProcess(executable: shell, args: TerminalRules.arguments(prompt: start.prompt, agent: start.agent),
                                  environment: environment, execName: nil, currentDirectory: start.folder)
        processID = terminalView.process.shellPid
        // SwiftTerm's descriptor is inherited by every child forked later, so
        // a program in another tab could read and type into this one.
        if ptyDescriptor >= 0 { _ = fcntl(ptyDescriptor, F_SETFD, FD_CLOEXEC) }
        if !terminalView.process.running {
            exited = true
            terminalView.feed(text: TerminalRules.startFailure + "\r\n")
        }
    }

    func setFontSize(_ size: Double) {
        terminalView.font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    func clearWait() {
        guard waitingSince != nil else { return }
        waitingSince = nil
        onChange?()
    }

    func miniView() -> NSView { TerminalMiniView(session: self) }

    /// The user's key event, given to SwiftTerm's own key handling so Escape,
    /// arrows and control keys are encoded exactly as in the window.
    func forward(_ event: NSEvent) {
        terminalView.keyDown(with: event)
    }

    /// The pasteboard's text, bracketed when the program asked for that, as
    /// SwiftTerm's own paste does.
    func paste() {
        terminalView.paste(self)
    }

    /// The last `count` rows of the content, oldest first, with the cursor's
    /// column on its row. Read on demand; nothing is copied or kept.
    func screenRows(last count: Int) -> [ScreenRow] {
        let terminal = terminalView.getTerminal()
        let cursor = terminal.getCursorLocation()
        return shownRows(count).map { row in
            var cells: [ScreenCell] = []
            if let line = terminal.getLine(row: row) {
                for column in 0..<terminal.cols {
                    let cell = line[column]
                    // The second half of a wide character is an empty cell.
                    guard cell.width > 0 else { continue }
                    // The terminal resolves wide and combined characters the cell only points to.
                    let character = terminal.getCharacter(for: cell)
                    let style = cell.attribute.style
                    let bold = style.contains(.bold)
                    let foreground = Self.color(cell.attribute.fg, bright: bold)
                    let background = Self.color(cell.attribute.bg, bright: false)
                    let inverse = style.contains(.inverse)
                    var shown = inverse ? background ?? .black : foreground ?? Self.defaultForeground
                    if style.contains(.dim) { shown = shown.withAlphaComponent(0.6) }
                    cells.append(ScreenCell(column: column, width: Int(cell.width),
                                            character: character == "\0" ? " " : String(character),
                                            foreground: shown, background: inverse ? foreground ?? Self.defaultForeground : background,
                                            bold: bold, underline: style.contains(.underline)))
                }
            }
            return ScreenRow(cells: cells, cursor: cursor.y == row ? cursor.x : nil)
        }
    }

    /// The same rows as plain text, for VoiceOver.
    func screenText(last count: Int) -> String {
        let terminal = terminalView.getTerminal()
        return shownRows(count).compactMap {
            terminal.getLine(row: $0)?.translateToString(trimRight: true, skipNullCellsFollowingWide: true,
                                                         characterProvider: terminal.getCharacter(for:))
        }
        .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Hangs up the shell's process group and the foreground one, where an
    /// interactive shell runs the agent or a program under job control, and
    /// closes the pseudo-terminal. SwiftTerm stops watching the child once
    /// terminated, so the child is reaped here, and whatever is left in
    /// either group is killed once the two-second grace ends.
    func close() {
        guard !exited else { return }
        let group = processID
        let foreground = tcgetpgrp(ptyDescriptor)
        exited = true
        waitingSince = nil
        let groups = Set([group, foreground].filter { $0 > 0 })
        for member in groups { kill(-member, SIGHUP) }
        terminalView.process.terminate()
        guard group > 0 else { return }
        DispatchQueue.global(qos: .utility).async { TerminalSession.reap(group, groups: groups) }
    }

    static func reap(_ pid: pid_t, groups: Set<pid_t>, grace: TimeInterval = 2) {
        var status: Int32 = 0
        var reaped = false
        let deadline = Date().addingTimeInterval(grace)
        while Date() < deadline {
            if !reaped, waitpid(pid, &status, WNOHANG) != 0 { reaped = true }
            if reaped, groups.allSatisfy({ kill(-$0, 0) != 0 }) { return }
            usleep(50_000)
        }
        for group in groups { kill(-group, SIGKILL) }
        if !reaped { _ = waitpid(pid, &status, 0) }
    }

    static func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// The rows the mini view shows: up to `count`, ending at the content's
    /// bottom, which is the lower of the cursor row and the last row with
    /// text. An inline program such as Claude Code draws at the top of a
    /// mostly empty screen, where the screen's own bottom rows are blank.
    private func shownRows(_ count: Int) -> Range<Int> {
        let terminal = terminalView.getTerminal()
        let cursor = min(max(terminal.getCursorLocation().y, 0), terminal.rows - 1)
        var bottom = cursor
        for row in stride(from: terminal.rows - 1, to: cursor, by: -1) {
            if let line = terminal.getLine(row: row), !line.translateToString(trimRight: true).isEmpty {
                bottom = row
                break
            }
        }
        return max(0, bottom + 1 - max(count, 0))..<(bottom + 1)
    }

    static let defaultForeground = NSColor(white: 0.9, alpha: 1)

    /// SwiftTerm's default palette for the 16 ANSI colours, the 6x6x6 cube
    /// and the grey ramp for the rest; nil for the terminal's own default.
    /// Bold text uses the bright variant of the first eight, as SwiftTerm does.
    private static func color(_ color: Attribute.Color, bright: Bool) -> NSColor? {
        switch color {
        case .defaultColor, .defaultInvertedColor: return nil
        case .trueColor(let red, let green, let blue):
            return NSColor(red: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
        case .ansi256(let code):
            let index = bright && code < 8 ? Int(code) + 8 : Int(code)
            if index < 16 {
                let base = SwiftTerm.Color.defaultInstalledColors[index]
                return NSColor(red: CGFloat(base.red) / 65535, green: CGFloat(base.green) / 65535,
                               blue: CGFloat(base.blue) / 65535, alpha: 1)
            }
            if index < 232 {
                let cube = index - 16
                func level(_ value: Int) -> CGFloat { value == 0 ? 0 : CGFloat(55 + 40 * value) / 255 }
                return NSColor(red: level(cube / 36), green: level((cube / 6) % 6), blue: level(cube % 6), alpha: 1)
            }
            return NSColor(white: CGFloat(8 + 10 * (index - 232)) / 255, alpha: 1)
        }
    }

    private static func recordedShell() -> String? {
        guard let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell else { return nil }
        return String(cString: shell)
    }

    /// Only an arrival counts; the notification's text is never read or kept.
    private func notified(_ data: [UInt8]) {
        guard agentRunning, waitingSince == nil, TerminalRules.isNotification(osc9: data) else { return }
        waitingSince = now()
        onChange?()
    }

    private func agentExited() {
        guard !markerSeen else { return }
        markerSeen = true
        waitingSince = nil
        onChange?()
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        guard !exited else { return }
        exited = true
        waitingSince = nil
        terminalView.feed(text: "\r\n[Process completed]\r\n")
        onChange?()
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
}
