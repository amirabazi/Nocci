import Foundation
import Combine

final class UsageModel: ObservableObject {
    @Published var claude: UsageSnapshot?
    @Published var codex: UsageSnapshot?
    @Published var codexMessage = CodexReader.connectingMessage
    @Published var claudeConnection: ClaudeConnection = .notConfigured
    @Published var expanded = false
    @Published var pinned = false
    @Published private(set) var demo: Bool
    @Published var refreshing = false
    @Published var notchWidth: CGFloat = 190
    @Published var notchHeight: CGFloat = 32
    /// The Projects tile's height while it shows a notch terminal, set by
    /// `AppDelegate.layout` from `NotchMetrics.terminalSlot`. The view never
    /// uses less than the list's height, so the unset 0 is harmless.
    @Published var terminalSlot: CGFloat = 0
    @Published var tick = Date()
    /// The pointer is resting on the collapsed strip. Set by the app from the
    /// hover poll; drawing only.
    @Published var peeking = false
    /// The collapsed strip is briefly wider because a session started
    /// waiting. Set by the app; drawing only.
    @Published var bouncing = false
    /// A full-screen app owns the notch's display and the user asked the
    /// notch to step aside. Separate from the user's own show/hide and pin.
    @Published var fullScreenHidden = false
    /// The chosen screen has no notch, so the notch draws as a pill with a
    /// floating card. `notchHeight` is then the pill's height.
    @Published var floating = false
    /// The Nocci terminal has tabs, so the open notch row offers its button.
    @Published var terminalOpen = false
    /// The terminal window hangs from the notch.
    @Published var terminalDropped = false
    var onLayout: (() -> Void)?
    var onConnectClaude: (() -> Void)?
    var onChooseCodex: (() -> Void)?
    var onOpenGuide: (() -> Void)?
    var onQuit: (() -> Void)?
    var onPreview: (() -> Void)?
    var onSettings: (() -> Void)?
    var onHistory: (() -> Void)?
    var onSummonTerminal: (() -> Void)?
    /// A click on the collapsed strip. The app opens the panel and plays the
    /// haptic tick; without it (previews) the view just expands.
    var onUserOpen: (() -> Void)?
    var timer: Timer?
    var pollCount = 0
    typealias Completion = (Result<UsageSnapshot, Error>) -> Void
    typealias FetchCodex = (@escaping Completion) -> Void
    /// Completion-based like `FetchCodex`, so decoding can leave the main
    /// thread. Disk work must never share the path that drives hover polling.
    typealias LoadClaude = (@escaping (UsageSnapshot?) -> Void) -> Void
    private let fetchCodex: FetchCodex
    private let loadClaude: LoadClaude
    private var claudeRequest: UUID?
    @Published private(set) var claudePace: PaceEstimate?
    @Published private(set) var codexPace: PaceEstimate?
    /// A bounded in-memory buffer per provider and window, so pace works
    /// whether or not persistent history recording is switched on.
    private var paceSamples: [String: [PaceSample]] = [:]
    private var paceTrackers: [String: PaceTracker] = [:]
    private let inspectClaude: (ClaudeSnapshotInfo) -> ClaudeConnection
    private let defaults: UserDefaults
    private weak var delivery: AlertDelivery?
    private var alertState: AlertState
    /// Raised when presentation mode starts, ends, or lapses on its own.
    var onPresentationChanged: (() -> Void)?
    /// Manual suppression of this app's surfaces, kept separate from the user's
    /// hidden and pinned preferences so ending it restores what they chose.
    @Published var presentation: PresentationState {
        didSet {
            precondition(Thread.isMainThread)
            guard presentation != oldValue, !sampleOnly else { return }
            presentation.save(to: defaults)
            onPresentationChanged?()
        }
    }
    /// Threshold-alert settings. Switching a provider off or changing its
    /// thresholds forgets that provider's windows, so the next evaluation
    /// establishes a quiet baseline instead of producing a retroactive alert.
    @Published var alertPreferences: AlertPreferences {
        didSet {
            precondition(Thread.isMainThread)
            guard alertPreferences != oldValue else { return }
            alertPreferences.save(to: defaults)
            for provider in AlertProvider.allCases {
                let disabled = !alertPreferences.enabled(for: provider)
                    && oldValue.enabled(for: provider)
                let thresholdsChanged = alertPreferences.thresholds(for: provider)
                    != oldValue.thresholds(for: provider)
                if disabled || thresholdsChanged { alertState.forget(provider) }
            }
            alertState.save(to: defaults)
            evaluateAlerts()
        }
    }
    private var generation = UUID()
    private var activeRequest: UUID?
    /// The Appearance Preview's model: sample data it never leaves, and a
    /// Presentation Mode chosen from its menus is neither saved nor applied.
    let sampleOnly: Bool
    /// Display-only preferences. Assigning here persists them and re-gates the
    /// provider reads; initializing in `init` deliberately does not fire
    /// `didSet`, so loading saved values never writes them back.
    @Published var preferences: DisplayPreferences {
        didSet {
            precondition(Thread.isMainThread)
            guard preferences != oldValue else { return }
            preferences.save(to: defaults)
            if demo {
                // Sample data carries its own illustrative pace line.
                if preferences.showPace != oldValue.showPace { refresh() }
            } else if preferences.showCodex != oldValue.showCodex {
                // A visibility change is a connection change: any request in
                // flight must drain under its own timeout without publishing.
                generation = UUID()
                codexMessage = preferences.showCodex ? CodexReader.connectingMessage : ""
                refresh()
            } else if preferences.showClaude, !oldValue.showClaude {
                readClaude()
                refreshClaudeConnection()
            }
            if !demo, !preferences.showPace {
                claudePace = nil
                codexPace = nil
                paceSamples.removeAll()
                paceTrackers.removeAll()
            }
            // Pace adds a row to each card, and provider visibility decides whether
            // a wing carries a logo or a wider window label, so both change the
            // panel's measurements. Never let the drawn shell and the hover
            // rectangle disagree.
            if preferences.showPace != oldValue.showPace
                || preferences.showClaude != oldValue.showClaude
                || preferences.showCodex != oldValue.showCodex { onLayout?() }
        }
    }

    // Mutations and injected completions run on the main thread. Only one
    // request is in flight; a superseded request drains before its replacement.
    init(demo: Bool = false,
         sampleOnly: Bool = false,
         fetchCodex: @escaping FetchCodex = UsageModel.fetchLiveCodex,
         loadClaude: @escaping LoadClaude = UsageModel.loadLiveClaude,
         inspectClaude: @escaping (ClaudeSnapshotInfo) -> ClaudeConnection = UsageModel.liveClaudeConnection,
         defaults: UserDefaults = .standard,
         delivery: AlertDelivery? = nil) {
        self.demo = demo || sampleOnly
        self.sampleOnly = sampleOnly
        self.fetchCodex = fetchCodex
        self.loadClaude = loadClaude
        self.inspectClaude = inspectClaude
        self.defaults = defaults
        self.delivery = delivery
        self.preferences = DisplayPreferences.load(from: defaults)
        self.alertPreferences = AlertPreferences.load(from: defaults)
        self.alertState = AlertState.load(from: defaults)
        self.presentation = PresentationState.load(from: defaults)
    }
    static func liveClaudeConnection(_ snapshot: ClaudeSnapshotInfo) -> ClaudeConnection {
        ClaudeInstaller(paths: ClaudePaths.resolve(),
                        appPath: Bundle.main.executablePath ?? CommandLine.arguments[0]).connection(snapshot: snapshot)
    }
    /// What the installer needs to tell a configured integration from a live one.
    var claudeSnapshot: ClaudeSnapshotInfo {
        ClaudeSnapshotInfo(updated: claude?.updated,
                           hasWindows: !(claude?.windows.isEmpty ?? true),
                           lastEvent: claude?.lastEvent)
    }
    /// Reads configuration state only. It never writes to Claude's settings.
    func refreshClaudeConnection() {
        precondition(Thread.isMainThread)
        guard !demo, preferences.showClaude else { return }
        claudeConnection = inspectClaude(claudeSnapshot)
    }
    static func fetchLiveCodex(completion: @escaping Completion) {
        // Resolve the selected connection before leaving the main thread.
        let path = CodexReader.executable()
        DispatchQueue.global(qos: .utility).async {
            let result = Result { try CodexReader.read(path: path) }
            DispatchQueue.main.async { completion(result) }
        }
    }
    static func loadLiveClaude(completion: @escaping (UsageSnapshot?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let snapshot = (try? Data(contentsOf: Storage.claudeFile))
                .flatMap { try? JSONDecoder().decode(UsageSnapshot.self, from: $0) }
            DispatchQueue.main.async { completion(snapshot) }
        }
    }
    func start(demo: Bool) {
        timer?.invalidate()
        if self.demo != demo { toggleDemo() } else { refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.tick = Date()
            self.pollCount += 1
            // Checked on the existing tick rather than a dedicated timer, so a
            // session that lapses while the Mac is asleep still ends on wake.
            if self.presentation.until != nil, !self.presentation.isActive(at: self.tick) {
                self.presentation = PresentationState()
            }
            if !self.demo { self.readClaude() }
            if self.pollCount % 12 == 0 { self.refresh() }
        }
    }
    func readClaude() {
        precondition(Thread.isMainThread)
        // One read in flight at a time, identified so a superseded completion
        // cannot publish over a newer one. Same shape as the Codex request.
        guard !demo, preferences.showClaude, claudeRequest == nil else { return }
        let request = UUID()
        claudeRequest = request
        loadClaude { [weak self] snapshot in
            guard let self else { return }
            precondition(Thread.isMainThread)
            guard self.claudeRequest == request else { return }
            self.claudeRequest = nil
            self.acceptClaude(snapshot)
        }
    }

    private func acceptClaude(_ snapshot: UsageSnapshot?) {
        guard !demo, preferences.showClaude else { return }
        let previous = claude
        // Re-reading identical file contents must not republish or re-check.
        if snapshot != previous { claude = snapshot }
        if snapshot != previous
            || (claudeConnection == .receiving && claudeSnapshot.isStale(at: tick)) {
            refreshClaudeConnection()
        }
        evaluateAlerts()
        updatePace()
    }
    func refresh() {
        precondition(Thread.isMainThread)
        if demo {
            refreshing = false
            codexMessage = ""
            claude = UsageSnapshot(windows: [.init(label: "5-hour", used: 38, reset: Date().addingTimeInterval(8040), kind: .session, duration: 18000), .init(label: "Weekly", used: 62, reset: Date().addingTimeInterval(183600), kind: .weekly, duration: 604800)], updated: Date())
            codex = UsageSnapshot(windows: [.init(label: "5-hour", used: 21, reset: Date().addingTimeInterval(12660), kind: .session, duration: 18000), .init(label: "Weekly", used: 45, reset: Date().addingTimeInterval(367200), kind: .weekly, duration: 604800)], updated: Date())
            // Sample data is a single snapshot, so no real estimate exists.
            // These are illustrative, on a card already labelled "Sample data".
            claudePace = preferences.showPace
                ? PaceEstimate(verdict: .mayRunOut, basisMinutes: 60, projectedAtReset: 118) : nil
            codexPace = preferences.showPace
                ? PaceEstimate(verdict: .likelyToLast, basisMinutes: 45, projectedAtReset: 52) : nil
            return
        }
        readClaude()
        refreshClaudeConnection()
        // Return before touching `activeRequest`, so the drain path below
        // cannot start a replacement request while Codex is hidden.
        guard preferences.showCodex else {
            refreshing = false
            codexMessage = ""
            return
        }
        refreshing = true
        guard activeRequest == nil else { return }
        let request = UUID()
        let requestGeneration = generation
        activeRequest = request
        fetchCodex { [weak self] result in
            guard let self else { return }
            precondition(Thread.isMainThread)
            guard self.activeRequest == request else { return }
            self.activeRequest = nil
            guard !self.demo, self.generation == requestGeneration else {
                // Drain stale work without publishing its success or failure.
                if !self.demo { self.refresh() }
                return
            }
            self.refreshing = false
            switch result {
            case .success(let snapshot):
                self.codex = snapshot
                self.codexMessage = snapshot.windows.isEmpty ? CodexReader.noLimitsMessage : ""
                self.evaluateAlerts()
                self.updatePace()
            // Only Codex's own categories are shown; anything else could
            // carry a path or a system message.
            case .failure(let error):
                self.codexMessage = ((error as? CodexReader.Failure) ?? .disconnected).localizedDescription
            }
        }
    }
    func codexConnectionChanged() {
        precondition(Thread.isMainThread)
        generation = UUID()
        if !demo {
            codex = nil
            codexMessage = CodexReader.connectingMessage
            refresh()
        }
    }
    /// Only eligible readings reach the engine. Anything demo, hidden,
    /// disabled, stale or expired is filtered out here rather than inside the
    /// engine, so an ineligible window's stored state is never advanced.
    func evaluateAlerts() {
        precondition(Thread.isMainThread)
        guard !demo else { return }
        var readings: [AlertReading] = []
        for (provider, snapshot, visible) in [(AlertProvider.claude, claude, preferences.showClaude),
                                              (AlertProvider.codex, codex, preferences.showCodex)] {
            guard visible, alertPreferences.enabled(for: provider), let snapshot else { continue }
            guard Freshness.isFresh(snapshot.updated, at: tick) else { continue }
            readings += snapshot.windows.filter { !$0.expired(at: tick) }.map {
                AlertReading(provider: provider, kind: $0.resolvedKind,
                             label: $0.label, used: $0.used, reset: $0.reset)
            }
        }
        guard !readings.isEmpty else { return }
        let decision = evaluate(state: alertState, readings: readings,
                                thresholdsByProvider: alertPreferences.thresholdsByProvider,
                                resetAlerts: alertPreferences.resets, now: tick)
        guard decision.state != alertState || !decision.messages.isEmpty else { return }
        alertState = decision.state
        alertState.save(to: defaults)
        // Presentation mode discards delivery but keeps the state above, so
        // ending it never releases a backlog.
        guard !presentation.isActive(at: tick) else { return }
        for message in decision.messages { delivery?.send(message, sound: alertPreferences.sound) }
    }

    /// Wired after construction because AppDelegate owns both objects.
    func attachDelivery(_ delivery: AlertDelivery) {
        self.delivery = delivery
    }

    /// Uses the production delivery adapter without changing quota baselines.
    /// It deliberately follows presentation suppression and the sound setting,
    /// so the same button can verify those user-visible behaviours safely.
    func sendTestNotification() {
        precondition(Thread.isMainThread)
        guard !presentation.isActive(at: tick) else { return }
        delivery?.send(
            AlertMessage(provider: .codex,
                         title: "Nocci test",
                         body: "Notifications are working. Click to open the notch.",
                         identifier: "nocci.test"),
            sound: alertPreferences.sound)
    }

    /// Percentage points only. This never infers tokens or plan capacity, and
    /// every label it produces is worded as an estimate.
    private func updatePace() {
        precondition(Thread.isMainThread)
        guard preferences.showPace, !demo else { return }
        for (provider, snapshot, visible) in [("claude", claude, preferences.showClaude),
                                              ("codex", codex, preferences.showCodex)] {
            guard visible, let snapshot else { continue }
            var estimates: [PaceEstimate] = []
            for window in snapshot.windows where !window.expired(at: tick) {
                let key = "\(provider).\(window.resolvedKind.rawValue)"
                var samples = paceSamples[key] ?? []
                if samples.last?.captured != snapshot.updated {
                    samples.append(PaceSample(captured: snapshot.updated, used: window.used))
                }
                // Bounded by the two-hour lookback, which nothing older can
                // reach. A count would not do: Claude Code can deliver a new
                // reading on every five-second read while it is busy.
                samples.removeAll { snapshot.updated.timeIntervalSince($0.captured) > Pace.lookback }
                paceSamples[key] = samples
                var estimate = Pace.estimate(samples: samples, now: tick, reset: window.reset)
                var tracker = paceTrackers[key] ?? PaceTracker()
                estimate.verdict = tracker.update(estimate.verdict)
                paceTrackers[key] = tracker
                estimates.append(estimate)
            }
            let combined = estimates.isEmpty ? nil : Pace.combine(estimates)
            if provider == "claude" { claudePace = combined } else { codexPace = combined }
        }
    }

    func expand(_ value: Bool) {
        guard expanded != value else { return }
        expanded = value
        onLayout?()
    }
    func toggleDemo() {
        precondition(Thread.isMainThread)
        guard !sampleOnly else { return }
        generation = UUID()
        demo.toggle()
        claude = nil; codex = nil
        codexMessage = demo ? "" : CodexReader.connectingMessage
        refresh()
    }
}
