import AppKit
import Combine

/// The Projects tab: the chosen folders, the scanned list and the compose
/// view. It follows `UsageModel`'s demo state and expansion like the other
/// models, and the panel tab that `PullRequestModel` stores.
final class ProjectModel: ObservableObject {
    typealias Executor = (@escaping () -> Void) -> Void
    typealias Scan = ([String]) -> DiscoveryResult
    typealias Launch = (LaunchRequest, @escaping (Result<Void, LaunchFailure>) -> Void) -> Void

    /// What the compose view's status line says.
    struct StatusLine: Equatable {
        var text: String
        var isProblem: Bool
    }

    static let scanGap: TimeInterval = 30

    @Published var settings: ProjectSettings {
        didSet {
            precondition(Thread.isMainThread)
            guard settings != oldValue else { return }
            if saves { settings.save(to: defaults) }
            if !settings.enabled {
                endCompose()
                moveAllToWindow()
                clearList()
            } else if settings.folders.isEmpty {
                moveAllToWindow()
                clearList()
            } else if settings.folders != oldValue.folders || !oldValue.enabled {
                scan(force: true)
            }
            refreshShowing()
        }
    }
    @Published private(set) var projects: [Project] = []
    @Published private(set) var folderStates: [String: FolderState] = [:]
    @Published private(set) var scanned = false
    @Published private(set) var demo = false
    /// The project a prompt is being written for. Nil shows the list.
    @Published private(set) var selected: Project?
    @Published var prompt = ""
    @Published private(set) var status: String?
    @Published private(set) var launching = false
    /// Targets whose application is installed, in preference order.
    @Published private(set) var installed: [LaunchTarget] = []
    @Published private(set) var targetNames: [LaunchTarget: String] = [:]
    @Published private(set) var claudePath: String?
    @Published private(set) var codexPath: String?
    /// Notch sessions by project folder, handed over by `AppDelegate`.
    @Published private(set) var notchSessions: [String: NotchSession] = [:]
    /// The folder whose terminal the tile shows, or nil for the list. Kept
    /// while the panel is closed, hidden or on another tab.
    @Published private(set) var shownFolder: String?
    /// True while the Projects tab is on screen with a notch terminal: the
    /// panel accepts the keyboard then, and takes it only on a click.
    @Published private(set) var showingTerminal = false
    /// True while that terminal has the keyboard. It holds the notch open,
    /// as composing does.
    @Published private(set) var typing = false
    /// True when composing ended because a session started, so the keyboard
    /// is not handed back over the app that is coming forward. It describes
    /// that one release only: `AppDelegate.setKeyboard` clears it whenever
    /// the panel takes the keyboard again.
    var endedByLaunch = false
    var onSettings: (() -> Void)?
    var onAddFolder: (() -> Void)?
    var onChooseClaude: (() -> Void)?
    var onChooseTerminal: (() -> Void)?
    /// Set once Nocci can host sessions itself; while nil, Nocci is not
    /// offered. Returns the new tab's ID.
    var onStartInNocci: ((TerminalStart, TerminalPlace) -> UUID?)?
    var onMoveToWindow: ((UUID) -> Void)?
    /// Closes a notch session, asking first while its agent runs. False
    /// when the user kept it.
    var onCloseSession: ((UUID) -> Bool)?
    var sessionView: ((UUID) -> NSView?)?

    let home: String
    var composing: Bool { selected != nil }
    /// The tab the tile shows, while it shows one.
    var shownTab: UUID? { showingTerminal ? shownFolder.flatMap { notchSessions[$0]?.tab } : nil }
    var targets: [LaunchTarget] { installed.filter { $0.supports(settings.agent) } }
    var target: LaunchTarget? {
        ProjectRules.resolvedTarget(stored: settings.target(for: settings.agent), agent: settings.agent, available: installed)
    }
    var labels: [String: String] { ProjectRules.labels(for: projects, home: home) }
    var emptyText: String {
        ProjectRules.emptyText(folders: settings.folders, states: folderStates, scanned: scanned, home: home)
    }
    var footerText: String {
        if demo { return "Sample data" }
        if composing { return "Return starts · Esc goes back" }
        if showingTerminal { return "Click to type · Back keeps it running" }
        return ProjectRules.footer(count: projects.count, folders: settings.folders, states: folderStates, home: home)
    }
    var statusLine: StatusLine? {
        if let status { return StatusLine(text: status, isProblem: true) }
        if let problem { return StatusLine(text: problem, isProblem: true) }
        return target.flatMap(ProjectRules.note(for:)).map { StatusLine(text: $0, isProblem: false) }
    }
    var canStart: Bool { selected != nil && !demo && !launching && problem == nil }
    /// Where a plain shell opens: the remembered app when it is a terminal,
    /// otherwise the first installed terminal.
    var shellTarget: LaunchTarget? {
        if let target, target.isTerminal { return target }
        return installed.first { $0.isTerminal }
    }

    private let defaults: UserDefaults
    /// False for the appearance preview, which must never change saved choices.
    private let saves: Bool
    private let scanner: Scan
    private let launch: Launch
    private let findProgram: (ProjectAgent) -> String?
    private let findApplication: (LaunchTarget) -> URL?
    private let appName: (URL) -> String
    private let folderExists: (String) -> Bool
    private let reveal: (URL) -> Void
    private let openFolder: ProjectLauncher.Open
    private let now: () -> Date
    private let io: Executor
    private let main: Executor
    private var applications: [LaunchTarget: URL] = [:]
    private var drafts: [String: String] = [:]
    private var ending = false
    private var endingTyping = false
    private var activeScan: UUID?
    private var lastScan: Date?
    private var tabShown = false
    private var observations = Set<AnyCancellable>()

    init(usage: UsageModel, tab: AnyPublisher<PanelTab, Never>, defaults: UserDefaults = .standard, saves: Bool = true,
         scanner: @escaping Scan = ProjectScanner.scan, launch: Launch? = nil,
         program: ((ProjectAgent) -> String?)? = nil, application: ((LaunchTarget) -> URL?)? = nil,
         appName: @escaping (URL) -> String = ProjectLauncher.liveAppName,
         folderExists: @escaping (String) -> Bool = ProjectModel.liveFolderExists,
         reveal: @escaping (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) },
         openFolder: @escaping ProjectLauncher.Open = ProjectLauncher.liveOpen,
         home: String = FileManager.default.homeDirectoryForCurrentUser.path,
         now: @escaping () -> Date = Date.init,
         io: @escaping Executor = { DispatchQueue.global(qos: .utility).async(execute: $0) },
         main: @escaping Executor = { DispatchQueue.main.async(execute: $0) }) {
        self.defaults = defaults
        self.saves = saves
        self.scanner = scanner
        self.launch = launch ?? { request, done in ProjectLauncher().launch(request, completion: done) }
        self.findProgram = program ?? { ProjectModel.liveProgram($0, defaults: defaults) }
        self.findApplication = application ?? { ProjectLauncher.liveApplication($0, defaults: defaults) }
        self.appName = appName
        self.folderExists = folderExists
        self.reveal = reveal
        self.openFolder = openFolder
        self.home = home
        self.now = now
        self.io = io
        self.main = main
        settings = ProjectSettings.load(from: defaults)
        // @Published sends before the property changes, so each sink uses the
        // value it is handed rather than reading `usage` back.
        usage.$demo.removeDuplicates().sink { [weak self] demo in self?.setDemo(demo) }.store(in: &observations)
        tab.removeDuplicates().sink { [weak self] tab in self?.tabChanged(tab) }.store(in: &observations)
        // A collapse, such as unpinning or a summon, gives the keyboard back,
        // so the typing hold can never reopen a closed notch.
        usage.$expanded.removeDuplicates().sink { [weak self] expanded in
            guard let self else { return }
            guard expanded else { return self.endTyping() }
            guard self.tabShown else { return }
            self.scan(force: false)
        }.store(in: &observations)
    }

    /// One scan at a time. A scan whose folders no longer match when it
    /// finishes is dropped and one replacement runs.
    func scan(force: Bool) {
        precondition(Thread.isMainThread)
        guard !demo, settings.enabled, !settings.folders.isEmpty, activeScan == nil else { return }
        let date = now()
        if !force, let lastScan, date.timeIntervalSince(lastScan) < Self.scanGap { return }
        let request = UUID(), folders = settings.folders, scanner = scanner, main = main
        activeScan = request
        lastScan = date
        io { [weak self] in
            let result = scanner(folders)
            main { self?.finish(request, folders: folders, result: result) }
        }
    }

    /// A row click: its notch terminal when it has one, otherwise the compose view.
    func open(_ project: Project) {
        precondition(Thread.isMainThread)
        guard notchSessions[project.path] == nil else { return showTerminal(project) }
        compose(project)
    }

    /// The compose view, also from New Session… on a row with a notch session.
    func compose(_ project: Project) {
        precondition(Thread.isMainThread)
        guard !demo, settings.enabled, selected?.path != project.path else { return }
        endCompose()
        refreshAvailability()
        endedByLaunch = false
        status = nil
        prompt = drafts[project.path] ?? ""
        selected = project
    }

    /// Shows a project's notch terminal without taking the keyboard.
    func showTerminal(_ project: Project) {
        precondition(Thread.isMainThread)
        guard !demo, settings.enabled, notchSessions[project.path] != nil else { return }
        endCompose()
        shownFolder = project.path
        refreshShowing()
    }

    /// A Sessions row for a notch tab: its terminal, with the keyboard.
    func showTerminal(tab: UUID) {
        precondition(Thread.isMainThread)
        guard !demo, settings.enabled, let folder = notchSessions.first(where: { $0.value.tab == tab })?.key else { return }
        endCompose()
        shownFolder = folder
        refreshShowing()
        if showingTerminal { typing = true }
    }

    /// The back chevron: the list, with the session still running.
    func backToList() {
        precondition(Thread.isMainThread)
        endTyping()
        shownFolder = nil
        moveUnlisted()
        refreshShowing()
    }

    /// Open in window. The window takes the keyboard, so nothing is handed back.
    func moveShownToWindow() {
        precondition(Thread.isMainThread)
        guard let tab = shownTab, let folder = shownFolder else { return }
        onMoveToWindow?(tab)
        endTyping()
        notchSessions[folder] = nil
        shownFolder = nil
        refreshShowing()
    }

    /// Close: asks first while the agent runs, then back to the list.
    func closeShown() {
        precondition(Thread.isMainThread)
        guard let tab = shownTab, let folder = shownFolder, onCloseSession?(tab) == true else { return }
        endTyping()
        notchSessions[folder] = nil
        shownFolder = nil
        refreshShowing()
    }

    /// The panel became key while the tile shows a terminal: a click inside it.
    func beganTyping() {
        precondition(Thread.isMainThread)
        guard showingTerminal, !composing, !typing else { return }
        typing = true
    }

    /// Gives the keyboard back; the session keeps running. Handing it back
    /// resigns the panel, whose observer calls this again from inside the change.
    func endTyping() {
        precondition(Thread.isMainThread)
        guard typing, !endingTyping else { return }
        endingTyping = true
        defer { endingTyping = false }
        typing = false
    }

    /// The terminal's notch tabs, by folder. A shown terminal whose tab has
    /// gone returns the tile to the list, and a session whose project is no
    /// longer listed moves to the window.
    func setNotchSessions(_ value: [String: NotchSession]) {
        precondition(Thread.isMainThread)
        if value != notchSessions { notchSessions = value }
        if let folder = shownFolder, value[folder] == nil {
            endTyping()
            shownFolder = nil
        }
        moveUnlisted()
        refreshShowing()
    }

    /// Back to the list. An unsent prompt stays as that project's draft.
    func endCompose() {
        precondition(Thread.isMainThread)
        // Handing the keyboard back resigns the panel, which calls this again
        // from inside the first call, after the prompt is already cleared.
        guard !ending, let project = selected else { return }
        ending = true
        defer { ending = false }
        drafts[project.path] = prompt.isEmpty ? nil : prompt
        endedByLaunch = false
        status = nil
        prompt = ""
        selected = nil
    }

    func start() {
        precondition(Thread.isMainThread)
        guard let project = selected, !demo, !launching else { return }
        refreshAvailability()
        let agent = settings.agent
        guard folderExists(project.path) else {
            status = "This folder no longer exists."
            scan(force: true)
            return
        }
        if let problem {
            status = problem
            return
        }
        guard let target else { return }
        let text = ProjectRules.effectivePrompt(prompt)
        if let refusal = ProjectRules.refusal(for: text, agent: agent, target: target) {
            status = refusal.message(for: agent)
            return
        }
        if target == .nocci {
            guard let program, let startInNocci = onStartInNocci else { return }
            // One notch session per project; a second one opens in the window.
            let place: TerminalPlace = notchSessions[project.path] == nil ? .notch : .window
            let label = labels[project.path] ?? project.name
            guard let tab = startInNocci(TerminalStart(folder: project.path, label: label, agent: agent,
                                                       program: program, prompt: text), place) else { return }
            drafts[project.path] = nil
            status = nil
            prompt = ""
            if place == .notch {
                // The terminal takes the keyboard before compose lets go of
                // it, so it is never handed back in between.
                notchSessions[project.path] = NotchSession(tab: tab, title: TerminalRules.title(label: label, agent: agent,
                                                                                                 agentRunning: true),
                                                           waiting: false)
                shownFolder = project.path
                refreshShowing()
                if showingTerminal { typing = true }
                endedByLaunch = false
            } else {
                endedByLaunch = true
            }
            selected = nil
            return
        }
        guard let application = applications[target] else { return }
        let name = targetNames[target] ?? "The app"
        let request = LaunchRequest(project: project.path, agent: agent, target: target,
                                    program: target.isTerminal ? program : nil, application: application, prompt: text)
        launching = true
        status = nil
        launch(request) { [weak self] result in
            guard let self else { return }
            precondition(Thread.isMainThread)
            self.launching = false
            let current = self.selected?.path == project.path
            switch result {
            case .success:
                self.drafts[project.path] = nil
                guard current else { return }
                self.endedByLaunch = true
                self.status = nil
                self.prompt = ""
                self.selected = nil
            case .failure(let failure):
                guard current else { return }
                self.status = failure == .notPrepared ? "Nocci couldn't prepare the session." : "\(name) couldn't be opened."
            }
        }
    }

    func revealInFinder(_ project: Project) {
        guard let folder = existingFolder(project) else { return }
        reveal(folder)
    }

    /// A plain shell in the folder, with no agent and no script.
    func openShell(_ project: Project) {
        guard let shell = shellTarget, let application = applications[shell],
              let folder = existingFolder(project) else { return }
        openFolder([folder], application) { _ in }
    }

    /// The folder in VS Code, without starting Claude Code.
    func openInEditor(_ project: Project) {
        guard let application = applications[.vscode], let folder = existingFolder(project) else { return }
        openFolder([folder], application) { _ in }
    }

    func choose(agent: ProjectAgent) {
        precondition(Thread.isMainThread)
        status = nil
        settings.agent = agent
    }

    func choose(target: LaunchTarget) {
        precondition(Thread.isMainThread)
        status = nil
        settings.setTarget(target, for: settings.agent)
    }

    /// Looks up installed apps and programs. Run when composing starts, on
    /// Start and when Settings shows; only file checks are involved.
    func refreshAvailability() {
        precondition(Thread.isMainThread)
        var found: [LaunchTarget: URL] = [:]
        for target in LaunchTarget.allCases { found[target] = findApplication(target) }
        // An other terminal that is Terminal or iTerm2 would be listed twice.
        if let other = found[.otherTerminal], Self.isOffered(other, in: found) { found[.otherTerminal] = nil }
        applications = found
        let order = LaunchTarget.allCases.filter { found[$0] != nil || ($0 == .nocci && onStartInNocci != nil) }
        if order != installed { installed = order }
        var names = found.mapValues(appName)
        // Not yet tried in the running app, so offered as experimental.
        if order.contains(.nocci) { names[.nocci] = "Nocci (experimental)" }
        if names != targetNames { targetNames = names }
        let claude = findProgram(.claude), codex = findProgram(.codex)
        if claude != claudePath { claudePath = claude }
        if codex != codexPath { codexPath = codex }
    }

    /// False when the folder is already listed.
    @discardableResult
    func addFolder(_ path: String) -> Bool {
        var changed = settings
        guard changed.addFolder(path) else { return false }
        settings = changed
        return true
    }

    func removeFolder(_ path: String) {
        settings.folders.removeAll { $0 == path }
    }

    func setClaudePath(_ path: String) {
        if saves { defaults.set(path, forKey: ClaudeProgram.preferenceKey) }
        refreshAvailability()
    }

    /// False, and nothing saved, for an app Nocci already offers by itself.
    @discardableResult
    func setOtherTerminal(_ path: String) -> Bool {
        refreshAvailability()
        guard !Self.isOffered(URL(fileURLWithPath: path), in: applications) else { return false }
        if saves { defaults.set(path, forKey: ProjectLauncher.otherTerminalKey) }
        refreshAvailability()
        return true
    }

    func clearOtherTerminal() {
        if saves { defaults.removeObject(forKey: ProjectLauncher.otherTerminalKey) }
        refreshAvailability()
    }

    private static func isOffered(_ application: URL, in found: [LaunchTarget: URL]) -> Bool {
        [LaunchTarget.terminal, .iterm].contains { found[$0]?.standardizedFileURL == application.standardizedFileURL }
    }

    static func liveProgram(_ agent: ProjectAgent, defaults: UserDefaults = .standard) -> String? {
        agent == .claude ? ClaudeProgram.executable(defaults: defaults)
                         : CodexReader.executable(savedPath: defaults.string(forKey: "codexPath"))
    }

    static func liveFolderExists(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private var program: String? { settings.agent == .claude ? claudePath : codexPath }

    /// Why Start cannot run, before it is pressed.
    private var problem: String? {
        guard let target else { return "No app that can open \(settings.agent.title) was found." }
        guard target.runsProgram, program == nil else { return nil }
        return ProjectRules.missingProgram(settings.agent)
    }

    private func finish(_ request: UUID, folders: [String], result: DiscoveryResult) {
        precondition(Thread.isMainThread)
        guard activeScan == request else { return }
        activeScan = nil
        guard !demo, settings.enabled, !settings.folders.isEmpty else { return }
        guard folders == settings.folders else { return scan(force: true) }
        let ordered = ProjectRules.ordered(result.projects)
        if ordered != projects { projects = ordered }
        if result.folders != folderStates { folderStates = result.folders }
        scanned = true
        moveUnlisted()
        refreshShowing()
    }

    /// Only after a real scan: demo, a scan in flight and the empty list
    /// after leaving demo say nothing about whether a project has gone. A
    /// plain folder is listed as a group once the agent makes a repository
    /// inside it; while its terminal is on screen it stays, so a rescan never
    /// pulls it out of the notch mid-conversation, and it moves once the tile
    /// goes back to a list that has no row for it.
    private func moveUnlisted() {
        guard scanned, !demo, settings.enabled else { return }
        let listed = Set(projects.map(\.path))
        func stillShown(_ folder: String) -> Bool {
            folder == shownFolder && folderExists(folder)
                && settings.folders.contains { folder.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
        }
        for (folder, session) in notchSessions where !listed.contains(folder) && !stillShown(folder) {
            notchSessions[folder] = nil
            if shownFolder == folder {
                endTyping()
                shownFolder = nil
            }
            onMoveToWindow?(session.tab)
        }
    }

    /// Projects turned off, or no folder left: every notch session goes to the window.
    private func moveAllToWindow() {
        let moving = notchSessions.values.map(\.tab)
        endTyping()
        shownFolder = nil
        if !notchSessions.isEmpty { notchSessions = [:] }
        for tab in moving { onMoveToWindow?(tab) }
    }

    private func refreshShowing() {
        let showing = tabShown && !demo && settings.enabled && shownFolder.map { notchSessions[$0] != nil } == true
        if !showing { endTyping() }
        if showing != showingTerminal { showingTerminal = showing }
    }

    private func clearList() {
        if !projects.isEmpty { projects = [] }
        if !folderStates.isEmpty { folderStates = [:] }
        scanned = false
        lastScan = nil
    }

    private func tabChanged(_ tab: PanelTab) {
        precondition(Thread.isMainThread)
        tabShown = tab == .projects
        refreshShowing()
        guard tabShown else { return endCompose() }
        // The row menu names the installed terminal and editor.
        refreshAvailability()
        scan(force: false)
    }

    /// The project's folder, or nil (after starting a rescan) when it has gone.
    private func existingFolder(_ project: Project) -> URL? {
        precondition(Thread.isMainThread)
        guard !demo else { return nil }
        guard folderExists(project.path) else {
            scan(force: true)
            return nil
        }
        return URL(fileURLWithPath: project.path, isDirectory: true)
    }

    private func setDemo(_ value: Bool) {
        precondition(Thread.isMainThread)
        guard value != demo else { return }
        endCompose()
        demo = value
        if value {
            projects = ProjectSamples.projects(now: now())
            folderStates = [:]
            scanned = true
        } else {
            clearList()
            if tabShown { scan(force: true) }
        }
        refreshShowing()
    }
}
