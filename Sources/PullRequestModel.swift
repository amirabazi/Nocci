import AppKit
import Combine

/// Which page the expanded panel shows while pull requests, session status or projects is on.
enum PanelTab: String { case usage, pullRequests, sessions, projects }

extension PanelTab {
    /// The tabs the panel offers, in header order. Usage is always there.
    static func available(pullRequests: Bool, sessions: Bool, projects: Bool) -> [PanelTab] {
        [.usage] + (pullRequests ? [.pullRequests] : []) + (sessions ? [.sessions] : [])
            + (projects ? [.projects] : [])
    }

    /// The stored tab, or Usage when the stored tab's feature is off.
    static func shown(stored: PanelTab, available: [PanelTab]) -> PanelTab {
        available.contains(stored) ? stored : .usage
    }

    /// The tab a clicked notification is about; nil leaves the tab alone.
    static func opened(byNotification identifier: String) -> PanelTab? {
        if identifier.hasPrefix("nocci.pullRequest.") { return .pullRequests }
        if identifier.hasPrefix("nocci.session.") { return .sessions }
        return nil
    }
}

enum AccountStatus: Equatable {
    case checking
    case signedIn(String)
    case failed(PullRequestFailure)
}

/// Owns the pull request list. It takes its clock from `UsageModel.tick` and
/// its demo state from `UsageModel.demo` instead of running a timer, the same
/// way `HistoryModel` follows the usage model.
final class PullRequestModel: ObservableObject {
    typealias Fetch = (PullRequestTarget, @escaping (Result<HostResult, PullRequestFailure>) -> Void) -> Void
    typealias Login = (PullRequestTarget, @escaping (Result<String, PullRequestFailure>) -> Void) -> Void
    enum Reason { case schedule, tab, manual }

    static let interval: TimeInterval = 120
    static let tabFreshness: TimeInterval = 60
    /// Keeps repeated clicks under GitHub's 30-a-minute search limit, and
    /// Settings shown repeatedly from checking accounts each time.
    static let minimumGap: TimeInterval = 15

    @Published var settings: PullRequestSettings {
        didSet {
            precondition(Thread.isMainThread)
            guard settings != oldValue else { return }
            if saves { settings.save(to: defaults) }
            connectionChanged(keeping: Set(settings.enabled ? settings.targets : []))
            checkAccounts(force: true)
        }
    }
    @Published var tab: PanelTab {
        didSet {
            precondition(Thread.isMainThread)
            guard tab != oldValue else { return }
            if saves { defaults.set(tab.rawValue, forKey: "panel.tab") }
            if tab == .pullRequests { refresh(reason: .tab) }
        }
    }
    /// Which changes notify. Changing it never starts a refresh, and changes
    /// are followed whether or not it is on, so turning it on announces only
    /// what happens afterwards.
    @Published var notify: PullRequestNotifications {
        didSet {
            precondition(Thread.isMainThread)
            guard notify != oldValue else { return }
            if saves { notify.save(to: defaults) }
        }
    }
    /// Display only: changing it never starts a refresh.
    @Published var filter: PullRequestFilter {
        didSet {
            precondition(Thread.isMainThread)
            guard filter != oldValue else { return }
            if saves { filter.save(to: defaults) }
        }
    }
    @Published private(set) var groups: [RepoGroup] = []
    @Published private(set) var failures: [PullRequestTarget: PullRequestFailure] = [:]
    @Published private(set) var refreshing = false
    @Published private(set) var lastSuccess: Date?
    @Published private(set) var successes: [PullRequestTarget: Date] = [:]
    /// Hosts whose answer filled a whole page for some role.
    @Published private(set) var truncatedTargets: Set<PullRequestTarget> = []
    @Published private(set) var demo = false
    @Published private(set) var accounts: [PullRequestTarget: AccountStatus] = [:]
    @Published private(set) var executables: [Forge: String] = [:]
    var onSettings: (() -> Void)?
    var onChooseExecutable: ((Forge) -> Void)?

    var activeFilter: PullRequestFilter { filter.resolved(for: settings) }
    var visibleTargets: [PullRequestTarget] { settings.targets.filter { activeFilter.includes($0) } }
    var visibleGroups: [RepoGroup] { activeFilter.apply(groups) }
    var visibleCount: Int { visibleGroups.reduce(0) { $0 + $1.items.count } }
    var visibleTruncated: Bool { truncatedTargets.contains { activeFilter.includes($0) } }
    /// A shown host has neither answered nor failed yet, such as one just added.
    var awaitingFirstAnswer: Bool { visibleTargets.contains { successes[$0] == nil && failures[$0] == nil } }
    /// The least fresh answer among the hosts the filter shows, so a failing
    /// host is never covered by another host's newer success, and none while
    /// a shown host has not answered yet.
    var visibleLastSuccess: Date? {
        awaitingFirstAnswer ? nil : visibleTargets.compactMap { successes[$0] }.min()
    }
    /// Only a shown host's first refresh shows "Checking pull requests…" in
    /// an empty tile. Later refreshes keep the tile's text; the footer shows
    /// they run.
    var isCheckingFirstTime: Bool {
        refreshing && awaitingFirstAnswer && !visibleTargets.contains { failures[$0] != nil }
    }

    private let defaults: UserDefaults
    /// False for the appearance preview, which starts from the saved choices
    /// but must never change them.
    private let saves: Bool
    private let fetch: Fetch
    private let login: Login
    private let browse: (URL) -> Bool
    private let copy: (String) -> Void
    private let now: () -> Date
    private var results: [PullRequestTarget: HostResult] = [:]
    /// Per host, so a host's first answer after it is added, or after its
    /// connection changes, is a silent baseline.
    private var watches: [PullRequestTarget: PullRequestWatch] = [:]
    private weak var usage: UsageModel?
    private let delivery: AlertDelivery?
    private var generation = UUID()
    private var activeRequest: UUID?
    private var accountsInFlight: Set<PullRequestTarget> = []
    private var staleAccounts: Set<PullRequestTarget> = []
    private var accountsCheckedAt: [PullRequestTarget: Date] = [:]
    private var lastAttempt: Date?
    private var observations = Set<AnyCancellable>()

    init(usage: UsageModel, defaults: UserDefaults = .standard, saves: Bool = true,
         fetch: @escaping Fetch = PullRequestModel.liveFetch,
         login: @escaping Login = PullRequestModel.liveLogin,
         browse: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) },
         copy: @escaping (String) -> Void = PullRequestModel.copyToPasteboard,
         delivery: AlertDelivery? = nil,
         now: @escaping () -> Date = Date.init) {
        self.usage = usage
        self.delivery = delivery
        self.defaults = defaults
        self.saves = saves
        self.fetch = fetch
        self.login = login
        self.browse = browse
        self.copy = copy
        self.now = now
        settings = PullRequestSettings.load(from: defaults)
        tab = defaults.string(forKey: "panel.tab").flatMap { PanelTab(rawValue: $0) } ?? .usage
        filter = PullRequestFilter.load(from: defaults)
        notify = PullRequestNotifications.load(from: defaults)
        reloadExecutables()
        // @Published sends before the property changes, so each sink uses the
        // value it is handed rather than reading `usage` back.
        usage.$demo.removeDuplicates().sink { [weak self] demo in self?.setDemo(demo) }.store(in: &observations)
        usage.$tick.sink { [weak self] _ in self?.refresh(reason: .schedule) }.store(in: &observations)
        usage.$expanded.removeDuplicates().sink { [weak self] expanded in
            guard let self, expanded, self.tab == .pullRequests else { return }
            self.refresh(reason: .tab)
        }.store(in: &observations)
    }

    /// One refresh at a time covers every enabled host. An answer from an
    /// older generation is drained without publishing, then one replacement
    /// starts, the same pattern Codex uses.
    func refresh(reason: Reason) {
        precondition(Thread.isMainThread)
        let date = now()
        guard !demo, settings.enabled, !settings.targets.isEmpty, activeRequest == nil else { return }
        switch reason {
        case .schedule:
            if let lastAttempt, date.timeIntervalSince(lastAttempt) < Self.interval { return }
        case .tab:
            if let lastSuccess, date.timeIntervalSince(lastSuccess) <= Self.tabFreshness { return }
            if let lastAttempt, date.timeIntervalSince(lastAttempt) < Self.minimumGap { return }
        case .manual:
            if let lastAttempt, date.timeIntervalSince(lastAttempt) < Self.minimumGap { return }
        }
        let request = UUID(), requestGeneration = generation, targets = settings.targets
        activeRequest = request
        lastAttempt = date
        refreshing = true
        var outcomes: [PullRequestTarget: Result<HostResult, PullRequestFailure>] = [:]
        for target in targets {
            fetch(target) { [weak self] outcome in
                guard let self else { return }
                precondition(Thread.isMainThread)
                guard self.activeRequest == request, outcomes[target] == nil else { return }
                outcomes[target] = outcome
                guard outcomes.count == targets.count else { return }
                self.activeRequest = nil
                guard !self.demo, self.generation == requestGeneration else {
                    self.refreshing = false
                    self.lastAttempt = nil
                    self.refresh(reason: .schedule)
                    return
                }
                self.accept(outcomes)
            }
        }
    }

    /// Sample rows never open, and neither does anything that is not an https
    /// link on the host it was fetched from.
    func canOpen(_ item: PullRequest, _ page: PullRequestPage = .pullRequest) -> Bool {
        !demo && item.openableURL(for: page) != nil
    }

    @discardableResult
    func copyLink(_ item: PullRequest) -> Bool {
        precondition(Thread.isMainThread)
        guard !demo else { return false }
        copy(item.url.absoluteString)
        return true
    }

    static func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @discardableResult
    func open(_ item: PullRequest, _ page: PullRequestPage = .pullRequest) -> Bool {
        precondition(Thread.isMainThread)
        guard !demo, let link = item.openableURL(for: page) else { return false }
        return browse(link)
    }

    /// Run when Settings shows the tab (`force` false) and after a change there
    /// (`force` true). Never on a timer, and never while the feature is off.
    /// One check runs per host at a time, and Settings shown again within
    /// `minimumGap` of a host's last answer keeps that answer.
    func checkAccounts(force: Bool = false) {
        precondition(Thread.isMainThread)
        reloadExecutables()
        guard settings.enabled else {
            accounts = [:]
            accountsCheckedAt = [:]
            staleAccounts.formUnion(accountsInFlight)
            return
        }
        let date = now()
        accounts = accounts.filter { settings.targets.contains($0.key) }
        for target in settings.targets {
            if accountsInFlight.contains(target) {
                if accounts[target] == nil { accounts[target] = .checking }
                continue
            }
            if !force, accounts[target] != nil, let checked = accountsCheckedAt[target],
               date.timeIntervalSince(checked) < Self.minimumGap { continue }
            checkAccount(target)
        }
    }

    /// An answer for a connection replaced while it ran is dropped, and one
    /// check with the new connection follows, the same drain as a refresh.
    private func checkAccount(_ target: PullRequestTarget) {
        accountsInFlight.insert(target)
        accounts[target] = .checking
        login(target) { [weak self] outcome in
            guard let self else { return }
            precondition(Thread.isMainThread)
            self.accountsInFlight.remove(target)
            let wanted = self.settings.enabled && self.settings.targets.contains(target)
            if self.staleAccounts.remove(target) != nil {
                if wanted { self.checkAccount(target) }
                return
            }
            guard wanted else { return }
            switch outcome {
            case .success(let name): self.accounts[target] = .signedIn(name)
            case .failure(let failure): self.accounts[target] = .failed(failure)
            }
            self.accountsCheckedAt[target] = self.now()
        }
    }

    func reloadExecutables() {
        precondition(Thread.isMainThread)
        var paths: [Forge: String] = [:]
        for forge in Forge.allCases { paths[forge] = ForgeCLI.executable(forge, defaults: defaults) }
        if paths != executables { executables = paths }
    }

    /// A newly chosen executable is a new connection for that forge only.
    func executableChanged(_ forge: Forge) {
        precondition(Thread.isMainThread)
        reloadExecutables()
        connectionChanged(keeping: Set(settings.enabled ? settings.targets.filter { $0.forge != forge } : []))
        staleAccounts.formUnion(accountsInFlight.filter { $0.forge == forge })
        accountsCheckedAt = accountsCheckedAt.filter { $0.key.forge != forge }
        checkAccounts(force: true)
    }

    private func setDemo(_ value: Bool) {
        precondition(Thread.isMainThread)
        guard value != demo else { return }
        demo = value
        generation = UUID()
        results.removeAll()
        watches.removeAll()
        failures.removeAll()
        successes.removeAll()
        truncatedTargets = []
        // A live request still draining keeps Refresh busy, since none can start before it ends.
        refreshing = !value && activeRequest != nil
        lastAttempt = nil
        lastSuccess = value ? now() : nil
        groups = value ? PullRequestGrouping.group(PullRequestSamples.items(now: now())) : []
        if !value { refresh(reason: .schedule) }
    }

    /// Settings or an executable changed: answers already in flight belong to
    /// the old connection and must not publish. Hosts still wanted keep their
    /// rows until a new answer replaces them.
    private func connectionChanged(keeping wanted: Set<PullRequestTarget>) {
        generation = UUID()
        results = results.filter { wanted.contains($0.key) }
        // Another account may answer now, so its first list is a baseline again.
        watches = watches.filter { wanted.contains($0.key) && results[$0.key] != nil }
        failures = failures.filter { wanted.contains($0.key) }
        successes = successes.filter { wanted.contains($0.key) }
        lastAttempt = nil
        if results.isEmpty { lastSuccess = nil }
        refreshing = settings.enabled && !demo && activeRequest != nil
        guard !demo else { return }
        publish()
        refresh(reason: .schedule)
    }

    private func accept(_ outcomes: [PullRequestTarget: Result<HostResult, PullRequestFailure>]) {
        refreshing = false
        var events: [PullRequestEvent] = []
        for (target, outcome) in outcomes {
            switch outcome {
            case .success(let result):
                var watch = watches[target] ?? PullRequestWatch()
                events += watch.update(with: result.items)
                watches[target] = watch
                results[target] = result
                failures[target] = nil
                lastSuccess = now()
                successes[target] = lastSuccess
            case .failure(let failure):
                // The host's last good list stays; the failure is shown beside it.
                failures[target] = failure
            }
        }
        publish()
        announce(events)
    }

    /// Presentation Mode withholds delivery but the watch has already moved
    /// on, so ending it never releases a backlog. Hosts in a stable order.
    private func announce(_ events: [PullRequestEvent]) {
        guard let usage, !events.isEmpty, !usage.presentation.isActive(at: now()) else { return }
        let ordered = events.sorted { ($0.item.target.host, $0.item.repo, $0.item.number) < ($1.item.target.host, $1.item.repo, $1.item.number) }
        for message in PullRequestWatch.messages(ordered, notifications: notify) {
            delivery?.send(message, sound: usage.alertPreferences.sound)
        }
    }

    private func publish() {
        let wanted = Set(settings.targets)
        let current = results.filter { wanted.contains($0.key) }.values
        groups = PullRequestGrouping.group(current.flatMap(\.items))
        truncatedTargets = Set(results.filter { wanted.contains($0.key) && $0.value.truncated }.keys)
    }

    /// Resolves the executable before leaving the main thread, like Codex, so
    /// a later selection cannot change this request's connection.
    static func liveFetch(_ target: PullRequestTarget,
                          completion: @escaping (Result<HostResult, PullRequestFailure>) -> Void) {
        let executable = ForgeCLI.executable(target.forge)
        DispatchQueue.global(qos: .utility).async {
            let result = Result<HostResult, Error> {
                switch target.forge {
                case .github: return try PullRequestReader.github(executable: executable)
                case .gitlab: return try PullRequestReader.gitlab(host: target.host, executable: executable)
                }
            }.mapError { $0 as? PullRequestFailure ?? .unreachable }
            DispatchQueue.main.async { completion(result) }
        }
    }

    static func liveLogin(_ target: PullRequestTarget,
                          completion: @escaping (Result<String, PullRequestFailure>) -> Void) {
        let executable = ForgeCLI.executable(target.forge)
        DispatchQueue.global(qos: .utility).async {
            let result = Result<String, Error> { try PullRequestReader.login(target, executable: executable) }
                .mapError { $0 as? PullRequestFailure ?? .unreachable }
            DispatchQueue.main.async { completion(result) }
        }
    }
}
