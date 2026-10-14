import Foundation

/// Where a pull request lives. GitHub means github.com only; GitLab covers
/// every host the user adds in Settings.
enum Forge: String, CaseIterable {
    case github, gitlab
    /// The executable's file name.
    var cli: String { self == .github ? "gh" : "glab" }
    var cliName: String { self == .github ? "GitHub CLI (gh)" : "GitLab CLI (glab)" }
}

/// One host Nocci asks for pull requests. Results are kept per target, so two
/// GitLab hosts never share a list.
struct PullRequestTarget: Hashable {
    var forge: Forge
    var host: String
    static let github = PullRequestTarget(forge: .github, host: "github.com")
}

/// Declared in the order a row lists them: what needs the user first.
enum PullRequestRole: Int, CaseIterable, Comparable {
    case reviewRequested, assigned, authored
    var title: String {
        switch self {
        case .reviewRequested: return "Review requested"
        case .assigned: return "Assigned"
        case .authored: return "Authored"
        }
    }
    static func < (lhs: PullRequestRole, rhs: PullRequestRole) -> Bool { lhs.rawValue < rhs.rawValue }
}

enum CheckState: Equatable { case passing, failing, running, neutral }

struct PullRequest: Equatable, Identifiable {
    var target: PullRequestTarget
    var repo: String
    var number: Int
    var title: String
    var url: URL
    var updated: Date
    var roles: Set<PullRequestRole>
    var checks: CheckState? = nil
    /// GitLab's numeric project id, needed only to ask for one merge request's pipeline.
    var projectID: Int? = nil
    /// The CI run that decided `checks`, as reported by the forge. It usually
    /// lives on the CI provider's own host, not the forge's.
    var ciLink: URL? = nil

    var id: String { url.absoluteString }
    /// GitHub numbers pull requests with `#`, GitLab merge requests with `!`.
    var reference: String { (target.forge == .github ? "#" : "!") + String(number) }
    var roleText: String { roles.sorted().map(\.title).joined(separator: ", ") }

    /// Only an https link on the host it was fetched from is ever opened.
    var isSafeToOpen: Bool { allowsOpening(url) }

    func allowsOpening(_ link: URL) -> Bool {
        guard link.scheme?.lowercased() == "https", let linkHost = link.host?.lowercased() else { return false }
        let parts = target.host.split(separator: ":")
        guard let name = parts.first, linkHost == String(name) else { return false }
        if parts.count == 2 { return link.port == Int(parts[1]) }
        return link.port == nil || link.port == 443
    }

    /// Names the CI's host, so the menu says where the link goes before it is clicked.
    var ciTitle: String { openableURL(for: .ci)?.host.map { "Open CI on \($0)" } ?? "Open CI" }

    /// The repository page is derived from the row's own URL, so no extra
    /// request is made; a URL without the expected shape gives no page rather
    /// than a guess. The CI page is the link the forge reported.
    func url(for page: PullRequestPage) -> URL? {
        switch page {
        case .pullRequest: return url
        case .ci: return ciLink
        case .repository:
            let marker = target.forge == .github ? "/pull/\(number)" : "/-/merge_requests/\(number)"
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  components.path.hasSuffix(marker), components.path.count > marker.count + 1 else { return nil }
            components.query = nil
            components.fragment = nil
            components.path = String(components.path.dropLast(marker.count))
            return components.url
        }
    }

    /// Forge pages must be on the host they were fetched from. A CI run lives
    /// on the CI provider's host, so it needs only https and no embedded
    /// credentials; the menu names its host.
    func openableURL(for page: PullRequestPage) -> URL? {
        guard let link = url(for: page) else { return nil }
        guard page == .ci else { return allowsOpening(link) ? link : nil }
        guard link.scheme?.lowercased() == "https", link.host?.isEmpty == false,
              link.user == nil, link.password == nil else { return nil }
        return link
    }
}

/// What a row's menu can open.
enum PullRequestPage { case pullRequest, repository, ci }

/// A pull request's CI state and the run that decided it.
struct CheckResult: Equatable {
    var state: CheckState?
    var link: URL? = nil
}

/// One host's answer. `truncated` is set when any role query came back full,
/// because more may exist than were shown.
struct HostResult: Equatable {
    var items: [PullRequest]
    var truncated: Bool
}

struct RepoGroup: Equatable, Identifiable {
    var target: PullRequestTarget
    var repo: String
    var items: [PullRequest]
    var id: String { "\(target.host)/\(repo)" }
    /// github.com is implied; a GitLab repository names its host.
    var title: String { target.forge == .github ? repo : "\(repo) · \(target.host)" }
}

enum GitLabHost {
    /// Accepts what people paste: `gitlab.example.com`, `https://GitLab.com/`,
    /// or a host with a port. Returns the lowercased host, or nil for plain
    /// http, a path, credentials, a query, a name without a dot, or github.com.
    /// The port is written the one way a link carries it, and 443 is dropped,
    /// because links from that host carry no port and would never open.
    static func normalize(_ text: String) -> String? {
        var host = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if host.hasPrefix("https://") { host.removeFirst("https://".count) }
        while host.hasSuffix("/") { host.removeLast() }
        let parts = host.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count <= 2, let name = parts.first, name.contains("."), name != "github.com" else { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.allSatisfy({ label in
            !label.isEmpty && !label.hasPrefix("-") && !label.hasSuffix("-")
                && label.unicodeScalars.allSatisfy { allowed.contains($0) }
        }) else { return nil }
        if parts.count == 2 {
            let digits = parts[1]
            guard !digits.isEmpty, !digits.hasPrefix("0"), digits.allSatisfy({ ("0"..."9").contains($0) }),
                  let port = Int(digits), port <= 65535 else { return nil }
            if port == 443 { return String(name) }
        }
        return host
    }
}

struct PullRequestSettings: Equatable {
    var enabled = false
    var github = true
    var gitlabHosts: [String] = []

    /// github.com first, then GitLab hosts in the order they were added.
    var targets: [PullRequestTarget] {
        (github ? [PullRequestTarget.github] : []) + gitlabHosts.map { PullRequestTarget(forge: .gitlab, host: $0) }
    }

    /// Adds a host once. False for invalid input or a host already listed.
    mutating func addGitLabHost(_ text: String) -> Bool {
        guard let host = GitLabHost.normalize(text), !gitlabHosts.contains(host) else { return false }
        gitlabHosts.append(host)
        return true
    }

    /// Read through `object(forKey:)` so an absent key means the default.
    /// Stored hosts are normalised again, so a hand-edited list cannot put a
    /// path or a duplicate into a command line.
    static func load(from defaults: UserDefaults = .standard) -> PullRequestSettings {
        var settings = PullRequestSettings()
        if let value = defaults.object(forKey: "pullRequests.enabled") as? Bool { settings.enabled = value }
        if let value = defaults.object(forKey: "pullRequests.github") as? Bool { settings.github = value }
        for host in defaults.stringArray(forKey: "pullRequests.gitlabHosts") ?? [] {
            _ = settings.addGitLabHost(host)
        }
        return settings
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: "pullRequests.enabled")
        defaults.set(github, forKey: "pullRequests.github")
        defaults.set(gitlabHosts, forKey: "pullRequests.gitlabHosts")
    }
}

enum PullRequestAge {
    private static func parts(_ updated: Date, at now: Date) -> (value: Int, unit: String, word: String)? {
        let minutes = Int(max(0, now.timeIntervalSince(updated)) / 60)
        guard minutes >= 1 else { return nil }
        if minutes < 60 { return (minutes, "m", "minute") }
        let hours = minutes / 60
        if hours < 24 { return (hours, "h", "hour") }
        let days = hours / 24
        if days < 14 { return (days, "d", "day") }
        if days < 365 { return (days / 7, "w", "week") }
        return (days / 365, "y", "year")
    }

    /// For the row: "now", "5m", "3h", "4d", "2w", "1y". A timestamp ahead of
    /// our clock reads as now rather than as the future.
    static func short(_ updated: Date, at now: Date) -> String {
        guard let age = parts(updated, at: now) else { return "now" }
        return "\(age.value)\(age.unit)"
    }

    /// For VoiceOver, which would otherwise read "3h" as a letter.
    static func spoken(_ updated: Date, at now: Date) -> String {
        guard let age = parts(updated, at: now) else { return "updated just now" }
        return "updated \(age.value) \(age.word)\(age.value == 1 ? "" : "s") ago"
    }
}

/// Every failure is reduced to one of these before it reaches the UI. CLI
/// output is inspected to classify it, never shown.
enum PullRequestFailure: Error, Equatable {
    case executableMissing, notSignedIn, timeout, unreachable, unreadable

    func message(for target: PullRequestTarget) -> String {
        switch self {
        case .executableMissing:
            return "\(target.forge.cliName) not found. Install it (brew install \(target.forge.cli)) or choose it in Settings › Pull Requests."
        case .notSignedIn:
            return target.forge == .github
                ? "Not signed in to github.com. Run gh auth login in Terminal."
                : "Not signed in to \(target.host). Run glab auth login --hostname \(target.host) in Terminal."
        case .timeout: return "\(target.host) took too long to respond."
        case .unreachable: return "Couldn't reach \(target.host)."
        case .unreadable: return "\(target.host) sent a response Nocci couldn't read."
        }
    }

    /// `gh` exits with 4 when authentication is required and reports "HTTP 401"
    /// or "401 Unauthorized" for a rejected token; `glab` reports
    /// "401 Unauthorized", and "Unauthenticated." when it has no token at all.
    /// A bare 401 is not a signal: request IDs and other numbers contain it.
    static func classify(status: Int32, stderr: String) -> PullRequestFailure {
        let text = stderr.lowercased()
        let signals = ["http 401", "unauthorized", "unauthenticated", "auth login", "not logged in"]
        if status == 4 || signals.contains(where: { text.contains($0) }) { return .notSignedIn }
        return .unreachable
    }
}

enum PullRequestCommands {
    static let limit = 50
    /// CI is looked up for at most this many pull requests per host per
    /// refresh, which keeps a busy account inside GitHub's GraphQL budget.
    static let checkLimit = 30
    static let githubFields = "number,title,url,updatedAt,repository"

    static func githubSearch(_ role: PullRequestRole) -> [String] {
        let filter: String
        switch role {
        case .authored: filter = "--author=@me"
        case .assigned: filter = "--assignee=@me"
        // `--review-requested` also matches requests made to a team. This
        // qualifier matches only requests made to the user directly.
        case .reviewRequested: filter = "user-review-requested:@me"
        }
        return ["search", "prs", filter, "--state=open", "--archived=false",
                "--limit", String(limit), "--json", githubFields]
    }

    static func githubChecks(_ url: URL) -> [String] {
        ["pr", "view", url.absoluteString, "--json", "statusCheckRollup"]
    }

    static func user(_ target: PullRequestTarget) -> [String] {
        target.forge == .github ? ["api", "user"] : ["api", "--hostname", target.host, "user"]
    }

    /// The list endpoint defaults to `scope=created_by_me`, so the reviewer
    /// query widens the scope before filtering by reviewer.
    static func gitlabList(_ role: PullRequestRole, host: String, login: String) -> [String] {
        let filter: String
        switch role {
        case .authored: filter = "scope=created_by_me"
        case .assigned: filter = "scope=assigned_to_me"
        case .reviewRequested:
            let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._")
            filter = "scope=all&reviewer_username=" + (login.addingPercentEncoding(withAllowedCharacters: safe) ?? "")
        }
        return ["api", "--hostname", host, "merge_requests?state=opened&per_page=\(limit)&\(filter)"]
    }

    static func gitlabPipeline(host: String, projectID: Int, iid: Int) -> [String] {
        ["api", "--hostname", host, "projects/\(projectID)/merge_requests/\(iid)"]
    }
}

enum PullRequestParser {
    /// `gh search prs --json number,title,url,updatedAt,repository`. A row
    /// missing a field is skipped; a response that is not a list fails.
    static func githubSearch(_ data: Data, role: PullRequestRole) throws -> [PullRequest] {
        try readable(rows(data)) { row in
            guard let number = row["number"] as? Int,
                  let title = row["title"] as? String,
                  let url = (row["url"] as? String).flatMap({ URL(string: $0) }),
                  let updated = (row["updatedAt"] as? String).flatMap(timestamp),
                  let repo = (row["repository"] as? [String: Any])?["nameWithOwner"] as? String
            else { return nil }
            return PullRequest(target: .github, repo: repo, number: number, title: title,
                               url: url, updated: updated, roles: [role])
        }
    }

    /// `glab api merge_requests?...`. The repository path comes from
    /// `references.full` ("group/sub/project!12"), which keeps subgroups.
    static func gitlabList(_ data: Data, host: String, role: PullRequestRole) throws -> [PullRequest] {
        try readable(rows(data)) { row in
            guard let iid = row["iid"] as? Int,
                  let projectID = row["project_id"] as? Int,
                  let title = row["title"] as? String,
                  let url = (row["web_url"] as? String).flatMap({ URL(string: $0) }),
                  let updated = (row["updated_at"] as? String).flatMap(timestamp),
                  let full = (row["references"] as? [String: Any])?["full"] as? String,
                  let bang = full.lastIndex(of: "!")
            else { return nil }
            return PullRequest(target: PullRequestTarget(forge: .gitlab, host: host), repo: String(full[..<bang]),
                               number: iid, title: title, url: url, updated: updated,
                               roles: [role], projectID: projectID)
        }
    }

    /// `gh pr view --json statusCheckRollup`
    static func githubChecks(_ data: Data) throws -> CheckResult {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let contexts = root["statusCheckRollup"] as? [[String: Any]] else {
            throw PullRequestFailure.unreadable
        }
        return rollup(contexts)
    }

    /// Check runs report `status` and, once complete, `conclusion`. Commit
    /// statuses report `state`. A failure anywhere wins, then anything still
    /// running, then success. Only neutral outcomes left means neutral. The
    /// link is that of a run in the winning state, so a red pull request opens
    /// its failure: `targetUrl` for a status, `detailsUrl` for a check run.
    static func rollup(_ contexts: [[String: Any]]) -> CheckResult {
        let failed: Set<String> = ["FAILURE", "ERROR", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE"]
        var runs: [(state: CheckState, link: URL?)] = []
        for context in contexts {
            let link = ((context["targetUrl"] as? String) ?? (context["detailsUrl"] as? String)).flatMap { URL(string: $0) }
            if let state = context["state"] as? String {
                runs.append((state == "SUCCESS" ? .passing : failed.contains(state) ? .failing : .running, link))
            } else if let status = context["status"] as? String, status != "COMPLETED" {
                runs.append((.running, link))
            } else if let conclusion = context["conclusion"] as? String {
                runs.append((conclusion == "SUCCESS" ? .passing : failed.contains(conclusion) ? .failing : .neutral, link))
            }
        }
        for state in [CheckState.failing, .running, .passing, .neutral] {
            let deciding = runs.filter { $0.state == state }
            if !deciding.isEmpty {
                return CheckResult(state: state, link: deciding.lazy.compactMap(\.link).first)
            }
        }
        return CheckResult(state: nil)
    }

    /// `glab api projects/:id/merge_requests/:iid`
    static func gitlabPipeline(_ data: Data) throws -> CheckResult {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PullRequestFailure.unreadable
        }
        let head = root["head_pipeline"] as? [String: Any]
        return CheckResult(state: pipeline(head?["status"] as? String),
                           link: (head?["web_url"] as? String).flatMap { URL(string: $0) })
    }

    /// No pipeline, or a status this list does not know, shows no glyph
    /// rather than a guess.
    static func pipeline(_ status: String?) -> CheckState? {
        switch status ?? "" {
        case "success": return .passing
        case "failed": return .failing
        case "created", "waiting_for_resource", "preparing", "pending", "running", "scheduled": return .running
        case "canceled", "skipped", "manual": return .neutral
        default: return nil
        }
    }

    /// `gh api user` answers with `login`; `glab api user` with `username`.
    static func login(_ data: Data) throws -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = (root["login"] as? String) ?? (root["username"] as? String), !name.isEmpty
        else { throw PullRequestFailure.unreadable }
        return name
    }

    /// GitHub sends whole seconds; GitLab sends milliseconds.
    static func timestamp(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }

    /// Rows that fail to read are skipped, but a list with rows and none
    /// readable is a changed format, not "nothing open".
    private static func readable(_ rows: [[String: Any]],
                                 _ read: ([String: Any]) -> PullRequest?) throws -> [PullRequest] {
        let items = rows.compactMap(read)
        guard !items.isEmpty || rows.isEmpty else { throw PullRequestFailure.unreadable }
        return items
    }

    private static func rows(_ data: Data) throws -> [[String: Any]] {
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw PullRequestFailure.unreadable
        }
        return rows
    }
}

enum PullRequestGrouping {
    /// One row per pull request, carrying every role it was found under and
    /// its newest update time. First-seen order is kept.
    static func merge(_ lists: [[PullRequest]]) -> [PullRequest] {
        var merged: [String: PullRequest] = [:]
        var order: [String] = []
        for item in lists.joined() {
            guard var existing = merged[item.id] else {
                merged[item.id] = item
                order.append(item.id)
                continue
            }
            existing.roles.formUnion(item.roles)
            existing.updated = max(existing.updated, item.updated)
            merged[item.id] = existing
        }
        return order.compactMap { merged[$0] }
    }

    /// Repositories ordered by their newest pull request, newest first inside
    /// each. Ties fall back to identity so identical refreshes never reshuffle.
    static func group(_ items: [PullRequest]) -> [RepoGroup] {
        Dictionary(grouping: items) { "\($0.target.host)/\($0.repo)" }.values
            .map { members -> RepoGroup in
                let sorted = members.sorted {
                    $0.updated != $1.updated ? $0.updated > $1.updated : $0.number > $1.number
                }
                return RepoGroup(target: sorted[0].target, repo: sorted[0].repo, items: sorted)
            }
            .sorted {
                $0.items[0].updated != $1.items[0].updated ? $0.items[0].updated > $1.items[0].updated : $0.id < $1.id
            }
    }
}

/// Which forge the Pull Requests tab shows. It only narrows what is drawn:
/// both forges keep refreshing, so switching never runs a CLI.
enum PullRequestFilter: String, CaseIterable {
    case all, github, gitlab

    var title: String {
        switch self {
        case .all: return "All"
        case .github: return "GitHub"
        case .gitlab: return "GitLab"
        }
    }

    var emptyText: String {
        switch self {
        case .all: return "No open pull requests or merge requests."
        case .github: return "No open pull requests on GitHub."
        case .gitlab: return "No open merge requests on GitLab."
        }
    }

    /// Offered only when github.com and at least one GitLab host are on.
    static func isAvailable(for settings: PullRequestSettings) -> Bool {
        settings.github && !settings.gitlabHosts.isEmpty
    }

    /// A saved choice is kept, but reads as all while it cannot be offered,
    /// so turning a forge off never leaves an empty list behind.
    func resolved(for settings: PullRequestSettings) -> PullRequestFilter {
        Self.isAvailable(for: settings) ? self : .all
    }

    func includes(_ target: PullRequestTarget) -> Bool {
        self == .all || target.forge.rawValue == rawValue
    }

    func apply(_ groups: [RepoGroup]) -> [RepoGroup] {
        groups.filter { includes($0.target) }
    }

    static func load(from defaults: UserDefaults = .standard) -> PullRequestFilter {
        defaults.string(forKey: "pullRequests.filter").flatMap { PullRequestFilter(rawValue: $0) } ?? .all
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: "pullRequests.filter")
    }
}

/// Shown in demo mode and the appearance preview. Never fetched, never opened.
enum PullRequestSamples {
    static func items(now: Date) -> [PullRequest] {
        let gitlab = PullRequestTarget(forge: .gitlab, host: "gitlab.com")
        return [
            PullRequest(target: .github, repo: "example/notch", number: 42,
                        title: "Fix hover race when the panel resizes",
                        url: URL(string: "https://github.com/example/notch/pull/42")!,
                        updated: now.addingTimeInterval(-12 * 60), roles: [.reviewRequested], checks: .running),
            PullRequest(target: .github, repo: "example/notch", number: 38,
                        title: "Add a pull request tab",
                        url: URL(string: "https://github.com/example/notch/pull/38")!,
                        updated: now.addingTimeInterval(-190 * 60), roles: [.authored, .assigned], checks: .passing),
            PullRequest(target: gitlab, repo: "example/api", number: 317,
                        title: "Paginate merge request search",
                        url: URL(string: "https://gitlab.com/example/api/-/merge_requests/317")!,
                        updated: now.addingTimeInterval(-25 * 3600), roles: [.authored], checks: .failing)
        ]
    }
}
