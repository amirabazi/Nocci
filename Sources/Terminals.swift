import CoreGraphics
import Foundation

/// What a new tab starts: the Projects inputs, plus the label the tab shows.
struct TerminalStart: Equatable {
    var folder: String
    var label: String
    var agent: ProjectAgent
    var program: String
    var prompt: String
}

/// Where a tab's session is shown.
enum TerminalPlace: Equatable { case window, notch }

/// Pure rules for Nocci's terminal window.
enum TerminalRules {
    /// A private OSC code the launch script writes when the agent exits.
    /// SwiftTerm ignores OSC codes it does not know, so it never shows.
    static let agentExitedCode = 7719
    static let fallbackShell = "/bin/zsh"
    /// The shells the launch script is tested under.
    static let launchShells: Set<String> = ["zsh", "bash", "sh", "fish"]
    static let defaultFontSize: Double = 13
    /// Fixed for a session shown in the notch; the window's size never applies there.
    static let notchFontSize: Double = 11
    static let fontSizes: ClosedRange<Double> = 9...24
    static let fontSizeKey = "terminal.fontSize"
    static let startFailure = "Couldn’t start the session."
    /// Codex's own terminal notifications, turned on for a Nocci tab only.
    /// Keys and values checked against codex-cli 0.155.0-alpha.16.3.
    static let codexNotificationFlags = "-c tui.notifications=true -c tui.notification_method=osc9 -c tui.notification_condition=always"
    /// Carries the tab's random ID to the child, and through Claude Code's
    /// hooks to `--claude-hook`.
    static let tabVariable = "NOCCI_TERMINAL_TAB"

    static func accountShell(_ recorded: String?, runnable: (String) -> Bool) -> String {
        guard let recorded, recorded.hasPrefix("/"), runnable(recorded) else { return fallbackShell }
        return recorded
    }

    static func launchShell(account: String) -> String {
        launchShells.contains((account as NSString).lastPathComponent) ? account : fallbackShell
    }

    /// Fixed text, valid in all four launch shells. The program and the prompt
    /// reach it only through the environment, so nothing typed is parsed as
    /// code, and `env -u` keeps both out of the agent's and the next shell's
    /// environment. An interactive zsh drops the rest of the script when the
    /// agent dies of Ctrl-C; the INT trap keeps it going, and the agent still
    /// gets the default Ctrl-C, since exec resets trapped signals.
    static func script(hasPrompt: Bool, agent: ProjectAgent = .claude) -> String {
        let clear = "env -u NOCCI_PROMPT -u NOCCI_AGENT"
        let flags = agent == .codex ? " " + codexNotificationFlags : ""
        let command = "\(clear) \"$NOCCI_AGENT\"\(flags)" + (hasPrompt ? " -- \"$NOCCI_PROMPT\"" : "")
        return "trap true INT; \(command); /usr/bin/printf '\\033]\(agentExitedCode);agent-exited\\007'; exec \(clear) \"$SHELL\" -l"
    }

    /// Login and interactive, so the shell reads the same startup files, and
    /// sets the same PATH, as a shell in Terminal.
    static func arguments(prompt: String, agent: ProjectAgent = .claude) -> [String] {
        ["-l", "-i", "-c", script(hasPrompt: !prompt.isEmpty, agent: agent)]
    }

    static func environment(base: [String: String], start: TerminalStart, accountShell: String, locale: String,
                            tab: UUID? = nil) -> [String] {
        var environment = base
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["SHELL"] = accountShell
        environment["NOCCI_AGENT"] = start.program
        environment["NOCCI_PROMPT"] = start.prompt.isEmpty ? nil : start.prompt
        environment[tabVariable] = tab?.uuidString
        // An app started from Finder has no locale, and agents draw UTF-8.
        if environment["LANG"] == nil && environment["LC_ALL"] == nil && environment["LC_CTYPE"] == nil {
            environment["LANG"] = locale
        }
        return environment.map { "\($0.key)=\($0.value)" }.sorted()
    }

    static func locale(identifier: String, available: (String) -> Bool) -> String {
        let base = String(identifier.prefix { $0 != "@" })
        let parts = base.split(separator: "_", omittingEmptySubsequences: false)
        let wellFormed = parts.count == 2 && parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy { $0.isASCII && $0.isLetter }
        }
        let candidate = base + ".UTF-8"
        return wellFormed && available(candidate) ? candidate : "en_US.UTF-8"
    }

    static func title(label: String, agent: ProjectAgent, agentRunning: Bool) -> String {
        agentRunning ? "\(label) · \(agent.title)" : label
    }

    static func agentRunning(markerSeen: Bool, exited: Bool) -> Bool { !markerSeen && !exited }

    static func clampedFontSize(_ value: Double?) -> Double {
        guard let value, value.isFinite, value > 0 else { return defaultFontSize }
        return min(max(value, fontSizes.lowerBound), fontSizes.upperBound)
    }

    static func closeQuestion(label: String, agent: ProjectAgent, agentRunning: Bool, programRunning: Bool = false) -> String? {
        if agentRunning { return "Close this tab? \(agent.title) is still running in \(label)." }
        return programRunning ? "Close this tab? A program is still running in \(label)." : nil
    }

    static func closeAllQuestion(running: Int) -> String? {
        running == 0 ? nil : "Close the window? \(sessions(running)) still running."
    }

    static func quitQuestion(running: Int) -> String? {
        running == 0 ? nil : "Quit Nocci? \(sessions(running)) still running."
    }

    static func startRefusal(folder: String?, folderExists: Bool, program: String?, prompt: String, agent: ProjectAgent) -> String? {
        guard folder != nil else { return "Choose a project or a folder." }
        guard folderExists else { return "This folder no longer exists." }
        guard program != nil else { return ProjectRules.missingProgram(agent) }
        return ProjectRules.refusal(for: prompt, agent: agent, target: .nocci)?.message(for: agent)
    }

    /// The text of an OSC 52 clipboard write, or nil. A query (`?`) is never
    /// answered, since that would hand the clipboard to whatever printed it.
    static func clipboardText(osc52 data: [UInt8]) -> String? {
        guard let separator = data.firstIndex(of: UInt8(ascii: ";")) else { return nil }
        let payload = Data(data[(separator + 1)...])
        guard payload != Data("?".utf8), let decoded = Data(base64Encoded: payload) else { return nil }
        return String(data: decoded, encoding: .utf8)
    }

    /// Whether an OSC 9 payload is a notification. SwiftTerm otherwise reads
    /// OSC 9 as a ConEmu progress report, `4;<state>;<percent>`, so that form
    /// is not one. The text itself is never read.
    static func isNotification(osc9 data: [UInt8]) -> Bool {
        guard !data.isEmpty else { return false }
        return !(data.count >= 2 && data[0] == UInt8(ascii: "4") && data[1] == UInt8(ascii: ";"))
    }

    private static func sessions(_ count: Int) -> String {
        count == 1 ? "1 session is" : "\(count) sessions are"
    }
}

/// Where the terminal window is.
enum TerminalPlacement: Equatable { case hidden, ordinary, dropped }

enum TerminalEvent {
    /// The notch button or Show Terminal / Hide Terminal.
    case summon
    /// The Dock, Cmd-Tab, or a session started elsewhere.
    case show
    /// Nocci stopped being the active app.
    case resign
    /// The user moved the window by its title bar.
    case drag
    /// The last tab closed.
    case empty
}

extension TerminalRules {
    static let dropDistance: CGFloat = 24

    static func placement(after event: TerminalEvent, from placement: TerminalPlacement) -> TerminalPlacement {
        switch (event, placement) {
        case (.summon, .dropped): return .hidden
        case (.summon, _): return .dropped
        case (.show, .dropped): return .dropped
        case (.show, _): return .ordinary
        case (.resign, .dropped): return .hidden
        case (.drag, .dropped): return .ordinary
        case (.empty, _): return .hidden
        default: return placement
        }
    }

    /// The window's frame is autosaved only while ordinary, so a dropped frame
    /// never replaces the one the user chose.
    static func savesFrame(_ placement: TerminalPlacement) -> Bool { placement == .ordinary }

    /// The frame to restore when the window is next ordinary: wherever the user
    /// last moved or resized it, taken as it leaves the ordinary place.
    static func ordinaryFrame(_ saved: CGRect, leaving placement: TerminalPlacement, current: CGRect) -> CGRect {
        placement == .ordinary ? current : saved
    }

    /// The ordinary size, shrunk to the screen, centred under the notch (or
    /// pill) and kept on screen, its top against the menu bar.
    static func droppedFrame(size: CGSize, visible: CGRect, anchor: CGRect) -> CGRect {
        let width = min(size.width, visible.width)
        let height = min(size.height, visible.height)
        let x = min(max(anchor.midX - width / 2, visible.minX), visible.maxX - width)
        return CGRect(x: x, y: visible.maxY - height, width: width, height: height)
    }

    /// Where a drop starts and a tuck ends: the same frame, slid up behind the
    /// menu bar. The size never changes, since resizing would resize the
    /// pseudo-terminal on every frame of the animation.
    static func dropStart(_ frame: CGRect) -> CGRect { frame.offsetBy(dx: 0, dy: dropDistance) }

    static func summonTitle(dropped: Bool) -> String { dropped ? "Hide Terminal" : "Show Terminal" }
}

/// A Codex tab that needs the user, as `TerminalModel`
/// publishes it for the Sessions list.
struct TerminalWait: Equatable {
    let tab: UUID
    let label: String
    let since: Date
}
