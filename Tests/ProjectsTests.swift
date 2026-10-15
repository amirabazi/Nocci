import Foundation

// Every pure Projects rule, over made-up folder trees, fixed dates and an
// isolated defaults suite. No real folder, app or program is touched.
@main
struct ProjectsTests {
    static func main() {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            guard condition() else { fatalError("FAIL: \(label)") }
            checks += 1
        }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let home = "/Users/someone"
        func folder(_ name: String, git: Bool = false) -> FolderEntry { FolderEntry(name: name, isFolder: true, hasGit: git) }
        func other(_ name: String) -> FolderEntry { FolderEntry(name: name, isFolder: false, hasGit: false) }
        func project(_ name: String, repo: Bool = true, minutes: Double? = nil, root: String = "/r") -> Project {
            Project(path: root + "/" + name, name: name, root: root, isRepo: repo,
                    activity: minutes.map { now.addingTimeInterval(-$0 * 60) })
        }

        // MARK: Discovery
        let tree: [String: FolderListing] = [
            "/c": FolderListing(entries: [folder("api", git: true), folder("group"), folder("notes"),
                                          other("Tool.app"), other("link"), other("readme.md")]),
            "/c/group": FolderListing(entries: [folder("app", git: true), folder("backend", git: true),
                                                folder("docs"), other("todo.txt")]),
            "/c/notes": FolderListing(entries: [folder("drafts")]),
            "/c/notes/drafts": FolderListing(entries: [folder("deep", git: true)]),
            "/w": FolderListing(entries: [folder("api", git: true)]),
        ]
        var listed: [String] = [], asked: [String] = []
        let times = ["/c/api": now.addingTimeInterval(-60), "/c/group/app": now.addingTimeInterval(-7200)]
        let found = ProjectRules.discover(roots: ["/c", "/w", "/missing"],
                                          list: { listed.append($0); return tree[$0] },
                                          activity: { asked.append($0); return times[$0] })
        check(found.projects.map(\.path) == ["/c/api", "/c/group/app", "/c/group/backend", "/c/notes", "/w/api"],
              "Repos, repos inside a plain folder, and plain folders are found in listing order")
        check(found.projects.map(\.name) == ["api", "group / app", "group / backend", "notes", "api"],
              "A repo inside a plain folder is named Group / repo")
        check(found.projects.map(\.isRepo) == [true, true, true, false, true], "Only folders with .git are repos")
        check(found.projects.map(\.root) == ["/c", "/c", "/c", "/c", "/w"], "Each project remembers its chosen folder")
        check(found.projects[0].activity == times["/c/api"] && found.projects[2].activity == nil
              && found.projects[3].activity == nil, "Activity comes from the scanner, for repos only")
        check(Set(asked) == ["/c/api", "/c/group/app", "/c/group/backend", "/w/api"],
              "Plain folders are never asked about activity")
        check(!listed.contains("/c/notes/drafts") && !listed.contains("/c/api"),
              "Nothing below the second level is listed, and a repo is never listed into")
        check(found.folders == ["/c": .available, "/w": .available, "/missing": .notAvailable],
              "A missing chosen folder is reported and the others are available")
        check(!found.projects.contains { ["docs", "Tool.app", "link", "readme.md", "todo.txt", "deep"]
                .contains(ProjectRules.lastComponent($0.path)) },
              "Plain folders beside repos, anything deeper, and anything that is not a real folder are never listed")

        let overlap = ProjectRules.discover(roots: ["/c", "/c/group"], list: { tree[$0] }, activity: { _ in nil })
        check(overlap.projects.filter { $0.path == "/c/group/app" }.map(\.root) == ["/c"],
              "A project reached through two chosen folders is listed once, under the first")
        check(overlap.projects.last?.path == "/c/group/docs", "The second chosen folder still adds what only it reaches")

        let cut = ProjectRules.discover(roots: ["/t"], list: { path in
            switch path {
            case "/t": return FolderListing(entries: [folder("a"), folder("b", git: true)])
            case "/t/a": return FolderListing(entries: [folder("r", git: true)], truncated: true)
            default: return nil
            }
        }, activity: { _ in nil })
        check(cut.folders["/t"] == .truncated && cut.projects.map(\.name) == ["a / r", "b"],
              "A cut-short listing inside a chosen folder marks that folder cut short and keeps what was found")
        // The home folder's own folders are never read: macOS asks the user
        // before Nocci may list Desktop, Documents or Downloads.
        var listedPaths: [String] = []
        let homeTree: [String: FolderListing] = [
            "/Users/x": FolderListing(entries: [FolderEntry(name: "Code", isFolder: true, hasGit: false),
                                                FolderEntry(name: "Desktop", isFolder: true, hasGit: false),
                                                FolderEntry(name: "Documents", isFolder: true, hasGit: false),
                                                FolderEntry(name: "Downloads", isFolder: true, hasGit: false),
                                                FolderEntry(name: "Library", isFolder: true, hasGit: false),
                                                FolderEntry(name: "dotfiles", isFolder: true, hasGit: true)], truncated: false),
            "/Users/x/Code": FolderListing(entries: [FolderEntry(name: "api", isFolder: true, hasGit: true)], truncated: false)]
        let fromHome = ProjectRules.discover(roots: ["/Users/x"], list: { listedPaths.append($0); return homeTree[$0] },
                                             activity: { _ in nil }, home: "/Users/x")
        check(fromHome.projects.map(\.name).sorted() == ["Code / api", "dotfiles"],
              "Choosing the home folder lists its projects and none of its standard folders")
        check(!listedPaths.contains { ["/Users/x/Desktop", "/Users/x/Documents", "/Users/x/Downloads", "/Users/x/Library"].contains($0) },
              "Desktop, Documents, Downloads and Library are never listed from the home folder")
        let cutRoot = ProjectRules.discover(roots: ["/t"], list: { $0 == "/t" ? FolderListing(entries: [], truncated: true) : nil },
                                            activity: { _ in nil })
        check(cutRoot.folders["/t"] == .truncated, "A cut-short chosen folder is marked cut short")
        check(ProjectRules.join("/", "x") == "/x" && ProjectRules.join("/a", "x") == "/a/x", "Paths join without doubled slashes")

        // MARK: Order
        let shuffled = [project("zeta", repo: false), project("old", minutes: 600), project("Beta"),
                        project("new", minutes: 5), project("alpha", repo: false), project("alpha2"),
                        project("file10", repo: false), project("file9", repo: false)]
        check(ProjectRules.ordered(shuffled).map(\.name) == ["new", "old", "alpha2", "Beta", "alpha", "file9", "file10", "zeta"],
              "Repos by newest activity, then repos without a time, then plain folders, each in Finder order")
        check(ProjectRules.ordered([project("x", repo: false, root: "/b"), project("x", repo: false, root: "/a")]).map(\.path)
              == ["/a/x", "/b/x"], "Equal names fall back to the path, so the order is stable")

        // MARK: Labels
        let labelled = ProjectRules.labels(for: [
            project("api", root: home + "/Coding"), project("api", root: home + "/Work"),
            project("web", root: home + "/Coding"), project("tool", repo: false, root: "/Volumes/Old/Code"),
            project("tool", repo: false, root: home + "/Code")], home: home)
        check(labelled[home + "/Coding/web"] == "web", "A unique name is the whole label")
        check(labelled[home + "/Coding/api"] == "api · Coding" && labelled[home + "/Work/api"] == "api · Work",
              "Clashing names add their chosen folder's name")
        check(labelled["/Volumes/Old/Code/tool"] == "tool · /Volumes/Old/Code" && labelled[home + "/Code/tool"] == "tool · ~/Code",
              "When the folder names clash too, the folder's path is added, shortened with ~")
        check(ProjectRules.abbreviate(home, home: home) == "~" && ProjectRules.abbreviate(home + "/x", home: home) == "~/x"
              && ProjectRules.abbreviate(home + "x/y", home: home) == home + "x/y",
              "Only the home folder and paths inside it are shortened")

        // MARK: .git files
        check(ProjectRules.gitDirectory(dotGitFile: "gitdir: /r/main/.git/worktrees/feature\n", project: "/r/feature")
              == "/r/main/.git/worktrees/feature", "An absolute gitdir is used as written")
        check(ProjectRules.gitDirectory(dotGitFile: "gitdir: ../main/.git/modules/lib\r\n", project: "/r/app/lib")
              == "/r/app/main/.git/modules/lib", "A relative gitdir resolves against the project")
        for bad in ["", "ref: refs/heads/main", "gitdir:", "gitdir:   \n", "\ngitdir: /x"] {
            check(ProjectRules.gitDirectory(dotGitFile: bad, project: "/r/p") == nil,
                  "No gitdir on the first line points nowhere: \(bad.debugDescription)")
        }

        // MARK: Text
        let coding = home + "/Coding", work = home + "/Work"
        check(ProjectRules.footer(count: 12, folders: [coding, work], states: [:], home: home) == "12 projects in ~/Coding, ~/Work",
              "The footer names up to two folders")
        check(ProjectRules.footer(count: 1, folders: [coding], states: [:], home: home) == "1 project in ~/Coding",
              "One project is singular")
        check(ProjectRules.footer(count: 3, folders: ["/a", "/b", "/c"], states: ["/b": .truncated, "/c": .notAvailable], home: home)
              == "3 projects in 3 folders · list cut short · /c not available",
              "Three or more folders are counted, and a cut-short or missing folder is mentioned")
        check(ProjectRules.footer(count: 0, folders: [], states: [:], home: home) == "No folders chosen", "No folders chosen")
        check(ProjectRules.emptyText(folders: [], states: [:], scanned: false, home: home) == "Add a folder in Settings › Projects.",
              "With no folders the tile points to Settings")
        check(ProjectRules.emptyText(folders: [coding], states: [:], scanned: false, home: home) == "Reading folders…",
              "Before the first scan finishes the tile says it is reading")
        check(ProjectRules.emptyText(folders: [coding], states: [coding: .notAvailable], scanned: true, home: home)
              == "~/Coding isn’t available.", "A single missing folder is named")
        check(ProjectRules.emptyText(folders: [coding, work], states: [coding: .notAvailable, work: .notAvailable], scanned: true, home: home)
              == "None of your project folders are available.", "Several missing folders are summarised")
        check(ProjectRules.emptyText(folders: [coding], states: [coding: .available], scanned: true, home: home)
              == "No projects in ~/Coding.", "An empty folder says so")
        check(ProjectRules.emptyText(folders: [coding, work], states: [:], scanned: true, home: home)
              == "No projects in your folders.", "Several empty folders say so")

        // MARK: Samples
        let samples = ProjectSamples.projects(now: now)
        check(samples.count == 4 && Set(samples.map(\.path)).count == 4 && samples.contains { !$0.isRepo }
              && samples.contains { $0.name.contains(" / ") }, "Samples cover repos, a grouped repo and a plain folder")
        check(ProjectRules.ordered(samples) == samples, "Samples are already in list order")
        check(samples.allSatisfy { $0.path.hasPrefix("/Users/someone/") }, "Samples use a neutral example folder")

        // MARK: Settings
        let suite = "nocci-projects-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        check(ProjectSettings.load(from: defaults) == ProjectSettings(),
              "Off, no folders, Claude Code and no remembered apps by default")
        var settings = ProjectSettings()
        check(settings.addFolder(home + "/Coding/"), "A folder is added")
        check(settings.folders == [home + "/Coding"], "Folders are stored without a trailing slash")
        check(!settings.addFolder(home + "/Coding") && !settings.addFolder(home + "/./Coding"),
              "The same folder is refused however it is written")
        check(!settings.addFolder("Coding") && !settings.addFolder(""), "Only absolute paths are accepted")
        settings.enabled = true
        settings.addFolder(home + "/Work")
        settings.agent = .codex
        settings.setTarget(.iterm, for: .claude)
        settings.setTarget(.codexApp, for: .codex)
        settings.save(to: defaults)
        check(ProjectSettings.load(from: defaults) == settings, "Settings survive a save and load")
        check(defaults.stringArray(forKey: "projects.folders") == [home + "/Coding", home + "/Work"]
              && defaults.string(forKey: "projects.app.claude") == "iterm"
              && defaults.string(forKey: "projects.app.codex") == "codexApp"
              && defaults.string(forKey: "projects.agent") == "codex", "Settings are stored under the projects keys")
        check(settings.target(for: .claude) == .iterm && settings.target(for: .codex) == .codexApp,
              "Each agent keeps its own app")
        settings.claudeTarget = nil
        settings.save(to: defaults)
        check(defaults.object(forKey: "projects.app.claude") == nil, "Clearing a remembered app removes its key")
        defaults.set("bogus", forKey: "projects.agent")
        defaults.set("bogus", forKey: "projects.app.codex")
        defaults.set(["/a", "relative", "/a/", "/b"], forKey: "projects.folders")
        let recovered = ProjectSettings.load(from: defaults)
        check(recovered.agent == .claude && recovered.codexTarget == nil, "Unknown stored values fall back to the defaults")
        check(recovered.folders == ["/a", "/b"], "Stored folders are normalised and deduplicated again on load")

        // MARK: Targets
        check(LaunchTarget.allCases.filter { $0.supports(.claude) } == [.terminal, .iterm, .otherTerminal, .vscode, .nocci],
              "Claude Code opens in terminals, VS Code and Nocci")
        check(LaunchTarget.allCases.filter { $0.supports(.codex) } == [.terminal, .iterm, .otherTerminal, .codexApp, .nocci],
              "Codex opens in terminals, the Codex app and Nocci")
        check(LaunchTarget.allCases.filter(\.isTerminal) == [.terminal, .iterm, .otherTerminal], "Three terminal targets")
        check(LaunchTarget.terminal.bundleIdentifier == "com.apple.Terminal" && LaunchTarget.iterm.bundleIdentifier == "com.googlecode.iterm2"
              && LaunchTarget.vscode.bundleIdentifier == "com.microsoft.VSCode" && LaunchTarget.otherTerminal.bundleIdentifier == nil,
              "Known apps are found by bundle identifier")
        check(ProjectRules.resolvedTarget(stored: .iterm, agent: .claude, available: [.terminal, .iterm]) == .iterm,
              "A remembered, installed app is used")
        check(ProjectRules.resolvedTarget(stored: .iterm, agent: .claude, available: [.vscode, .terminal]) == .terminal,
              "A remembered app that is gone falls back to the first installed one in preference order")
        check(ProjectRules.resolvedTarget(stored: .codexApp, agent: .claude, available: [.vscode, .codexApp]) == .vscode,
              "A remembered app the agent cannot use is ignored")
        check(ProjectRules.resolvedTarget(stored: nil, agent: .codex, available: [.vscode]) == nil, "No usable app resolves to nothing")

        // MARK: Prompts
        check(ProjectRules.effectivePrompt("  \n\t ") == "" && ProjectRules.effectivePrompt("  fix it \n") == "  fix it \n",
              "A blank prompt is no prompt; anything else is kept exactly")
        check(ProjectRules.refusal(for: "fix\u{0}it", agent: .claude, target: .vscode) == .nul,
              "A NUL character is refused for every target")
        check(ProjectRules.refusal(for: String(repeating: "a", count: 32_768), agent: .claude, target: .terminal) == nil,
              "32 KB is allowed")
        check(ProjectRules.refusal(for: String(repeating: "é", count: 16_385), agent: .claude, target: .terminal)
              == .tooLong(limit: 32_768), "The limit counts UTF-8 bytes")
        check(ProjectRules.refusal(for: "-p is a flag", agent: .claude, target: .terminal)
              == (ProjectAgent.claude.acceptsOptionTerminator ? nil : .leadingHyphen),
              "A leading hyphen is refused only for an agent whose CLI does not accept --")
        check(ProjectRules.refusal(for: "-p is a flag", agent: .codex, target: .terminal)
              == (ProjectAgent.codex.acceptsOptionTerminator ? nil : .leadingHyphen),
              "The same holds for Codex")
        check(ProjectRules.refusal(for: "-x", agent: .codex, target: .codexApp) == nil, "Links never read a prompt as an option")
        check(PromptRefusal.leadingHyphen.message(for: .codex) == "A prompt for Codex can’t start with a hyphen."
              && PromptRefusal.tooLong(limit: 32_768).message(for: .claude) == "This prompt is too long. The limit is 32 KB.",
              "Refusals explain themselves")

        // MARK: Script
        let script = ProjectRules.script(project: home + "/My 'Code'", program: home + "/.local/bin/claude",
                                         prompt: "it's done", optionTerminator: true)
        check(script == ["#!/bin/sh", "rm -f -- \"$0\"", "cd -- '/Users/someone/My '\\''Code'\\''' || exit 1",
                         "'/Users/someone/.local/bin/claude' -- 'it'\\''s done'", "exec \"${SHELL:-/bin/zsh}\" -l", ""]
                            .joined(separator: "\n"),
              "The script deletes itself, enters the project, runs the agent with its prompt, then leaves a shell")
        check(ProjectRules.script(project: "/p", program: "/bin/codex", prompt: "", optionTerminator: true).contains("\n'/bin/codex'\n"),
              "With no prompt the agent runs alone")
        check(ProjectRules.script(project: "/p", program: "/bin/claude", prompt: "hi", optionTerminator: false).contains("\n'/bin/claude' 'hi'\n"),
              "Without -- the prompt follows the program directly")
        check(ProjectRules.script(project: "/p", program: "/bin/claude", prompt: "line one\nline two", optionTerminator: true)
                .contains("'line one\nline two'"), "A line break stays inside the quoted prompt")

        // MARK: Links
        check(ProjectRules.queryValue("a+b&c=d#e%f g/h?") == "a%2Bb%26c%3Dd%23e%25f%20g%2Fh%3F",
              "Everything but unreserved characters is percent-encoded, + included")
        check(ProjectRules.queryValue("-._~AZaz09") == "-._~AZaz09", "Unreserved characters stay as they are")
        check(ProjectRules.queryValue("café\n日本") == "caf%C3%A9%0A%E6%97%A5%E6%9C%AC",
              "Line breaks and non-ASCII text are UTF-8 percent-encoded")
        check(ProjectRules.vscodeLink(prompt: "").absoluteString == "vscode://anthropic.claude-code/open",
              "With no prompt VS Code just opens Claude Code")
        check(ProjectRules.vscodeLink(prompt: "fix it").absoluteString == "vscode://anthropic.claude-code/open?prompt=fix%20it",
              "The prompt rides in the VS Code link")
        check(ProjectRules.codexLink(project: home + "/My Code", prompt: "").absoluteString
              == "codex://threads/new?path=%2FUsers%2Fsomeone%2FMy%20Code", "With no prompt the Codex link carries only the folder")
        check(ProjectRules.codexLink(project: "/p", prompt: "a&b").absoluteString == "codex://threads/new?path=%2Fp&prompt=a%26b",
              "The Codex link carries the folder and the prompt")
        check(ProjectRules.note(for: .terminal) == nil && ProjectRules.note(for: .iterm) == nil
              && ProjectRules.note(for: .otherTerminal) == nil, "Terminals need no note")
        check(ProjectRules.note(for: .vscode) == "Needs the Claude Code extension and a trusted folder. The prompt is filled in for you to send.",
              "VS Code says what it needs and that the prompt waits to be sent")
        check(ProjectRules.note(for: .codexApp) == "The prompt is filled in for you to send.",
              "The Codex app says the prompt waits to be sent")

        // MARK: Nocci target
        check(LaunchTarget.allCases.last == .nocci, "Nocci comes last in the fallback order")
        check(!LaunchTarget.nocci.isTerminal && LaunchTarget.nocci.runsProgram && LaunchTarget.terminal.runsProgram
              && LaunchTarget.otherTerminal.runsProgram && !LaunchTarget.vscode.runsProgram && !LaunchTarget.codexApp.runsProgram,
              "Terminals and Nocci run the agent's program; the two apps take a link")
        check(LaunchTarget.nocci.bundleIdentifier == nil && ProjectRules.note(for: .nocci) == nil, "Nocci needs no app and no note")
        check(ProjectRules.resolvedTarget(stored: .nocci, agent: .codex, available: [.terminal, .nocci]) == .nocci
              && ProjectRules.resolvedTarget(stored: nil, agent: .claude, available: [.terminal, .nocci]) == .terminal
              && ProjectRules.resolvedTarget(stored: .vscode, agent: .claude, available: [.nocci]) == .nocci,
              "A remembered Nocci is used, and Nocci is the last fallback")
        check(ProjectRules.refusal(for: "-v please", agent: .claude, target: .nocci) == nil
              && ProjectRules.refusal(for: "a\u{0}b", agent: .codex, target: .nocci) == .nul
              && ProjectRules.refusal(for: String(repeating: "a", count: 32_769), agent: .claude, target: .nocci) == .tooLong(limit: 32_768),
              "Nocci's prompts follow the terminal rules")
        check(ProjectRules.missingProgram(.claude) == "Claude Code wasn’t found. Choose it in Settings › Projects."
              && ProjectRules.missingProgram(.codex) == "Codex wasn’t found. Choose it in Settings › Providers.",
              "A missing program says where to choose it")

        print("\(checks) projects checks passed")
    }
}
