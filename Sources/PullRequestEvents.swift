import Foundation

/// Which pull request changes notify. Both are off until turned on in
/// Settings › Pull Requests.
struct PullRequestNotifications: Equatable {
    var reviews = false
    var checks = false

    static func load(from defaults: UserDefaults = .standard) -> PullRequestNotifications {
        PullRequestNotifications(reviews: defaults.bool(forKey: "pullRequests.notify.reviews"),
                                 checks: defaults.bool(forKey: "pullRequests.notify.checks"))
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(reviews, forKey: "pullRequests.notify.reviews")
        defaults.set(checks, forKey: "pullRequests.notify.checks")
    }
}

/// Something worth telling the user about one pull request.
struct PullRequestEvent: Equatable {
    enum Kind: Equatable { case reviewRequested, checksFailed, checksPassed }
    var kind: Kind
    var item: PullRequest

    /// The repository and reference only. A title is the author's text and
    /// stays in memory; notifications are kept by macOS on disk.
    var message: AlertMessage {
        let title: String
        switch kind {
        case .reviewRequested: title = "Review requested"
        case .checksFailed: title = "Checks failed"
        case .checksPassed: title = "Checks passed"
        }
        // `provider` is not read by the delivery; it names no usage here.
        return AlertMessage(provider: .codex, title: title, body: "\(item.repo) \(item.reference)",
                            identifier: "nocci.pullRequest.\(kind).\(item.target.host)/\(item.repo)\(item.reference)")
    }
}

/// What one host's answers have shown so far, so a change is announced once.
/// The first answer is a baseline: everything already open is old news.
struct PullRequestWatch: Equatable {
    /// Review requests seen, with how many answers in a row have missed each.
    /// A request is forgotten only after two misses, so one answer that
    /// briefly lacks a row does not announce it again, while a request made
    /// again after a review does.
    private(set) var reviews: [String: Int] = [:]
    /// The last known CI state of each of the user's own pull requests. A
    /// lookup that failed or was skipped (`checks` nil) keeps what was known.
    private(set) var checks: [String: CheckState] = [:]
    private(set) var baselined = false

    static let forgetAfterMisses = 2

    mutating func update(with items: [PullRequest]) -> [PullRequestEvent] {
        var events: [PullRequestEvent] = []
        let requested = items.filter { $0.roles.contains(.reviewRequested) }
        let requestedIDs = Set(requested.map(\.id))
        for id in reviews.keys where !requestedIDs.contains(id) {
            reviews[id, default: 0] += 1
            if reviews[id, default: 0] >= Self.forgetAfterMisses { reviews[id] = nil }
        }
        for item in requested {
            if reviews[item.id] == nil, baselined { events.append(PullRequestEvent(kind: .reviewRequested, item: item)) }
            reviews[item.id] = 0
        }
        let authored = items.filter { $0.roles.contains(.authored) }
        let authoredIDs = Set(authored.map(\.id))
        checks = checks.filter { authoredIDs.contains($0.key) }
        for item in authored {
            guard let state = item.checks else { continue }
            let known = checks[item.id]
            checks[item.id] = state
            guard baselined, let known, known != state else { continue }
            if state == .failing {
                events.append(PullRequestEvent(kind: .checksFailed, item: item))
            } else if state == .passing, known == .running || known == .failing {
                events.append(PullRequestEvent(kind: .checksPassed, item: item))
            }
        }
        baselined = true
        return events
    }

    /// More than this many at once, such as after waking from sleep, become
    /// one summary rather than a stack of banners.
    static let summaryAfter = 3

    static func messages(_ events: [PullRequestEvent], notifications: PullRequestNotifications) -> [AlertMessage] {
        let wanted = events.filter { $0.kind == .reviewRequested ? notifications.reviews : notifications.checks }
        guard wanted.count > summaryAfter else { return wanted.map(\.message) }
        let reviews = wanted.filter { $0.kind == .reviewRequested }.count
        let checks = wanted.count - reviews
        var parts: [String] = []
        if reviews > 0 { parts.append("\(reviews) review request\(reviews == 1 ? "" : "s")") }
        if checks > 0 { parts.append("\(checks) finished check\(checks == 1 ? "" : "s")") }
        return [AlertMessage(provider: .codex, title: "Pull requests", body: parts.joined(separator: " and "),
                             identifier: "nocci.pullRequest.summary")]
    }
}
