import Foundation
import Combine

// Drives the real Code Review model through real usage and pull request
// models, with injected scans, remotes, programs, folders and executors. No
// git, agent, terminal or account is touched; the review folder is temporary.
@main
struct CodeReviewModelTests {
    static func main() throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            guard condition() else { fatalError("FAIL: \(label)") }
            checks += 1
        }
        let suite = "nocci-code-review-model-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let manager = FileManager.default
        let temp = manager.temporaryDirectory.appendingPathComponent("nocci-review-model-" + UUID().uuidString)
        defer { try? manager.removeItem(at: temp) }
        let reviewFolder = temp.appendingPathComponent("Data/Reviews")

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let usage = UsageModel(fetchCodex: { _ in }, loadClaude: { $0(nil) },
                               inspectClaude: { _ in .notConfigured }, defaults: defaults)
        let pullRequests = PullRequestModel(usage: usage, defaults: defaults, fetch: { _, _ in }, login: { _, _ in },
                                            browse: { _ in false }, copy: { _ in }, now: { now })
        var projectSettings = ProjectSettings()
        var scanned: [[String]] = []
        var repos: [Project] = []
        var remotes: [String: [String]] = [:]
        var programs: [ProjectAgent: String] = [.claude: "/bin/claude", .codex: "/bin/codex"]
        var existing: Set<String> = []
        var prepareWorks = true
        var pending: [() -> Void] = []
        var starts: [TerminalStart] = []
        var problems: [String] = []
        var clock = now
        let model = CodeReviewModel(usage: usage, pullRequests: pullRequests, defaults: defaults,
                                    projects: { projectSettings },
                                    scanner: { roots in scanned.append(roots); return DiscoveryResult(projects: repos) },
                                    remotes: { remotes[$0] ?? [] },
                                    program: { programs[$0] },
                                    folderExists: { existing.contains($0) },
                                    reviewFolder: reviewFolder,
                                    prepare: { prepareWorks && CodeReviewModel.prepareFolder($0) },
                                    now: { clock },
                                    io: { pending.append($0) }, main: { $0() })
        model.onStart = { starts.append($0) }
        model.onProblem = { problems.append($0) }
        func drain() {
            let work = pending
            pending = []
            work.forEach { $0() }
        }
        func pr(_ number: Int, repo: String = "owner/repo") -> PullRequest {
            PullRequest(target: .github, repo: repo, number: number, title: "PR \(number)",
                        url: URL(string: "https://github.com/\(repo)/pull/\(number)")!, updated: now, roles: [.authored])
        }
        /// Each pull request's own folder under the review folder.
        func reviewed(_ item: PullRequest) -> URL { reviewFolder.appendingPathComponent(CodeReviewRules.reviewPath(for: item)) }
        // Existing checks click the same pull request again right after a
        // start; advancing the clock past `repeatGap` before each such click
        // keeps their original meaning under the new repeat-click rule.
        func click(_ item: PullRequest) {
            clock = clock.addingTimeInterval(CodeReviewModel.repeatGap + 1)
            model.review(item)
        }
        func mode(_ url: URL) throws -> Int? {
            (try manager.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
        }

        // MARK: Before pull requests are on
        check(model.settings == ReviewSettings() && !model.programFound && !model.canReview,
              "Nothing is checked before the tab shows")
        click(pr(1))
        check(pending.isEmpty && starts.isEmpty && problems.isEmpty, "Nothing starts while pull requests are off")

        // MARK: The program check
        pullRequests.settings.enabled = true
        pullRequests.tab = .pullRequests
        check(model.programFound && model.canReview && model.help == "Code review with Claude Code (experimental)",
              "Showing the tab finds the agent's program")
        programs[.claude] = nil
        usage.expand(true)
        check(!model.programFound && !model.canReview
              && model.help == "Claude Code wasn’t found. Choose it in Settings › Projects.",
              "Opening the panel on the tab checks again, and a missing program says where to choose it")
        click(pr(1))
        check(problems == ["Claude Code wasn’t found. Choose it in Settings › Projects."] && pending.isEmpty && starts.isEmpty,
              "A click without the program explains and starts nothing")
        problems = []
        model.settings.agent = .codex
        check(model.programFound && model.help == "Code review with Codex (experimental)", "Changing the agent checks its program")
        programs[.codex] = nil
        model.checkProgram()
        check(model.help == "Codex wasn’t found. Choose it in Settings › Providers.", "Codex's program is chosen in Providers")
        programs = [.claude: "/bin/claude", .codex: "/bin/codex"]
        model.settings.agent = .claude
        check(ReviewSettings.load(from: defaults).agent == .claude && model.programFound, "The agent is saved")

        // MARK: Starting in the review folder
        click(pr(42))
        check(model.resolving && !model.canReview && pending.count == 1 && starts.isEmpty,
              "A click finds the folder off the main thread and disables every button meanwhile")
        click(pr(42))
        click(pr(43))
        check(pending.count == 1, "Clicking again, or another row, while resolving starts nothing more")
        drain()
        check(starts == [TerminalStart(folder: reviewed(pr(42)).path, label: "Review owner/repo #42", agent: .claude,
                                       program: "/bin/claude", prompt: CodeReviewRules.fill(ReviewSettings.defaultPrompt, with: pr(42)))],
              "With Projects off the review starts in the review folder on the filled default prompt")
        check(scanned.isEmpty && !model.resolving && model.canReview && problems.isEmpty,
              "Projects off means no scan, and the buttons come back")
        let created = try mode(reviewed(pr(42)))
        let root = try mode(reviewFolder)
        check(created == 0o700 && root == 0o700, "The review folders are readable only by the user")
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: reviewed(pr(42)).path)
        click(pr(42))
        drain()
        let tightened = try mode(reviewed(pr(42)))
        check(tightened == 0o700, "Each review tightens it again")
        projectSettings.folders = ["/code"]
        starts = []
        click(pr(42))
        drain()
        check(scanned.isEmpty && starts.map(\.folder) == [reviewed(pr(42)).path],
              "Folders saved while Projects is off are never scanned")

        // MARK: Finding a clone
        projectSettings.enabled = true
        repos = [Project(path: "/code/plain", name: "plain", root: "/code", isRepo: false),
                 Project(path: "/code/old", name: "old", root: "/code", isRepo: true, activity: now.addingTimeInterval(-86400)),
                 Project(path: "/code/new", name: "new", root: "/code", isRepo: true, activity: now)]
        remotes = ["/code/plain": ["git@github.com:owner/plain.git"],
                   "/code/old": ["git@github.com:owner/repo.git"],
                   "/code/new": ["https://me:ghp_secret@github.com/owner/repo.git"]]
        existing = ["/code/plain", "/code/old", "/code/new"]
        starts = []
        click(pr(42))
        drain()
        check(scanned == [["/code"]] && starts.map(\.folder) == ["/code/new"],
              "The most recently active clone wins, and a plain folder is never matched")
        check(!String(describing: starts).contains("ghp_secret") && !String(describing: model.settings).contains("ghp_secret")
              && problems.isEmpty,
              "A token in a remote reaches neither the start, the settings nor a message")
        starts = []
        click(pr(9, repo: "owner/plain"))
        drain()
        check(starts.map(\.folder) == [reviewed(pr(9, repo: "owner/plain")).path],
              "A plain folder's own remote is never matched, even when it points at the pull request's repository")
        existing.remove("/code/new")
        starts = []
        click(pr(42))
        drain()
        check(starts.map(\.folder) == [reviewed(pr(42)).path], "A clone that has gone by the start falls back to the review folder")
        existing.insert("/code/new")
        starts = []
        click(pr(7, repo: "owner/other"))
        drain()
        check(starts.map(\.folder) == [reviewed(pr(7, repo: "owner/other")).path] && starts.first?.label == "Review owner/other #7",
              "A pull request with no clone uses the review folder")

        // MARK: The prompt
        model.settings.prompt = "Look at {reference}: {title}"
        starts = []
        click(pr(42))
        drain()
        check(starts.first?.prompt == "Look at #42: PR 42", "The user's prompt is filled")
        model.settings.prompt = "  \n"
        starts = []
        click(pr(42))
        drain()
        check(starts.first?.prompt == CodeReviewRules.fill(ReviewSettings.defaultPrompt, with: pr(42))
              && ReviewSettings.load(from: defaults).prompt == "  \n",
              "A blank prompt runs the default and is kept as typed")
        model.settings.prompt = "{title}"
        var huge = pr(42)
        huge.title = String(repeating: "a", count: 32_769)
        starts = []
        problems = []
        click(huge)
        check(pending.isEmpty && starts.isEmpty && problems == ["This prompt is too long. The limit is 32 KB."],
              "A refused prompt explains and starts nothing")
        // A title can no longer carry one (control characters become spaces),
        // so the NUL comes from the prompt as typed.
        model.settings.prompt = "a\u{0}b {url}"
        problems = []
        click(pr(42))
        check(problems == ["This prompt contains a character that can’t be passed on."], "A NUL character is refused")
        model.settings.prompt = ReviewSettings.defaultPrompt

        // MARK: A review folder that cannot be made
        prepareWorks = false
        starts = []
        problems = []
        click(pr(7, repo: "owner/other"))
        drain()
        check(starts.isEmpty && problems == ["Nocci couldn’t prepare the review folder."], "It is reported when it is needed")
        click(pr(42))
        drain()
        check(starts.map(\.folder) == ["/code/new"], "A found clone does not need it")
        prepareWorks = true

        // MARK: Repeat clicks
        starts = []
        problems = []
        click(pr(42))
        drain()
        check(starts.count == 1 && starts.first?.label == "Review owner/repo #42", "A click starts the review")
        let repeatStart = clock
        starts = []
        clock = repeatStart.addingTimeInterval(0.5)
        model.review(pr(42))
        check(pending.isEmpty && starts.isEmpty,
              "A second click on the same pull request half a second after its start queues and starts nothing")
        clock = repeatStart.addingTimeInterval(0.5)
        model.review(pr(43))
        drain()
        check(starts.count == 1 && starts.first?.label == "Review owner/repo #43", "A different row starts at once")
        starts = []
        clock = repeatStart.addingTimeInterval(1.5)
        model.review(pr(42))
        drain()
        check(starts.count == 1 && starts.first?.label == "Review owner/repo #42",
              "The same pull request starts again a second and a half after its start")
        starts = []
        clock = repeatStart.addingTimeInterval(5)
        model.review(pr(42))
        usage.toggleDemo()
        drain()
        check(starts.isEmpty, "A start dropped by a generation change while resolving starts nothing")
        usage.toggleDemo()
        model.review(pr(42))
        drain()
        check(starts.count == 1 && starts.first?.label == "Review owner/repo #42",
              "and records nothing, so the same pull request starts again at once")

        // MARK: Generation bumps within one resolve
        starts = []
        model.review(pr(50))
        usage.toggleDemo()
        usage.toggleDemo()
        drain()
        check(starts.isEmpty,
              "Toggling demo on then off before the resolve lands still drops that start, even though demo ends up unchanged")
        starts = []
        model.review(pr(51))
        pullRequests.settings.enabled = false
        pullRequests.settings.enabled = true
        drain()
        check(starts.isEmpty,
              "Turning Pull Requests off then on before the resolve lands still drops that start, even though the switch ends up unchanged")

        // MARK: Changes while resolving
        starts = []
        problems = []
        click(pr(42))
        usage.toggleDemo()
        drain()
        check(starts.isEmpty && !model.resolving && model.demo && !model.canReview && model.help == "Sample data",
              "Demo mode turned on while resolving drops the start")
        click(pr(42))
        check(pending.isEmpty, "Nothing starts in demo mode")
        usage.toggleDemo()
        click(pr(42))
        pullRequests.settings.enabled = false
        drain()
        check(starts.isEmpty && !model.resolving, "Turning pull requests off while resolving drops the start")
        pullRequests.settings.enabled = true
        click(pr(42))
        model.settings.agent = .codex
        drain()
        check(starts.isEmpty, "Changing the agent while resolving drops the start")
        click(pr(42))
        drain()
        check(starts.map(\.agent) == [.codex] && starts.first?.program == "/bin/codex", "The next click uses the new agent")
        model.settings.agent = .claude

        // MARK: Without a terminal
        model.onStart = nil
        check(!model.canReview, "Without Nocci's terminal the button is disabled")
        click(pr(42))
        check(pending.isEmpty, "and a click does nothing")
        model.onStart = { starts.append($0) }

        // MARK: Nothing about a pull request is stored
        let stored = String(describing: UserDefaults().persistentDomain(forName: suite) ?? [:])
        check(!stored.contains("PR 42") && !stored.contains("owner/repo") && !stored.contains("ghp_secret")
              && !stored.contains("/code/new") && stored.contains("pullRequests.review.prompt"),
              "Only the review settings are saved: no title, repository, remote or folder")

        // MARK: The appearance preview never saves
        let preview = CodeReviewModel(usage: usage, pullRequests: pullRequests, defaults: defaults, saves: false,
                                      program: { _ in nil })
        check(preview.settings == ReviewSettings.load(from: defaults), "The preview starts from the saved choices")
        preview.settings.agent = .codex
        preview.settings.prompt = "changed"
        check(ReviewSettings.load(from: defaults) == ReviewSettings(), "and never writes them")

        print("\(checks) code review model checks passed")
    }
}
