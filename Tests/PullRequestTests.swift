import Foundation

// Every pure pull request rule, with fixed dates and an isolated defaults
// suite. No CLI, account or network is touched.
@main
struct PullRequestTests {
    static func main() {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            guard condition() else { fatalError("FAIL: \(label)") }
            checks += 1
        }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func item(_ link: String, host: String = "github.com", forge: Forge = .github,
                  repo: String = "owner/repo", number: Int = 1, minutesAgo: Double = 0,
                  roles: Set<PullRequestRole> = [.authored]) -> PullRequest {
            PullRequest(target: PullRequestTarget(forge: forge, host: host), repo: repo, number: number,
                        title: "Title \(number)", url: URL(string: link)!,
                        updated: now.addingTimeInterval(-minutesAgo * 60), roles: roles)
        }

        // Host validation
        check(GitLabHost.normalize("gitlab.com") == "gitlab.com", "A bare host is accepted")
        check(GitLabHost.normalize("  https://GitLab.Example.com/ ") == "gitlab.example.com",
              "Scheme, trailing slash, case and whitespace are normalised")
        check(GitLabHost.normalize("git.corp.example:8443") == "git.corp.example:8443", "A port is kept")
        for bad in ["", "gitlab", "http://gitlab.com", "gitlab.com/group", "user@gitlab.com",
                    "gitlab.com?x=1", "git lab.com", "gitlab..com", "-gitlab.com", "gitlab.com:0",
                    "gitlab.com:70000", "gitlab.com:abc", "github.com", "https://github.com", "a.b:1:2",
                    "gitlab.com:+443", "gitlab.com:0443", "gitlab.com:-1", "gitlab.com: 443", "gitlab.com:"] {
            check(GitLabHost.normalize(bad) == nil, "Rejected host: \(bad)")
        }
        check(GitLabHost.normalize("gitlab.com:443") == "gitlab.com"
              && GitLabHost.normalize("https://gitlab.com:443/") == "gitlab.com",
              "The default https port is dropped, so its rows open like the bare host's")

        // Settings
        let suite = "nocci-pull-request-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let fresh = PullRequestSettings.load(from: defaults)
        check(!fresh.enabled && fresh.github && fresh.gitlabHosts.isEmpty,
              "Off by default, github.com ticked, no GitLab hosts")
        check(fresh.targets == [.github], "The default target is github.com")
        var edited = fresh
        check(edited.addGitLabHost("https://gitlab.com/"), "A valid host is added")
        check(!edited.addGitLabHost("GITLAB.COM"), "A duplicate host is refused")
        check(!edited.addGitLabHost("http://gitlab.example.com"), "An invalid host is refused")
        edited.enabled = true
        edited.github = false
        edited.save(to: defaults)
        check(PullRequestSettings.load(from: defaults) == edited, "Settings round-trip")
        check(edited.targets == [PullRequestTarget(forge: .gitlab, host: "gitlab.com")],
              "Unticking github.com removes it from the targets")
        defaults.set(["gitlab.com", "GitLab.com", "gitlab.com/evil", "git.example.org"], forKey: "pullRequests.gitlabHosts")
        check(PullRequestSettings.load(from: defaults).gitlabHosts == ["gitlab.com", "git.example.org"],
              "A hand-edited host list is normalised and deduplicated on load")
        defaults.set(["gitlab.com:443", "gitlab.com"], forKey: "pullRequests.gitlabHosts")
        check(PullRequestSettings.load(from: defaults).gitlabHosts == ["gitlab.com"],
              "A host saved with :443 before this rule loads as the bare host, once")
        var both = PullRequestSettings()
        _ = both.addGitLabHost("gitlab.com")
        check(both.targets.first == .github && both.targets.count == 2, "github.com is listed before GitLab hosts")

        // Opening links
        check(item("https://github.com/o/r/pull/1").isSafeToOpen, "An https link on the fetched host opens")
        check(!item("http://github.com/o/r/pull/1").isSafeToOpen, "Plain http never opens")
        check(!item("https://evil.example/o/r/pull/1").isSafeToOpen, "A link to another host never opens")
        check(item("https://github.com:443/o/r/pull/1").isSafeToOpen, "The default https port is the same host")
        check(!item("https://github.com:8443/o/r/pull/1").isSafeToOpen, "Another port is another host")
        check(item("https://git.corp.example:8443/g/p/-/merge_requests/3", host: "git.corp.example:8443",
                   forge: .gitlab).isSafeToOpen, "A GitLab host with a port opens links on that port")
        check(!item("https://git.corp.example/g/p/-/merge_requests/3", host: "git.corp.example:8443",
                    forge: .gitlab).isSafeToOpen, "A GitLab host with a port refuses links without it")
        check(!item("file:///etc/passwd").isSafeToOpen, "A file URL never opens")

        // Pages behind a row's menu
        let pr42 = item("https://github.com/o/r/pull/42", number: 42)
        check(pr42.url(for: .pullRequest) == pr42.url, "The pull request page is its own URL")
        check(pr42.openableURL(for: .repository)?.absoluteString == "https://github.com/o/r", "GitHub repository page")
        let mr12 = item("https://gitlab.com/group/sub/project/-/merge_requests/12", host: "gitlab.com", forge: .gitlab,
                        repo: "group/sub/project", number: 12)
        check(mr12.openableURL(for: .repository)?.absoluteString == "https://gitlab.com/group/sub/project",
              "A GitLab repository page keeps its subgroups")
        check(item("https://example.org/gitlab/g/p/-/merge_requests/3", host: "example.org", forge: .gitlab, number: 3)
              .url(for: .repository)?.absoluteString == "https://example.org/gitlab/g/p", "A GitLab under a sub-path keeps it")
        check(item("https://git.corp.example:8443/g/p/-/merge_requests/3", host: "git.corp.example:8443", forge: .gitlab,
                   number: 3).openableURL(for: .repository)?.absoluteString == "https://git.corp.example:8443/g/p",
              "A port is kept and the page still opens")
        check(item("https://github.com/o/r/issues/42", number: 42).url(for: .repository) == nil,
              "An unexpected shape gives no derived page")
        check(item("https://github.com/pull/42", number: 42).url(for: .repository) == nil, "A path without a repository gives none")
        check(item("https://github.com/o/r/pull/42?x=1#y", number: 42).url(for: .repository)?.absoluteString
              == "https://github.com/o/r", "A query or fragment is dropped from a derived page")
        check(item("https://evil.example/o/r/pull/42", number: 42).openableURL(for: .repository) == nil,
              "A repository page on another host is refused")

        // The CI run, which lives on the CI's own host
        var withCI = pr42
        withCI.ciLink = URL(string: "https://example-org.semaphoreci.com/workflows/718b?pipeline_id=61b8")
        check(withCI.openableURL(for: .ci) == withCI.ciLink && withCI.ciTitle == "Open CI on example-org.semaphoreci.com",
              "A CI link on another host opens over https and names its host")
        check(pr42.openableURL(for: .ci) == nil && pr42.ciTitle == "Open CI", "No CI link, nothing to open")
        for bad in ["http://example-org.semaphoreci.com/workflows/1", "https://user:secret@ci.example/run", "file:///etc/passwd",
                    "javascript:alert(1)"] {
            var risky = pr42
            risky.ciLink = URL(string: bad)
            check(risky.openableURL(for: .ci) == nil && risky.ciTitle == "Open CI", "Refused CI link: \(bad)")
        }

        // Presentation
        check(item("https://github.com/o/r/pull/42", number: 42).reference == "#42", "GitHub references use #")
        check(item("https://gitlab.com/g/p/-/merge_requests/7", host: "gitlab.com", forge: .gitlab, number: 7).reference == "!7",
              "GitLab references use !")
        check(item("https://github.com/o/r/pull/1", roles: [.authored, .reviewRequested, .assigned]).roleText
              == "Review requested, Assigned, Authored", "Roles read in attention order")
        check(RepoGroup(target: .github, repo: "o/r", items: []).title == "o/r", "github.com is implied in a group title")
        check(RepoGroup(target: PullRequestTarget(forge: .gitlab, host: "gitlab.com"), repo: "g/p", items: []).title
              == "g/p · gitlab.com", "A GitLab group names its host")

        // Age
        let ages: [(TimeInterval, String)] = [(-600, "now"), (0, "now"), (59, "now"), (60, "1m"), (3599, "59m"),
                                              (3600, "1h"), (86_399, "23h"), (86_400, "1d"), (13 * 86_400, "13d"),
                                              (14 * 86_400, "2w"), (364 * 86_400, "52w"), (365 * 86_400, "1y")]
        for (seconds, expected) in ages {
            check(PullRequestAge.short(now.addingTimeInterval(-seconds), at: now) == expected,
                  "Age \(seconds)s reads \(expected)")
        }
        check(PullRequestAge.spoken(now.addingTimeInterval(-60), at: now) == "updated 1 minute ago", "Singular spoken age")
        check(PullRequestAge.spoken(now.addingTimeInterval(-7200), at: now) == "updated 2 hours ago", "Plural spoken age")
        check(PullRequestAge.spoken(now, at: now) == "updated just now", "Spoken age under a minute")

        // Parsing
        func fails(_ body: () throws -> Any?) -> PullRequestFailure? {
            do { _ = try body(); return nil } catch { return error as? PullRequestFailure }
        }
        let search = Data("""
        [{"number":42,"title":"Fix 🚀 the notch","url":"https://github.com/o/r/pull/42","updatedAt":"2026-09-22T10:06:41Z","repository":{"name":"r","nameWithOwner":"o/r"}},
         {"number":7,"title":"No repository","url":"https://github.com/o/r/pull/7","updatedAt":"2026-09-22T10:06:41Z"}]
        """.utf8)
        let parsed = try? PullRequestParser.githubSearch(search, role: .assigned)
        check(parsed?.count == 1, "A row missing a field is skipped, the rest are kept")
        check(parsed?.first?.repo == "o/r" && parsed?.first?.number == 42 && parsed?.first?.roles == [.assigned]
              && parsed?.first?.target == .github, "GitHub fields and role are read")
        check(parsed?.first?.title == "Fix 🚀 the notch", "Titles are kept verbatim")
        check(parsed?.first?.updated == Date(timeIntervalSince1970: 1_790_071_601), "GitHub timestamps are parsed")
        check(fails { try PullRequestParser.githubSearch(Data("not json".utf8), role: .authored) } == .unreadable,
              "Output that is not JSON is unreadable")
        check(fails { try PullRequestParser.githubSearch(Data(#"{"message":"x"}"#.utf8), role: .authored) } == .unreadable,
              "An object where a list belongs is unreadable")
        check(fails { try PullRequestParser.gitlabList(Data("<html><body>Sign in</body></html>".utf8),
                                                        host: "gitlab.com", role: .authored) } == .unreadable,
              "A web page instead of JSON is unreadable, never an empty list")
        check(fails { try PullRequestParser.githubSearch(Data(#"[{"number":"42"},{"title":"x"}]"#.utf8), role: .authored) }
              == .unreadable, "A list whose every row is unreadable is an error, never an empty list")
        check(fails { try PullRequestParser.gitlabList(Data(#"[{"iid":"12"}]"#.utf8), host: "gitlab.com", role: .authored) }
              == .unreadable, "A GitLab list whose every row is unreadable is an error")
        check((try? PullRequestParser.githubSearch(Data("[]".utf8), role: .authored))?.isEmpty == true
              && (try? PullRequestParser.gitlabList(Data("[]".utf8), host: "gitlab.com", role: .authored))?.isEmpty == true,
              "An empty list is still nothing open")

        let mergeRequests = Data("""
        [{"iid":12,"project_id":99,"title":"Add MR list","web_url":"https://gitlab.com/group/sub/project/-/merge_requests/12","updated_at":"2026-09-22T10:06:41.123Z","references":{"full":"group/sub/project!12"}},
         {"iid":13,"project_id":99,"title":"No references","web_url":"https://gitlab.com/group/sub/project/-/merge_requests/13","updated_at":"2026-09-22T10:06:41.123Z"}]
        """.utf8)
        let gitlabTarget = PullRequestTarget(forge: .gitlab, host: "gitlab.com")
        let requests = try? PullRequestParser.gitlabList(mergeRequests, host: "gitlab.com", role: .reviewRequested)
        check(requests?.count == 1 && requests?.first?.repo == "group/sub/project", "Subgroups survive in the repository path")
        check(requests?.first?.number == 12 && requests?.first?.projectID == 99 && requests?.first?.target == gitlabTarget
              && requests?.first?.reference == "!12", "GitLab fields, project id and host are read")
        check(abs((requests?.first?.updated.timeIntervalSince1970 ?? 0) - 1_790_071_601.123) < 0.001,
              "Millisecond timestamps are parsed")

        // CI rollup
        func rollup(_ json: String) -> CheckState? { (try? PullRequestParser.githubChecks(Data(json.utf8)))?.state }
        func ciLink(_ json: String) -> String? { (try? PullRequestParser.githubChecks(Data(json.utf8)))?.link?.absoluteString }
        check(ciLink(#"{"statusCheckRollup":[{"__typename":"StatusContext","context":"ci/semaphoreci/pr: Test suite","state":"SUCCESS","targetUrl":"https://example-org.semaphoreci.com/workflows/718b?pipeline_id=61b8"}]}"#)
              == "https://example-org.semaphoreci.com/workflows/718b?pipeline_id=61b8",
              "A Semaphore status carries its run link")
        check(ciLink(#"{"statusCheckRollup":[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS","detailsUrl":"https://ci.example/pass"},{"__typename":"CheckRun","status":"COMPLETED","conclusion":"FAILURE","detailsUrl":"https://ci.example/fail"}]}"#)
              == "https://ci.example/fail", "The failing run's link is chosen over a passing one")
        check(ciLink(#"{"statusCheckRollup":[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS","detailsUrl":"https://ci.example/pass"},{"__typename":"CheckRun","status":"IN_PROGRESS","conclusion":null,"detailsUrl":"https://ci.example/run"}]}"#)
              == "https://ci.example/run", "A running check's link is chosen over a passing one")
        check(ciLink(#"{"statusCheckRollup":[{"__typename":"StatusContext","state":"FAILURE"},{"__typename":"StatusContext","state":"ERROR","targetUrl":"https://ci.example/error"}]}"#)
              == "https://ci.example/error", "Among runs that decide the state, one with a link is chosen")
        check(ciLink(#"{"statusCheckRollup":[{"__typename":"StatusContext","state":"SUCCESS"}]}"#) == nil,
              "A status without a link gives none")
        check(rollup(#"{"statusCheckRollup":[]}"#) == nil, "No checks means no glyph")
        check(rollup(#"{"statusCheckRollup":[{"__typename":"StatusContext","state":"SUCCESS","status":null,"conclusion":null}]}"#) == .passing,
              "A successful commit status passes (the shape seen live on 22 September 2026)")
        check(rollup(#"{"statusCheckRollup":[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"},{"__typename":"CheckRun","status":"IN_PROGRESS","conclusion":null}]}"#) == .running,
              "A check still running outranks a success")
        check(rollup(#"{"statusCheckRollup":[{"__typename":"CheckRun","status":"IN_PROGRESS","conclusion":null},{"__typename":"StatusContext","state":"ERROR"}]}"#) == .failing,
              "A failure outranks anything running")
        check(rollup(#"{"statusCheckRollup":[{"__typename":"StatusContext","state":"PENDING"}]}"#) == .running,
              "A pending status is running")
        check(rollup(#"{"statusCheckRollup":[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"TIMED_OUT"}]}"#) == .failing,
              "A timed-out run fails")
        check(rollup(#"{"statusCheckRollup":[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SKIPPED"},{"__typename":"CheckRun","status":"COMPLETED","conclusion":"CANCELLED"}]}"#) == .neutral,
              "Only skipped and cancelled runs are neutral")
        check(rollup(#"{"statusCheckRollup":[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"NEUTRAL"},{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"}]}"#) == .passing,
              "A neutral run beside a success still passes")
        check(fails { try PullRequestParser.githubChecks(Data("{}".utf8)) } == .unreadable,
              "A response without the rollup is unreadable")
        let pipelines: [(String?, CheckState?)] = [
            ("success", .passing), ("failed", .failing), ("running", .running), ("pending", .running),
            ("created", .running), ("waiting_for_resource", .running), ("preparing", .running),
            ("scheduled", .running), ("canceled", .neutral), ("skipped", .neutral), ("manual", .neutral),
            ("something_new", nil), (nil, nil)]
        for (status, expected) in pipelines {
            check(PullRequestParser.pipeline(status) == expected, "Pipeline \(status ?? "missing") maps correctly")
        }
        check((try? PullRequestParser.gitlabPipeline(Data(#"{"iid":1,"head_pipeline":{"status":"failed"}}"#.utf8)))?.state == .failing,
              "head_pipeline.status is read from a single merge request")
        let pipelineRun = try? PullRequestParser.gitlabPipeline(Data(#"{"iid":1,"head_pipeline":{"status":"running","web_url":"https://gitlab.com/g/p/-/pipelines/9"}}"#.utf8))
        check(pipelineRun?.state == .running && pipelineRun?.link?.absoluteString == "https://gitlab.com/g/p/-/pipelines/9",
              "head_pipeline.web_url is the merge request's CI link")
        check(fails { try PullRequestParser.gitlabPipeline(Data(#"{"iid":1,"head_pipeline":null}"#.utf8)) } == nil,
              "A merge request without a pipeline is not an error")

        // Accounts
        check((try? PullRequestParser.login(Data(#"{"login":"octo","id":1}"#.utf8))) == "octo", "gh reports login")
        check((try? PullRequestParser.login(Data(#"{"username":"tanuki","id":1}"#.utf8))) == "tanuki", "glab reports username")
        check(fails { try PullRequestParser.login(Data(#"{"id":1}"#.utf8)) } == .unreadable, "A user without a name is unreadable")

        // Merging and grouping
        let a1 = item("https://github.com/o/a/pull/1", repo: "o/a", number: 1, minutesAgo: 30, roles: [.authored])
        let a1Assigned = item("https://github.com/o/a/pull/1", repo: "o/a", number: 1, minutesAgo: 5, roles: [.assigned])
        let a2 = item("https://github.com/o/a/pull/2", repo: "o/a", number: 2, minutesAgo: 60, roles: [.reviewRequested])
        let b3 = item("https://github.com/o/b/pull/3", repo: "o/b", number: 3, minutesAgo: 10, roles: [.authored])
        let merged = PullRequestGrouping.merge([[a1, a2], [a1Assigned], [b3]])
        check(merged.count == 3, "A pull request found under two roles is one row")
        check(merged[0].roles == [.authored, .assigned] && merged[0].updated == a1Assigned.updated,
              "The merged row keeps every role and the newest update")
        let grouped = PullRequestGrouping.group(merged)
        check(grouped.map(\.repo) == ["o/a", "o/b"], "Repositories are ordered by their newest pull request")
        check(grouped[0].items.map(\.number) == [1, 2], "Newest first inside a repository")
        check(PullRequestGrouping.group(Array(merged.reversed())) == grouped, "Input order never changes the result")
        let sameName = [item("https://gitlab.com/g/p/-/merge_requests/1", host: "gitlab.com", forge: .gitlab, repo: "g/p"),
                        item("https://git.example.org/g/p/-/merge_requests/1", host: "git.example.org", forge: .gitlab, repo: "g/p")]
        check(PullRequestGrouping.group(sameName).count == 2, "The same path on two hosts is two groups")
        let tied = [item("https://github.com/o/z/pull/1", repo: "o/z"), item("https://github.com/o/y/pull/1", repo: "o/y")]
        check(PullRequestGrouping.group(tied).map(\.repo) == ["o/y", "o/z"], "Equal times fall back to a stable order")

        // Commands
        let review = PullRequestCommands.githubSearch(.reviewRequested)
        check(review.contains("user-review-requested:@me") && !review.contains { $0.hasPrefix("--review-requested") },
              "Review requests are direct only, never team requests")
        check(PullRequestCommands.githubSearch(.authored).contains("--author=@me")
              && PullRequestCommands.githubSearch(.assigned).contains("--assignee=@me"), "Author and assignee filters")
        check(review.contains("--state=open") && review.contains("--archived=false") && review.contains("50")
              && review.contains(PullRequestCommands.githubFields), "Open, unarchived, 50 results, fixed fields")
        check(PullRequestCommands.githubChecks(URL(string: "https://github.com/o/r/pull/1")!)
              == ["pr", "view", "https://github.com/o/r/pull/1", "--json", "statusCheckRollup"],
              "One CI lookup per pull request")
        check(PullRequestCommands.gitlabList(.reviewRequested, host: "gitlab.com", login: "a.b-c_d").last
              == "merge_requests?state=opened&per_page=50&scope=all&reviewer_username=a.b-c_d",
              "The reviewer query widens the scope first")
        check(PullRequestCommands.gitlabList(.reviewRequested, host: "gitlab.com", login: "x&scope=all").last?
              .hasSuffix("reviewer_username=x%26scope%3Dall") == true, "A login cannot add query parameters")
        check(PullRequestCommands.gitlabList(.authored, host: "h.example", login: "x")
              == ["api", "--hostname", "h.example", "merge_requests?state=opened&per_page=50&scope=created_by_me"],
              "Authored merge requests on the chosen host")
        check(PullRequestCommands.gitlabList(.assigned, host: "h.example", login: "x").last?
              .hasSuffix("scope=assigned_to_me") == true, "Assigned merge requests")
        check(PullRequestCommands.gitlabPipeline(host: "h.example", projectID: 99, iid: 12)
              == ["api", "--hostname", "h.example", "projects/99/merge_requests/12"], "One pipeline lookup per merge request")
        check(PullRequestCommands.user(.github) == ["api", "user"]
              && PullRequestCommands.user(gitlabTarget) == ["api", "--hostname", "gitlab.com", "user"], "Account lookups")

        // Failures
        check(PullRequestFailure.classify(status: 4, stderr: "") == .notSignedIn, "gh's authentication exit status")
        check(PullRequestFailure.classify(status: 1, stderr: "GET https://gitlab.com/api/v4/user: 401 {message: 401 Unauthorized}")
              == .notSignedIn, "glab's 401 on stderr")
        check(PullRequestFailure.classify(status: 1, stderr: "          \n   ERROR  \n          \n  Unauthenticated.  \n\n")
              == .notSignedIn, "glab api without a token (glab 1.89.0 output, seen live on 22 September 2026)")
        check(PullRequestFailure.classify(status: 1, stderr: "dial tcp: lookup gitlab.com: no such host") == .unreachable,
              "Anything else is unreachable")
        check(PullRequestFailure.classify(status: 1, stderr: "gh: Bad credentials (HTTP 401)") == .notSignedIn,
              "gh api with a rejected token (gh output, captured 23 September 2026)")
        check(PullRequestFailure.classify(status: 1, stderr: #"non-200 OK status code: 401 Unauthorized body: "{\r\n  \"message\": \"Bad credentials\"}""#)
              == .notSignedIn, "gh search with a rejected token (gh output, captured 23 September 2026)")
        check(PullRequestFailure.classify(status: 1, stderr: "HTTP 502: Server Error (https://api.github.com/graphql)\nrequest ID C0DE:401A:3F2B401:4401")
              == .unreachable, "A 401 inside a request ID is not a sign-in failure")
        check(PullRequestFailure.classify(status: 1, stderr: "GraphQL: Something went wrong (request 1401)") == .unreachable,
              "A number that merely contains 401 is not a sign-in failure")
        check(PullRequestFailure.notSignedIn.message(for: gitlabTarget)
              == "Not signed in to gitlab.com. Run glab auth login --hostname gitlab.com in Terminal.",
              "GitLab sign-in guidance names the host")
        check(PullRequestFailure.executableMissing.message(for: .github) == "GitHub CLI (gh) not found. Install it (brew install gh) or choose it in Settings › Pull Requests.",
              "A missing executable points to Settings")
        for failure in [PullRequestFailure.executableMissing, .notSignedIn, .timeout, .unreachable, .unreadable] {
            let message = failure.message(for: gitlabTarget)
            check(!message.contains("\u{2014}") && !message.contains("\u{2013}"), "Failure text uses plain punctuation")
        }

        // Samples
        let samples = PullRequestSamples.items(now: now)
        check(samples.count == 3 && Set(samples.map(\.target.forge)) == [.github, .gitlab], "Samples cover both forges")
        check(PullRequestGrouping.group(samples).count == 2, "Samples fill two repository groups")

        // Filter
        var twoForges = PullRequestSettings()
        _ = twoForges.addGitLabHost("gitlab.com")
        var gitlabOnly = twoForges
        gitlabOnly.github = false
        check(PullRequestFilter.isAvailable(for: twoForges), "The filter is offered with github.com and a GitLab host on")
        check(!PullRequestFilter.isAvailable(for: PullRequestSettings()) && !PullRequestFilter.isAvailable(for: gitlabOnly),
              "The filter is not offered with only one forge on")
        check(PullRequestFilter.gitlab.resolved(for: twoForges) == .gitlab, "A choice stands while both forges are on")
        check(PullRequestFilter.github.resolved(for: gitlabOnly) == .all
              && PullRequestFilter.gitlab.resolved(for: PullRequestSettings()) == .all,
              "A choice for a forge that is off reads as all")
        let sampleGroups = PullRequestGrouping.group(samples)
        check(PullRequestFilter.all.apply(sampleGroups) == sampleGroups, "All shows every group")
        check(PullRequestFilter.github.apply(sampleGroups).map(\.repo) == ["example/notch"], "GitHub shows only github.com groups")
        check(PullRequestFilter.gitlab.apply(sampleGroups).map(\.repo) == ["example/api"], "GitLab shows only GitLab groups")
        check(PullRequestFilter.gitlab.includes(PullRequestTarget(forge: .gitlab, host: "git.example.org"))
              && !PullRequestFilter.gitlab.includes(.github) && PullRequestFilter.all.includes(.github),
              "GitLab covers every GitLab host; all covers everything")
        check(PullRequestFilter.all.emptyText == "No open pull requests or merge requests."
              && PullRequestFilter.github.emptyText == "No open pull requests on GitHub."
              && PullRequestFilter.gitlab.emptyText == "No open merge requests on GitLab.", "Empty text names the forge")
        check(PullRequestFilter.all.title == "All" && PullRequestFilter.github.title == "GitHub"
              && PullRequestFilter.gitlab.title == "GitLab", "Each choice has a spoken title")
        check(PullRequestFilter.load(from: defaults) == .all, "The filter starts at all")
        PullRequestFilter.gitlab.save(to: defaults)
        check(PullRequestFilter.load(from: defaults) == .gitlab, "The filter round-trips")
        defaults.set("bogus", forKey: "pullRequests.filter")
        check(PullRequestFilter.load(from: defaults) == .all, "An unknown stored filter reads as all")
        print("\(checks) pull-request checks passed")
    }
}
