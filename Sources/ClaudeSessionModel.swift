import AppKit
import Combine

/// Follows the session files the `--claude-hook` bridge writes. It takes its
/// clock and demo state from `UsageModel` instead of running a timer, the same
/// way `HistoryModel` does, and watches the directory so a change shows at once.
final class ClaudeSessionModel: ObservableObject {
    typealias Executor = (@escaping () -> Void) -> Void

    /// Sessions that need the user, most urgent first.
    @Published private(set) var items: [ClaudeSessionItem] = []
    @Published private(set) var status: ClaudeHooksStatus
    @Published private(set) var demo = false
    /// Goes up once for every update that brings at least one new wait after
    /// the first-scan baseline, whatever the notification switch says. The
    /// notch bounces on each change.
    @Published private(set) var waitCount = 0
    /// The terminal's live session tabs, tabs closed this run and Codex
    /// waits, fed from `AppDelegate`.
    @Published private(set) var hosting = ClaudeSessionHosting()
    /// The hosted row whose mini view is open; one at a time.
    @Published private(set) var answering: ClaudeSessionItem?
    @Published var notify: Bool {
        didSet {
            precondition(Thread.isMainThread)
            guard notify != oldValue else { return }
            defaults.set(notify, forKey: "sessions.notify")
        }
    }
    /// A hosted row was clicked: select that tab and drop the window.
    var onSummon: ((UUID) -> Void)?
    /// A Codex wait was dismissed: clear it, as the next key would.
    var onClearWait: ((UUID) -> Void)?
    /// A fresh mini view for a live tab, or nil when the tab is gone.
    var hostedView: ((UUID) -> NSView?)?

    /// Hooks installed from a place Nocci has since left still run, so they
    /// still count as on until the user reinstalls.
    var enabled: Bool {
        switch status {
        case .on, .moved: return true
        case .off, .removedOutside: return false
        }
    }
    var needsYou: Bool { !items.isEmpty }
    /// What each row is called: its project, with the app and start time added
    /// only where names clash.
    var labels: [String: String] {
        precondition(Thread.isMainThread)
        return ClaudeSessionRules.labels(for: items, now: now(), appName: cachedAppName, calendar: .current, locale: .current)
    }

    private weak var usage: UsageModel?
    private let store: ClaudeSessionStore
    private let defaults: UserDefaults
    private let makeInstaller: () -> ClaudeHooksInstaller
    private let statusProvider: () -> ClaudeHooksStatus
    private let activate: (String) -> Bool
    private let appName: (String) -> String?
    private var appNames: [String: String?] = [:]
    private let delivery: AlertDelivery?
    private let now: () -> Date
    private let io: Executor
    private let main: Executor
    private let watch: Bool
    private var watcher: DispatchSourceFileSystemObject?
    private var request = UUID()
    private var baselined = false
    /// The wait each shown session was last seen in, so a notification goes
    /// out once per wait, never again for the same one.
    private var handled: [String: Date] = [:]
    /// The files as last read, so a hosting change applies without a disk read.
    private var loaded: [ClaudeSessionItem] = []
    private var clearingAnswer = false
    private var observations = Set<AnyCancellable>()

    init(usage: UsageModel, store: ClaudeSessionStore = ClaudeSessionStore(), defaults: UserDefaults = .standard,
         installer: @escaping () -> ClaudeHooksInstaller = ClaudeSessionModel.liveInstaller,
         status: (() -> ClaudeHooksStatus)? = nil,
         activate: @escaping (String) -> Bool = ClaudeSessionModel.liveActivate,
         appName: @escaping (String) -> String? = ClaudeSessionModel.liveAppName,
         delivery: AlertDelivery? = nil, now: @escaping () -> Date = Date.init,
         io: @escaping Executor = { DispatchQueue.global(qos: .utility).async(execute: $0) },
         main: @escaping Executor = { DispatchQueue.main.async(execute: $0) },
         watch: Bool = true) {
        self.usage = usage
        self.store = store
        self.defaults = defaults
        self.makeInstaller = installer
        let statusProvider = status ?? { installer().status() }
        self.statusProvider = statusProvider
        self.activate = activate
        self.appName = appName
        self.delivery = delivery
        self.now = now
        self.io = io
        self.main = main
        self.watch = watch
        self.status = statusProvider()
        self.notify = defaults.bool(forKey: "sessions.notify")
        // @Published sends before the property changes, so each sink uses the
        // value it is handed rather than reading `usage` back.
        usage.$demo.removeDuplicates().sink { [weak self] demo in self?.setDemo(demo) }.store(in: &observations)
        usage.$tick.sink { [weak self] _ in self?.reload() }.store(in: &observations)
        updateWatcher()
    }

    deinit { watcher?.cancel() }

    /// Run at launch and when Settings changes the hooks.
    func refreshStatus() {
        precondition(Thread.isMainThread)
        let wasEnabled = enabled
        let value = statusProvider()
        if value != status { status = value }
        // Sessions already waiting when the feature comes on are a baseline,
        // not news.
        if enabled && !wasEnabled {
            baselined = false
            handled = [:]
        }
        updateWatcher()
        reload()
    }

    /// What Turn On would change, for the review sheet. Nothing is written.
    func reviewPlan() throws -> ClaudeHooksPlan {
        try makeInstaller().plan()
    }

    func turnOn() throws {
        precondition(Thread.isMainThread)
        try makeInstaller().install()
        refreshStatus()
    }

    /// Removes only Nocci's hooks, then every session file it kept.
    func turnOff() throws {
        precondition(Thread.isMainThread)
        try makeInstaller().uninstall()
        try? store.removeAll()
        refreshStatus()
    }

    func reload() {
        precondition(Thread.isMainThread)
        guard !demo else { return }
        guard enabled else {
            request = UUID()
            loaded = []
            clearAnswer()
            if !items.isEmpty { items = [] }
            return
        }
        let request = UUID(), date = now(), store = store, main = main
        self.request = request
        io { [weak self] in
            try? store.removeExpired(at: date)
            let loaded = store.load()
            main {
                guard let self, self.request == request, !self.demo, self.enabled else { return }
                self.publish(loaded, at: date)
            }
        }
    }

    func dismiss(_ item: ClaudeSessionItem) {
        dismiss([item])
    }

    func dismissAll() {
        dismiss(items)
    }

    /// Brings the app hosting the session forward, or, for a Nocci tab,
    /// summons the terminal with that tab. Sample rows, and sessions whose
    /// app is unknown, do nothing.
    @discardableResult
    func open(_ item: ClaudeSessionItem) -> Bool {
        precondition(Thread.isMainThread)
        guard !demo else { return false }
        if let tab = item.record.tab, hosting.live.contains(tab), let onSummon {
            onSummon(tab)
            return true
        }
        guard let host = item.record.host else { return false }
        return activate(host)
    }

    func setHosting(_ value: ClaudeSessionHosting) {
        precondition(Thread.isMainThread)
        guard value != hosting else { return }
        hosting = value
        republish()
    }

    func isHosted(_ item: ClaudeSessionItem) -> Bool {
        ClaudeSessionRules.isHosted(item, live: hosting.live)
    }

    /// A hosted row whose tab is in the notch. Its click opens the Projects
    /// tile, and it has no mini view since the real terminal is one click away.
    func isInNotch(_ item: ClaudeSessionItem) -> Bool {
        isHosted(item) && (item.record.tab.map(hosting.notch.contains) ?? false)
    }

    /// The chevron: opens the row's mini view, or closes the open one.
    func toggleAnswer(_ item: ClaudeSessionItem) {
        precondition(Thread.isMainThread)
        if answering?.id == item.id { return endAnswer() }
        guard !demo, enabled, isHosted(item), !isInNotch(item), items.contains(where: { $0.id == item.id }) else { return }
        answering = item
    }

    func endAnswer() {
        precondition(Thread.isMainThread)
        guard answering != nil, !clearingAnswer else { return }
        clearAnswer()
        republish()
    }

    /// Handing the keyboard back resigns the panel, whose observer calls
    /// `endAnswer` again from inside this change, before it has landed.
    private func clearAnswer() {
        guard answering != nil, !clearingAnswer else { return }
        clearingAnswer = true
        defer { clearingAnswer = false }
        answering = nil
    }

    /// Applies a hosting or answering change to the files already read. Not
    /// before the first read since turning on: every wait would look new.
    private func republish() {
        guard enabled, !demo, baselined else { return }
        publish(loaded, at: now())
    }

    private func dismiss(_ chosen: [ClaudeSessionItem]) {
        precondition(Thread.isMainThread)
        guard !demo, !chosen.isEmpty else { return }
        for item in chosen where ClaudeSessionRules.isHostedWait(item) {
            if let tab = item.record.tab { onClearWait?(tab) }
        }
        let files = chosen.filter { !ClaudeSessionRules.isHostedWait($0) }
        guard !files.isEmpty else { return }
        let store = store, main = main
        io { [weak self] in
            for item in files { try? store.dismiss(item.id, since: item.record.since) }
            main { self?.reload() }
        }
    }

    private func publish(_ loaded: [ClaudeSessionItem], at date: Date) {
        self.loaded = loaded
        let shown = ClaudeSessionRules.hosted(loaded, closed: hosting.closed) + hosting.waits.map(ClaudeSessionRules.hostedItem)
        var attention = ClaudeSessionRules.attention(shown, at: date)
        let fresh = attention.filter { handled[$0.id] != $0.record.since }
        handled = Dictionary(uniqueKeysWithValues: attention.map { ($0.id, $0.record.since) })
        // Presentation mode withholds delivery but still marks the wait as
        // handled, so ending it never releases a backlog.
        if baselined, notify, let usage, !usage.presentation.isActive(at: date) {
            for item in fresh { delivery?.send(message(item), sound: usage.alertPreferences.sound) }
        }
        if baselined, !fresh.isEmpty { waitCount += 1 }
        baselined = true
        // A row being answered stays where it was until its mini view closes,
        // so an answer never makes the view vanish mid-keystroke. Its tab
        // closing ends the answer instead.
        if let held = answering {
            if let tab = held.record.tab, hosting.live.contains(tab), !hosting.closed.contains(tab) {
                let current = shown.first { $0.id == held.id } ?? held
                if let index = attention.firstIndex(where: { $0.id == held.id }) {
                    attention[index] = current
                } else {
                    let place = items.firstIndex { $0.id == held.id } ?? attention.count
                    attention.insert(current, at: min(place, attention.count))
                }
                if current != held { answering = current }
            } else {
                clearAnswer()
            }
        }
        if attention != items { items = attention }
    }

    /// The project name and state only; nothing from the session itself.
    private func message(_ item: ClaudeSessionItem) -> AlertMessage {
        if item.record.state == .waiting {
            return AlertMessage(title: "Codex", body: "\(item.record.project ?? "A Codex session") needs you",
                                identifier: "nocci.session.\(item.id)")
        }
        let name = item.record.project ?? "A Claude Code session"
        let body: String
        switch item.record.state {
        case .permission: body = "\(name) needs permission"
        case .question: body = "\(name) is asking a question"
        default: body = "\(name) finished: your turn"
        }
        return AlertMessage(title: "Claude Code", body: body, identifier: "nocci.session.\(item.id)")
    }

    private func setDemo(_ value: Bool) {
        precondition(Thread.isMainThread)
        guard value != demo else { return }
        demo = value
        request = UUID()
        clearAnswer()
        items = value ? ClaudeSessionSamples.items(now: now()) : []
        if !value { reload() }
    }

    private func updateWatcher() {
        guard watch, enabled else {
            watcher?.cancel()
            watcher = nil
            return
        }
        guard watcher == nil else { return }
        try? FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let descriptor = Darwin.open(store.directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                                                               eventMask: [.write, .delete, .rename], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            // The directory itself went away (Turn Off): watch again when it returns.
            if source.data.contains(.delete) || source.data.contains(.rename) {
                self.watcher?.cancel()
                self.watcher = nil
            }
            self.reload()
        }
        source.setCancelHandler { close(descriptor) }
        watcher = source
        source.resume()
    }

    static func liveInstaller() -> ClaudeHooksInstaller {
        ClaudeHooksInstaller(paths: ClaudePaths.resolve(), appPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
    }

    /// Looked up once per app, since the list is drawn on every tick.
    private func cachedAppName(_ bundleIdentifier: String) -> String? {
        if let known = appNames[bundleIdentifier] { return known }
        let name = appName(bundleIdentifier)
        appNames[bundleIdentifier] = name
        return name
    }

    /// The name Finder and the Dock show, such as "Visual Studio Code". Nil
    /// when no installed app has the identifier. Nothing is launched.
    static func liveAppName(_ bundleIdentifier: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return nil }
        let name = FileManager.default.displayName(atPath: url.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    /// Only an app that is already running is brought forward; a session
    /// whose app has quit is not worth launching it for.
    static func liveActivate(_ bundleIdentifier: String) -> Bool {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        return true
    }
}
