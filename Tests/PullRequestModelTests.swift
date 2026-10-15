import Foundation
import Combine

// Drives the real pull request model through a real UsageModel with injected
// fetches, logins, browser and clock. No CLI, account or network is touched.
@main
struct PullRequestModelTests {
    static func main() {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            guard condition() else { fatalError("FAIL: \(label)") }
            checks += 1
        }
        let suite = "nocci-pr-model-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { UserDefaults().removePersistentDomain(forName: suite) }

        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        typealias Done = (Result<HostResult, PullRequestFailure>) -> Void
        var fetches: [(target: PullRequestTarget, done: Done)] = []
        var logins: [(target: PullRequestTarget, done: (Result<String, PullRequestFailure>) -> Void)] = []
        var opened: [URL] = []
        var copied: [String] = []
        let usage = UsageModel(fetchCodex: { _ in }, loadClaude: { $0(nil) },
                               inspectClaude: { _ in .notConfigured }, defaults: defaults)
        let model = PullRequestModel(usage: usage, defaults: defaults,
                                     fetch: { fetches.append(($0, $1)) },
                                     login: { logins.append(($0, $1)) },
                                     browse: { opened.append($0); return true },
                                     copy: { copied.append($0) },
                                     now: { clock })
        func advance(_ seconds: TimeInterval) {
            clock = clock.addingTimeInterval(seconds)
            usage.tick = clock
        }
        func pr(_ number: Int, host: String = "github.com", forge: Forge = .github) -> PullRequest {
            let path = forge == .github ? "o/r/pull/\(number)" : "g/p/-/merge_requests/\(number)"
            return PullRequest(target: PullRequestTarget(forge: forge, host: host), repo: forge == .github ? "o/r" : "g/p",
                               number: number, title: "PR \(number)", url: URL(string: "https://\(host)/\(path)")!,
                               updated: clock, roles: [.authored])
        }
        func answer(_ items: [PullRequest], truncated: Bool = false) -> Result<HostResult, PullRequestFailure> {
            .success(HostResult(items: items, truncated: truncated))
        }
        let gitlab = PullRequestTarget(forge: .gitlab, host: "gitlab.com")

        // Off by default: nothing runs.
        advance(5)
        check(fetches.isEmpty && logins.isEmpty && model.groups.isEmpty && !model.refreshing,
              "Nothing is fetched or checked while pull requests are off")
        model.checkAccounts()
        check(logins.isEmpty && model.accounts.isEmpty, "Opening Settings with the feature off runs no CLI")
        check(model.tab == .usage, "The panel starts on Usage")

        // Enabling fetches github.com at once and checks the account.
        model.settings.enabled = true
        check(fetches.count == 1 && fetches[0].target == .github && model.refreshing, "Enabling fetches github.com at once")
        check(logins.count == 1 && model.accounts[.github] == .checking, "Enabling checks the account")
        check(PullRequestSettings.load(from: defaults).enabled, "Enabling is persisted")
        advance(5)
        check(fetches.count == 1, "A refresh in flight is never duplicated")
        fetches[0].done(answer([pr(1), pr(2)]))
        check(model.groups.count == 1 && model.groups[0].items.count == 2 && !model.refreshing
              && model.lastSuccess == clock, "A result is published grouped by repository")
        logins[0].done(.success("octo"))
        check(model.accounts[.github] == .signedIn("octo"), "The signed-in account is shown")
        fetches[0].done(answer([pr(9)]))
        check(model.groups[0].items.count == 2, "A duplicate callback cannot republish")

        // Every two minutes, counted from the last attempt.
        advance(114)
        check(fetches.count == 1, "No scheduled refresh before two minutes")
        advance(1)
        check(fetches.count == 2, "A scheduled refresh at two minutes")
        fetches[1].done(.failure(.notSignedIn))
        check(model.groups[0].items.count == 2 && model.failures[.github] == .notSignedIn && !model.refreshing,
              "A failure keeps the last good list and says why")

        // Opening the tab.
        model.tab = .pullRequests
        check(defaults.string(forKey: "panel.tab") == "pullRequests", "The tab is remembered")
        check(fetches.count == 2, "Opening the tab right after an attempt does not refresh")
        model.tab = .usage
        advance(16)
        model.tab = .pullRequests
        check(fetches.count == 3, "Opening the tab with a stale list refreshes it")
        fetches[2].done(answer([pr(1)]))
        check(model.failures.isEmpty && model.groups[0].items.count == 1 && model.lastSuccess == clock,
              "Success clears the failure and replaces the list")
        model.tab = .usage
        advance(20)
        model.tab = .pullRequests
        check(fetches.count == 3, "Opening the tab with a fresh list does not refresh")
        advance(50)
        usage.expanded = true
        check(fetches.count == 4, "Opening the panel on the pull request tab counts as opening the tab")
        fetches[3].done(answer([pr(1)]))
        usage.expanded = false

        // Manual refresh floor.
        model.refresh(reason: .manual)
        check(fetches.count == 4, "A manual refresh within 15 seconds of the last is ignored")
        advance(15)
        model.refresh(reason: .manual)
        check(fetches.count == 5, "A manual refresh after 15 seconds runs")
        fetches[4].done(answer([pr(1)]))

        // A settings change drains the refresh in flight.
        advance(120)
        check(fetches.count == 6, "Scheduled refresh")
        var settings = model.settings
        _ = settings.addGitLabHost("gitlab.com")
        model.settings = settings
        check(fetches.count == 6 && model.refreshing, "A settings change waits for the refresh in flight to drain")
        fetches[5].done(answer([pr(7)]))
        check(fetches.count == 8 && !model.groups.flatMap(\.items).contains { $0.number == 7 },
              "The drained answer is not published; one replacement starts")
        check(fetches[6].target == .github && fetches[7].target == gitlab, "The replacement asks github.com, then GitLab")

        // Hosts are independent.
        fetches[7].done(.failure(.unreachable))
        check(model.refreshing, "Still refreshing until every host answers")
        fetches[6].done(answer([pr(1), pr(3)]))
        check(model.groups.flatMap(\.items).map(\.number).sorted() == [1, 3] && model.failures == [gitlab: .unreachable],
              "One host failing never hides another host's rows")
        advance(120)
        check(fetches.count == 10, "Both hosts are asked on schedule")
        fetches[9].done(answer([pr(5, host: "gitlab.com", forge: .gitlab)], truncated: true))
        fetches[8].done(answer([pr(1)]))
        check(model.groups.count == 2 && model.groups.contains { $0.title == "g/p · gitlab.com" } && !model.truncatedTargets.isEmpty,
              "GitLab rows join the list under their host, and a full page is flagged")
        settings = model.settings
        settings.gitlabHosts = []
        model.settings = settings
        check(model.groups.count == 1 && model.truncatedTargets.isEmpty && model.failures[gitlab] == nil,
              "Removing a host drops its rows at once")
        fetches[10].done(answer([pr(1)]))

        // A new executable is a new connection for that forge only.
        settings = model.settings
        _ = settings.addGitLabHost("gitlab.com")
        model.settings = settings
        fetches[11].done(answer([pr(1)]))
        fetches[12].done(answer([pr(5, host: "gitlab.com", forge: .gitlab)]))
        model.executableChanged(.github)
        check(model.groups.count == 1 && model.groups[0].target == gitlab,
              "A new gh executable drops github.com rows and keeps GitLab's")
        check(fetches.count == 15, "and asks both hosts again")
        fetches[13].done(answer([pr(1)]))
        fetches[14].done(answer([]))

        // Opening rows.
        let link = pr(1)
        check(model.open(link) && opened == [link.url], "A row opens its exact URL")
        var foreign = pr(2)
        foreign.url = URL(string: "https://evil.example/o/r/pull/2")!
        check(!model.open(foreign) && opened.count == 1, "A link off the fetched host is never opened")

        // Demo mode.
        let inFlight = fetches.count
        advance(120)
        check(fetches.count == inFlight + 2, "Scheduled refresh before demo")
        usage.toggleDemo()
        check(model.demo && model.groups.count == 2 && !model.refreshing, "Demo shows the labelled samples")
        check(!model.open(model.groups[0].items[0]) && opened.count == 1, "Sample rows never open")
        let sample = model.groups[0].items[0]
        check(!model.canOpen(sample, .repository) && !model.open(sample, .ci) && !model.copyLink(sample)
              && opened.count == 1 && copied.isEmpty, "A sample row's menu opens and copies nothing")
        fetches[inFlight].done(answer([pr(99)]))
        fetches[inFlight + 1].done(answer([]))
        check(!model.groups.flatMap(\.items).contains { $0.number == 99 }, "A late live answer cannot replace sample data")
        advance(300)
        check(fetches.count == inFlight + 2, "Demo never runs a CLI")
        usage.toggleDemo()
        check(!model.demo && model.groups.isEmpty && fetches.count == inFlight + 4,
              "Leaving demo clears samples and fetches live data")

        // A row's menu.
        check(model.canOpen(link, .repository) && model.open(link, .repository)
              && opened.last == URL(string: "https://github.com/o/r"), "Open Repository opens the repository page")
        check(!model.canOpen(link, .ci) && !model.open(link, .ci), "Without a CI link, Open CI is disabled")
        var ciRow = pr(1)
        ciRow.ciLink = URL(string: "https://example-org.semaphoreci.com/workflows/718b")
        check(model.canOpen(ciRow, .ci) && model.open(ciRow, .ci) && opened.last == ciRow.ciLink,
              "Open CI opens the run on the CI's own host")
        check(model.copyLink(link) && copied == ["https://github.com/o/r/pull/1"], "Copy Link copies the exact URL")
        let openedBeforeForeign = opened.count
        check(!model.canOpen(foreign, .repository) && !model.open(foreign, .repository) && opened.count == openedBeforeForeign,
              "No page of a row off the fetched host is opened")

        // Turning it off.
        model.settings.enabled = false
        check(model.groups.isEmpty && !model.refreshing && model.accounts.isEmpty,
              "Turning the feature off clears the list at once")
        let off = fetches.count
        fetches[off - 2].done(answer([pr(42)]))
        fetches[off - 1].done(answer([]))
        advance(600)
        check(fetches.count == off && model.groups.isEmpty, "Nothing runs or publishes once turned off")

        // The tab survives a relaunch.
        check(PullRequestModel(usage: usage, defaults: defaults, fetch: { _, _ in }, login: { _, _ in },
                               browse: { _ in true }, now: { clock }).tab == .pullRequests,
              "The last tab is restored on launch")
        defaults.set("bogus", forKey: "panel.tab")
        check(PullRequestModel(usage: usage, defaults: defaults, fetch: { _, _ in }, login: { _, _ in },
                               browse: { _ in true }, now: { clock }).tab == .usage,
              "An unknown stored tab falls back to Usage")

        // Filtering by forge narrows what is drawn and nothing else.
        check(model.filter == .all, "The filter starts at all")
        model.settings.enabled = true
        let filterRound = fetches.count
        check(fetches[filterRound - 2].target == .github && fetches[filterRound - 1].target == gitlab,
              "Both forges refresh whatever the filter")
        fetches[filterRound - 1].done(answer([pr(5, host: "gitlab.com", forge: .gitlab)], truncated: true))
        fetches[filterRound - 2].done(answer([pr(1), pr(2)]))
        check(model.visibleGroups.count == 2 && model.visibleCount == 3 && model.visibleTruncated,
              "All shows both forges")
        model.filter = .github
        check(model.visibleGroups.map(\.target) == [.github] && model.visibleCount == 2 && !model.visibleTruncated
              && model.visibleTargets == [.github], "GitHub narrows rows, count, truncation and failures to github.com")
        check(fetches.count == filterRound && defaults.string(forKey: "pullRequests.filter") == "github",
              "Switching runs no CLI and is remembered")
        model.filter = .gitlab
        check(model.visibleCount == 1 && model.visibleTruncated && model.visibleTargets == [gitlab], "GitLab shows only GitLab")
        check(model.groups.count == 2 && !model.truncatedTargets.isEmpty, "The full list is kept underneath")
        var githubOnly = model.settings
        githubOnly.gitlabHosts = []
        model.settings = githubOnly
        check(model.activeFilter == .all && model.filter == .gitlab && model.visibleCount == 2,
              "With GitLab gone the saved choice reads as all")
        check(PullRequestModel(usage: usage, defaults: defaults, fetch: { _, _ in }, login: { _, _ in },
                               browse: { _ in true }, now: { clock }).filter == .gitlab,
              "The filter is restored on launch")
        model.settings.enabled = false

        // "Checking pull requests…" belongs to the very first refresh only, so an
        // empty or failing tile does not flicker every two minutes.
        fetches[fetches.count - 1].done(answer([]))
        model.settings.enabled = true
        check(model.refreshing && model.isCheckingFirstTime, "The first refresh shows the checking state")
        fetches[fetches.count - 1].done(.failure(.unreachable))
        advance(120)
        check(model.refreshing && !model.isCheckingFirstTime, "A retry after a failure keeps the failure text")
        fetches[fetches.count - 1].done(answer([]))
        advance(120)
        check(model.refreshing && model.visibleGroups.isEmpty && !model.isCheckingFirstTime,
              "A later refresh of an empty list keeps its text instead of flickering")
        fetches[fetches.count - 1].done(answer([]))
        model.settings.enabled = false

        // A GitLab host added later has not answered yet: it is checking, not
        // empty, and the footer names no time for it until it has.
        model.settings.enabled = true
        fetches[fetches.count - 1].done(answer([pr(1)]))
        var withNewHost = model.settings
        _ = withNewHost.addGitLabHost("gitlab.com")
        model.settings = withNewHost
        model.filter = .gitlab
        check(model.refreshing && model.isCheckingFirstTime && model.awaitingFirstAnswer,
              "A new GitLab host shows the checking state, not an empty list")
        model.filter = .all
        check(model.visibleLastSuccess == nil, "Under All the footer waits for the new host before naming a time")
        model.settings.enabled = false

        // A refresh still draining shows as one, so Refresh never looks idle
        // while it cannot start.
        var pending: [Done] = []
        let drainer = PullRequestModel(usage: usage, defaults: defaults, fetch: { pending.append($1) },
                                       login: { _, _ in }, browse: { _ in true }, now: { clock })
        drainer.settings = PullRequestSettings(enabled: true)
        check(pending.count == 1 && drainer.refreshing, "A refresh starts")
        usage.toggleDemo()
        usage.toggleDemo()
        check(drainer.refreshing && pending.count == 1, "Leaving demo while the old refresh drains still shows it refreshing")
        pending[0](answer([pr(1)]))
        check(pending.count == 2 && drainer.refreshing && drainer.groups.isEmpty,
              "The drained answer is dropped and one replacement runs")
        drainer.settings.enabled = false
        drainer.settings.enabled = true
        check(drainer.refreshing && pending.count == 2,
              "Turning the feature off and on while a refresh drains still shows it refreshing")
        pending[1](answer([pr(1)]))
        check(pending.count == 3 && drainer.refreshing, "Then one replacement runs")
        pending[2](answer([pr(1)]))
        check(!drainer.refreshing && drainer.groups.count == 1, "and its answer is shown")
        drainer.settings.enabled = false

        // The footer's time is the least fresh among the hosts the filter shows,
        // so a failing forge never reads as just updated.
        var timedFetches: [(target: PullRequestTarget, done: Done)] = []
        let timed = PullRequestModel(usage: usage, defaults: defaults, fetch: { timedFetches.append(($0, $1)) },
                                     login: { _, _ in }, browse: { _ in true }, now: { clock })
        var twoHosts = PullRequestSettings(enabled: true)
        _ = twoHosts.addGitLabHost("gitlab.com")
        timed.settings = twoHosts
        let firstAnswer = clock
        timedFetches[0].done(answer([pr(1)]))
        timedFetches[1].done(answer([pr(5, host: "gitlab.com", forge: .gitlab)]))
        advance(120)
        let secondAnswer = clock
        check(timedFetches[2].target == .github && timedFetches[3].target == gitlab, "Both hosts refresh again")
        timedFetches[2].done(answer([pr(1)]))
        timedFetches[3].done(.failure(.unreachable))
        timed.filter = .gitlab
        check(timed.visibleLastSuccess == firstAnswer, "A failing GitLab shows when GitLab last answered")
        timed.filter = .github
        check(timed.visibleLastSuccess == secondAnswer, "GitHub shows its own newer answer")
        timed.filter = .all
        check(timed.visibleLastSuccess == firstAnswer, "All shows the least fresh host")
        timed.settings.gitlabHosts = []
        check(timed.visibleLastSuccess == secondAnswer, "A removed host no longer holds the time back")
        timed.settings.enabled = false
        check(timed.visibleLastSuccess == nil, "Turning the feature off clears the time")

        // Account checks: one at a time per host, and a repeat check waits 15 seconds.
        var accountChecks: [(target: PullRequestTarget, done: (Result<String, PullRequestFailure>) -> Void)] = []
        let accounts = PullRequestModel(usage: usage, defaults: defaults, fetch: { _, _ in },
                                        login: { accountChecks.append(($0, $1)) }, browse: { _ in true }, now: { clock })
        accounts.settings = PullRequestSettings(enabled: true)
        check(accountChecks.count == 1 && accounts.accounts[.github] == .checking, "Turning it on checks the account")
        accounts.checkAccounts()
        check(accountChecks.count == 1, "Opening Settings while a check runs starts no second one")
        accountChecks[0].done(.success("octo"))
        check(accounts.accounts[.github] == .signedIn("octo"), "The answer is shown")
        advance(5)
        accounts.checkAccounts()
        check(accountChecks.count == 1 && accounts.accounts[.github] == .signedIn("octo"),
              "Opening Settings again within 15 seconds keeps the answer without a new check")
        advance(15)
        accounts.checkAccounts()
        check(accountChecks.count == 2, "After 15 seconds Settings checks again")
        accountChecks[1].done(.success("octo"))
        var withGitLab = accounts.settings
        _ = withGitLab.addGitLabHost("gitlab.com")
        accounts.settings = withGitLab
        check(accountChecks.count == 4 && accountChecks[2].target == .github && accountChecks[3].target == gitlab,
              "A settings change checks every host again")
        var withAnother = accounts.settings
        _ = withAnother.addGitLabHost("git.example.org")
        accounts.settings = withAnother
        check(accountChecks.count == 5 && accountChecks[4].target.host == "git.example.org",
              "A settings change never repeats a check still running")
        accounts.executableChanged(.github)
        check(accountChecks.count == 5, "A new gh waits for the check it replaces to finish")
        accountChecks[2].done(.success("old"))
        check(accounts.accounts[.github] == .checking && accountChecks.count == 6 && accountChecks[5].target == .github,
              "The old executable's answer is dropped and one check with the new one runs")
        accountChecks[5].done(.success("new"))
        check(accounts.accounts[.github] == .signedIn("new"), "The new executable's answer is shown")
        accounts.settings.enabled = false
        check(accounts.accounts.isEmpty, "Turning it off clears the accounts")
        accounts.settings.enabled = true
        check(accountChecks.count == 7 && accountChecks[6].target == .github
              && accounts.accounts[gitlab] == .checking,
              "Turning it back on checks idle hosts and waits for running ones")
        accountChecks[3].done(.success("stale"))
        check(accounts.accounts[gitlab] == .checking && accountChecks.count == 8 && accountChecks[7].target == gitlab,
              "An answer from before turning it off is dropped and asked again")
        accounts.settings.enabled = false

        // The appearance preview starts from the saved choices but never saves its own.
        defaults.set("usage", forKey: "panel.tab")
        PullRequestFilter.all.save(to: defaults)
        let preview = PullRequestModel(usage: usage, defaults: defaults, saves: false, fetch: { _, _ in },
                                       login: { _, _ in }, browse: { _ in true }, now: { clock })
        preview.tab = .pullRequests
        preview.filter = .gitlab
        check(defaults.string(forKey: "panel.tab") == "usage" && PullRequestFilter.load(from: defaults) == .all,
              "Switching tab or filter in the preview leaves the real choices alone")

        // --demo: a usage model created in demo mode never lets a CLI run, not
        // even once before demo starts. AppDelegate relies on this order.
        PullRequestSettings(enabled: true).save(to: defaults)
        var demoFetches = 0
        let demoUsage = UsageModel(demo: true, fetchCodex: { _ in }, loadClaude: { $0(nil) },
                                   inspectClaude: { _ in .notConfigured }, defaults: defaults)
        let demoStart = PullRequestModel(usage: demoUsage, defaults: defaults, fetch: { _, _ in demoFetches += 1 },
                                         login: { _, _ in }, browse: { _ in true }, now: { clock })
        demoUsage.start(demo: true)
        check(demoFetches == 0 && demoStart.demo && !demoStart.groups.isEmpty, "Starting in demo shows samples and runs no CLI")
        PullRequestSettings().save(to: defaults)

        // MARK: Notifications: the watch's rules
        func item(_ number: Int, _ roles: Set<PullRequestRole>, _ checks: CheckState? = nil,
                  host: String = "github.com") -> PullRequest {
            var value = pr(number, host: host, forge: host == "github.com" ? .github : .gitlab)
            value.roles = roles
            value.checks = checks
            return value
        }
        var watch = PullRequestWatch()
        check(watch.update(with: [item(1, [.reviewRequested]), item(2, [.authored], .failing)]).isEmpty,
              "The first answer is a baseline: nothing already open is announced")
        check(watch.update(with: [item(1, [.reviewRequested]), item(2, [.authored], .failing)]).isEmpty,
              "The same answer again announces nothing")
        var events = watch.update(with: [item(1, [.reviewRequested]), item(3, [.reviewRequested, .assigned]),
                                         item(2, [.authored], .failing)])
        check(events == [PullRequestEvent(kind: .reviewRequested, item: item(3, [.reviewRequested, .assigned]))],
              "A new review request is announced once")
        check(watch.update(with: [item(3, [.reviewRequested, .assigned]), item(2, [.authored], .failing)]).isEmpty
              && watch.update(with: [item(1, [.reviewRequested]), item(3, [.reviewRequested, .assigned]),
                                     item(2, [.authored], .failing)]).isEmpty,
              "A request missing from one answer is not announced again when it returns")
        _ = watch.update(with: [item(3, [.reviewRequested]), item(2, [.authored], .failing)])
        _ = watch.update(with: [item(3, [.reviewRequested]), item(2, [.authored], .failing)])
        check(watch.update(with: [item(1, [.reviewRequested]), item(3, [.reviewRequested]),
                                  item(2, [.authored], .failing)]).map(\.kind) == [.reviewRequested],
              "A request made again after two answers without it is announced, as after a review")
        check(watch.update(with: [item(1, [.assigned]), item(3, [.reviewRequested]), item(2, [.authored], .failing)]).isEmpty,
              "Losing the review role is not news")

        var ci = PullRequestWatch()
        _ = ci.update(with: [item(5, [.authored], .running), item(6, [.assigned], .running), item(7, [.authored])])
        events = ci.update(with: [item(5, [.authored], .failing), item(6, [.assigned], .failing), item(7, [.authored], .failing)])
        check(events == [PullRequestEvent(kind: .checksFailed, item: item(5, [.authored], .failing))],
              "Checks failing on the user's own pull request are announced; not on one only assigned, nor without a known state before")
        check(ci.update(with: [item(5, [.authored], .failing)]).isEmpty, "Still failing is not news")
        check(ci.update(with: [item(5, [.authored])]).isEmpty && ci.update(with: [item(5, [.authored], .failing)]).isEmpty,
              "A lookup that failed or was skipped keeps the known state, so it is not announced again")
        check(ci.update(with: [item(5, [.authored], .running)]).isEmpty, "Checks starting are not news")
        check(ci.update(with: [item(5, [.authored], .passing)]).map(\.kind) == [.checksPassed], "Checks finishing green are announced")
        check(ci.update(with: [item(5, [.authored], .failing)]).map(\.kind) == [.checksFailed],
              "Failing straight after passing, when the run was too quick to see, is announced")
        check(ci.update(with: [item(5, [.authored], .passing)]).map(\.kind) == [.checksPassed], "Passing again after a failure is announced")
        check(ci.update(with: [item(5, [.authored], .neutral)]).isEmpty && ci.update(with: [item(5, [.authored], .passing)]).isEmpty,
              "Neutral outcomes, and passing after one, are not news")
        _ = ci.update(with: [])
        check(ci.update(with: [item(5, [.authored], .failing)]).isEmpty,
              "A pull request that left the list starts again without a known state")

        let three = (1...3).map { PullRequestEvent(kind: .reviewRequested, item: item($0, [.reviewRequested])) }
        let both = PullRequestNotifications(reviews: true, checks: true)
        check(PullRequestWatch.messages(three, notifications: both).map(\.body) == ["o/r #1", "o/r #2", "o/r #3"],
              "Up to three changes notify one by one, naming the repository and number")
        check(!PullRequestWatch.messages(three, notifications: both).contains { $0.body.contains("PR ") || $0.title.contains("PR ") },
              "A notification never carries the title")
        let failed = PullRequestEvent(kind: .checksFailed, item: item(9, [.authored], .failing))
        check(PullRequestWatch.messages(three + [failed], notifications: both)
                == [AlertMessage(title: "Pull requests", body: "3 review requests and 1 finished check",
                                 identifier: "nocci.pullRequest.summary")], "More than three become one summary")
        check(PullRequestWatch.messages(three + [failed], notifications: PullRequestNotifications(reviews: false, checks: true))
                .map(\.title) == ["Checks failed"], "Only the switched-on kinds notify")
        check(PullRequestWatch.messages(three, notifications: PullRequestNotifications()).isEmpty, "Both off sends nothing")
        let gitlabEvent = PullRequestEvent(kind: .checksPassed, item: item(4, [.authored], .passing, host: "gitlab.example.com"))
        check(gitlabEvent.message.body == "g/p !4" && gitlabEvent.message.identifier == "nocci.pullRequest.checksPassed.gitlab.example.com/g/p!4",
              "A merge request reads with its own reference, and each change has one identifier")
        check(PanelTab.opened(byNotification: gitlabEvent.message.identifier) == .pullRequests
              && PanelTab.opened(byNotification: "nocci.pullRequest.summary") == .pullRequests
              && PanelTab.opened(byNotification: "nocci.session.abc") == .sessions
              && PanelTab.opened(byNotification: "nocci.alert.claude") == nil,
              "A clicked notification opens the tab it is about, and a usage alert leaves the tab alone")

        // MARK: Notifications: the model
        do {
            let suite = "nocci-pr-notify-tests-" + UUID().uuidString
            let notifyDefaults = UserDefaults(suiteName: suite)!
            defer { UserDefaults().removePersistentDomain(forName: suite) }
            final class Delivery: AlertDelivery {
                var sent: [AlertMessage] = []
                func send(_ message: AlertMessage, sound: Bool) { sent.append(message) }
            }
            let delivery = Delivery()
            var pending: [(target: PullRequestTarget, done: Done)] = []
            let notifyUsage = UsageModel(fetchCodex: { _ in }, loadClaude: { $0(nil) },
                                         inspectClaude: { _ in .notConfigured }, defaults: notifyDefaults)
            let notifying = PullRequestModel(usage: notifyUsage, defaults: notifyDefaults,
                                             fetch: { pending.append(($0, $1)) }, login: { _, _ in },
                                             browse: { _ in true }, delivery: delivery, now: { clock })
            check(notifying.notify == PullRequestNotifications(), "Notifications are off by default")
            notifying.notify.reviews = true
            check(PullRequestNotifications.load(from: notifyDefaults).reviews, "The switch is saved")
            notifying.settings.enabled = true
            func step(_ items: [PullRequest]) {
                clock = clock.addingTimeInterval(121)
                notifyUsage.tick = clock
                pending.removeLast().done(answer(items))
            }
            pending.removeLast().done(answer([item(1, [.reviewRequested])]))
            check(delivery.sent.isEmpty, "What is open when the feature starts is not announced")
            step([item(1, [.reviewRequested]), item(2, [.reviewRequested]), item(3, [.authored], .running)])
            check(delivery.sent.map(\.body) == ["o/r #2"], "A new review request is delivered")
            notifying.notify.checks = true
            notifyUsage.presentation = .untilEnded
            step([item(1, [.reviewRequested]), item(2, [.reviewRequested]), item(3, [.authored], .failing),
                  item(4, [.reviewRequested])])
            check(delivery.sent.count == 1, "Presentation Mode withholds delivery")
            notifyUsage.presentation = PresentationState()
            step([item(1, [.reviewRequested]), item(2, [.reviewRequested]), item(3, [.authored], .failing),
                  item(4, [.reviewRequested])])
            check(delivery.sent.count == 1, "Ending Presentation Mode releases no backlog")
            var withHost = notifying.settings
            _ = withHost.addGitLabHost("gitlab.example.com")
            notifying.settings = withHost
            // The refresh in flight drains; the replacement asks both hosts.
            pending.removeLast().done(answer([]))
            let replies = pending
            pending.removeAll()
            for reply in replies {
                reply.done(reply.target == .github
                           ? answer([item(1, [.reviewRequested]), item(2, [.reviewRequested]), item(3, [.authored], .failing),
                                     item(4, [.reviewRequested])])
                           : answer([item(8, [.reviewRequested], host: "gitlab.example.com")]))
            }
            check(delivery.sent.count == 1, "A newly added host's first answer is a baseline, and the kept host saw nothing new")
            notifyUsage.toggleDemo()
            notifyUsage.toggleDemo()
            let afterDemo = pending
            pending.removeAll()
            for reply in afterDemo {
                reply.done(reply.target == .github ? answer([item(1, [.reviewRequested]), item(9, [.reviewRequested])])
                                                   : answer([item(8, [.reviewRequested], host: "gitlab.example.com")]))
            }
            check(delivery.sent.count == 1, "Leaving sample data starts from a new baseline")
        }

        // The header's tabs: Usage always, then each feature that is on, in one order.
        check(PanelTab.available(pullRequests: false, sessions: false, projects: false) == [.usage],
              "Usage is the only tab when nothing else is on")
        check(PanelTab.available(pullRequests: true, sessions: true, projects: true)
                == [.usage, .pullRequests, .sessions, .projects], "Tabs keep one order")
        check(PanelTab.available(pullRequests: false, sessions: true, projects: false) == [.usage, .sessions],
              "A feature that is off has no tab")
        check(PanelTab.shown(stored: .projects, available: [.usage, .sessions]) == .usage,
              "A stored tab whose feature is off shows Usage")
        check(PanelTab.shown(stored: .sessions, available: [.usage, .sessions]) == .sessions,
              "A stored tab whose feature is on is shown")

        print("\(checks) pull-request model checks passed")
    }
}
