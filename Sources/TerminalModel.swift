import AppKit
import Combine

/// A tab's running session, as the model and the window see it.
/// `TerminalSession` is the real one; the model's tests use a fake.
protocol TerminalProcess: AnyObject {
    var view: NSView { get }
    var agentRunning: Bool { get }
    /// The agent, or any program other than the idle shell, holds the tab.
    var programRunning: Bool { get }
    /// When a Codex notification arrived and no key has been sent since.
    /// Always nil for Claude Code tabs, whose waits come from hooks.
    var waitingSince: Date? { get }
    /// Called when the agent ends, the process exits, or a wait begins or ends.
    var onChange: (() -> Void)? { get set }
    func setFontSize(_ size: Double)
    func clearWait()
    /// A fresh view of the bottom of this session's screen that forwards the
    /// user's keys.
    func miniView() -> NSView
    func close()
}

/// The Nocci terminal's tabs. A tab whose `start` is nil
/// shows the start page. Main thread only.
final class TerminalModel: ObservableObject {
    typealias MakeSession = (_ start: TerminalStart, _ fontSize: Double, _ tab: UUID) -> TerminalProcess
    typealias Confirm = (_ question: String, _ action: String) -> Bool

    struct Tab: Identifiable, Equatable {
        let id: UUID
        var start: TerminalStart?
        /// Where its session is shown. Start pages are always in the window.
        var place = TerminalPlace.window
    }

    @Published private(set) var tabs: [Tab] = []
    @Published var selection: UUID?
    @Published private(set) var fontSize: Double
    /// Moves whenever a session's state changes, so titles are drawn again.
    @Published private(set) var revision = 0
    @Published var draftFolder: String?
    @Published var draftLabel = ""
    @Published var draftAgent = ProjectAgent.claude
    @Published var draftPrompt = ""
    @Published private(set) var draftStatus: String?
    /// Tabs that had a session and were closed since Nocci started, so the
    /// Sessions list can drop their rows at once.
    @Published private(set) var closedTabs: Set<UUID> = []
    /// Codex tabs that need the user, in tab order.
    @Published private(set) var waits: [TerminalWait] = []
    /// True when the first tab opens, false when the last one closes.
    var onActivationChange: ((Bool) -> Void)?
    var onShow: (() -> Void)?
    var onChooseFolder: (() -> Void)?

    var selectedTab: Tab? { windowTabs.first { $0.id == selection } }
    /// The tabs the window lists; notch tabs are shown in the Projects tile.
    var windowTabs: [Tab] { tabs.filter { $0.place == .window } }
    var runningCount: Int { sessions.values.filter(\.programRunning).count }

    private let defaults: UserDefaults
    private let makeSession: MakeSession
    private let confirm: Confirm
    private let findProgram: (ProjectAgent) -> String?
    private let folderExists: (String) -> Bool
    private var sessions: [UUID: TerminalProcess] = [:]

    init(defaults: UserDefaults = .standard, makeSession: @escaping MakeSession, confirm: @escaping Confirm,
         findProgram: @escaping (ProjectAgent) -> String?, folderExists: @escaping (String) -> Bool) {
        self.defaults = defaults
        self.makeSession = makeSession
        self.confirm = confirm
        self.findProgram = findProgram
        self.folderExists = folderExists
        fontSize = TerminalRules.clampedFontSize(defaults.object(forKey: TerminalRules.fontSizeKey) as? Double)
    }

    /// Starts a session in the window's open start page or a new tab, or,
    /// for the notch, always in a new tab the window never shows. The tab's
    /// ID exists before the session, so its child can carry it.
    @discardableResult
    func start(_ start: TerminalStart, place: TerminalPlace = .window) -> UUID {
        precondition(Thread.isMainThread)
        let page = place == .window ? tabs.first { $0.id == selection && $0.start == nil }?.id : nil
        let id = page ?? UUID()
        let session = makeSession(start, place == .notch ? TerminalRules.notchFontSize : fontSize, id)
        session.onChange = { [weak self] in
            self?.revision += 1
            self?.updateWaits()
        }
        sessions[id] = session
        if let index = tabs.firstIndex(where: { $0.id == id }) {
            tabs[index].start = start
        } else {
            append(Tab(id: id, start: start, place: place))
            if place == .window { selection = id }
        }
        if place == .window { onShow?() }
        return id
    }

    /// Open in window: the notch tab joins the window at the window's text
    /// size and is shown there. Nothing happens for a tab already there.
    func moveToWindow(_ id: UUID) {
        precondition(Thread.isMainThread)
        guard let index = tabs.firstIndex(where: { $0.id == id }), tabs[index].place == .notch else { return }
        let first = windowTabs.isEmpty
        tabs[index].place = .window
        sessions[id]?.setFontSize(fontSize)
        selection = id
        if first { onActivationChange?(true) }
        onShow?()
    }

    /// A start page, reusing the one already open. A summon passes `show:
    /// false`, since it places the window itself.
    func newTab(show: Bool = true) {
        precondition(Thread.isMainThread)
        if let page = tabs.first(where: { $0.start == nil }) {
            selection = page.id
        } else {
            let tab = Tab(id: UUID(), start: nil)
            append(tab)
            selection = tab.id
        }
        draftStatus = nil
        if show { onShow?() }
    }

    func session(for id: UUID) -> TerminalProcess? { sessions[id] }

    func waiting(_ tab: Tab) -> Bool { sessions[tab.id]?.waitingSince != nil }

    /// Dismiss on a Codex row: the same as the user's next key.
    func clearWait(_ id: UUID) {
        precondition(Thread.isMainThread)
        sessions[id]?.clearWait()
        updateWaits()
    }

    func title(for tab: Tab) -> String {
        guard let start = tab.start else { return "New Tab" }
        return TerminalRules.title(label: start.label, agent: start.agent, agentRunning: sessions[tab.id]?.agentRunning ?? false)
    }

    /// False when the user kept the tab.
    @discardableResult
    func close(_ id: UUID) -> Bool {
        precondition(Thread.isMainThread)
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return true }
        if let start = tabs[index].start,
           let question = TerminalRules.closeQuestion(label: start.label, agent: start.agent,
                                                      agentRunning: sessions[id]?.agentRunning ?? false,
                                                      programRunning: sessions[id]?.programRunning ?? false),
           !confirm(question, "Close") {
            return false
        }
        sessions.removeValue(forKey: id)?.close()
        if tabs[index].start != nil { closedTabs.insert(id) }
        let place = tabs[index].place
        tabs.remove(at: index)
        updateWaits()
        if selection == id { selection = tabs[index...].first { $0.place == .window }?.id ?? windowTabs.last?.id }
        if place == .window && windowTabs.isEmpty { onActivationChange?(false) }
        return true
    }

    func closeSelected() {
        if let selection { close(selection) }
    }

    /// The window's close button: its own tabs only. False when the user kept
    /// them, or when a tab opened while the question was up, so the window
    /// stays to show it.
    @discardableResult
    func closeAll() -> Bool {
        precondition(Thread.isMainThread)
        let closing = windowTabs
        let running = closing.filter { sessions[$0.id]?.programRunning ?? false }.count
        if let question = TerminalRules.closeAllQuestion(running: running), !confirm(question, "Close") { return false }
        guard !closing.isEmpty else { return true }
        for tab in closing { sessions.removeValue(forKey: tab.id)?.close() }
        closedTabs.formUnion(closing.filter { $0.start != nil }.map(\.id))
        // Only what was asked about: a code review can open a tab while the
        // question is up.
        let closed = Set(closing.map(\.id))
        tabs.removeAll { closed.contains($0.id) }
        if let selection, closed.contains(selection) { self.selection = windowTabs.last?.id }
        updateWaits()
        guard windowTabs.isEmpty else { return false }
        onActivationChange?(false)
        return true
    }

    func canQuit() -> Bool {
        guard let question = TerminalRules.quitQuestion(running: runningCount) else { return true }
        return confirm(question, "Quit")
    }

    /// Closes everything without asking, once quitting is decided.
    func closeAllNow() {
        precondition(Thread.isMainThread)
        guard !tabs.isEmpty else { return }
        let hadWindowTabs = !windowTabs.isEmpty
        for session in sessions.values { session.close() }
        closedTabs.formUnion(tabs.filter { $0.start != nil }.map(\.id))
        sessions = [:]
        tabs = []
        selection = nil
        updateWaits()
        if hadWindowTabs { onActivationChange?(false) }
    }

    func selectNext() { step(1) }
    func selectPrevious() { step(-1) }

    func setFontSize(_ size: Double) {
        let clamped = TerminalRules.clampedFontSize(size)
        guard clamped != fontSize else { return }
        fontSize = clamped
        defaults.set(clamped, forKey: TerminalRules.fontSizeKey)
        for tab in windowTabs { sessions[tab.id]?.setFontSize(clamped) }
    }

    func biggerFont() { setFontSize(fontSize + 1) }
    func smallerFont() { setFontSize(fontSize - 1) }
    func actualSizeFont() { setFontSize(TerminalRules.defaultFontSize) }

    func chooseDraft(folder: String, label: String) {
        draftFolder = folder
        draftLabel = label
        draftStatus = nil
    }

    func startDraft() {
        precondition(Thread.isMainThread)
        let prompt = ProjectRules.effectivePrompt(draftPrompt)
        let program = findProgram(draftAgent)
        if let refusal = TerminalRules.startRefusal(folder: draftFolder, folderExists: draftFolder.map(folderExists) ?? false,
                                                     program: program, prompt: prompt, agent: draftAgent) {
            draftStatus = refusal
            return
        }
        guard let folder = draftFolder, let program else { return }
        draftStatus = nil
        draftPrompt = ""
        start(TerminalStart(folder: folder, label: draftLabel, agent: draftAgent, program: program, prompt: prompt))
    }

    private func updateWaits() {
        let current = tabs.compactMap { tab -> TerminalWait? in
            guard let start = tab.start, let since = sessions[tab.id]?.waitingSince else { return nil }
            return TerminalWait(tab: tab.id, label: start.label, since: since)
        }
        if current != waits { waits = current }
    }

    private func append(_ tab: Tab) {
        let first = tab.place == .window && windowTabs.isEmpty
        tabs.append(tab)
        if first { onActivationChange?(true) }
    }

    private func step(_ offset: Int) {
        let shown = windowTabs
        guard let selection, let index = shown.firstIndex(where: { $0.id == selection }), shown.count > 1 else { return }
        self.selection = shown[(index + offset + shown.count) % shown.count].id
    }
}
