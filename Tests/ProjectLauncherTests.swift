import AppKit

// Temporary folders, fake programs and a recording opener. No terminal,
// editor or agent is ever opened; the only thing run is a fake agent script,
// by /bin/sh, to prove the quoting end to end.
@main
struct ProjectLauncherTests {
    static func main() throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            guard condition() else { fatalError("FAIL: \(label)") }
            checks += 1
        }
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("nocci-launcher-" + UUID().uuidString)
        defer { try? manager.removeItem(at: root) }
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        func executable(_ path: String, _ body: String = "#!/bin/sh\nexit 0\n") throws -> String {
            let url = root.appendingPathComponent(path)
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(body.utf8).write(to: url)
            try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            return url.path
        }
        func mode(_ path: String) -> Int {
            ((try? manager.attributesOfItem(atPath: path))?[.posixPermissions] as? NSNumber)?.intValue ?? -1
        }
        func succeeded(_ result: Result<Void, LaunchFailure>?) -> Bool {
            if case .success? = result { return true }
            return false
        }
        func failure(_ result: Result<Void, LaunchFailure>?) -> LaunchFailure? {
            if case .failure(let failure)? = result { return failure }
            return nil
        }
        /// The physical path, as `pwd -P` prints it (`/var` is a link to `/private/var`).
        func physical(_ path: String) -> String {
            guard let resolved = realpath(path, nil) else { return path }
            defer { free(resolved) }
            return String(cString: resolved)
        }

        // MARK: Finding claude
        let suite = "nocci-launcher-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let home = root.appendingPathComponent("home").path
        let homeClaude = try executable("home/.local/bin/claude")
        let chosen = try executable("chosen/claude")
        check(ClaudeProgram.executable(environment: [:], defaults: defaults, home: home) == homeClaude,
              "~/.local/bin/claude is found")
        // The older local installer's place, and npm with its own prefix.
        let localHome = root.appendingPathComponent("local-home").path
        let localClaude = try executable("local-home/.claude/local/claude")
        check(ClaudeProgram.executable(environment: [:], defaults: defaults, home: localHome) == localClaude,
              "~/.claude/local/claude is found before any system-wide copy")
        let npmHome = root.appendingPathComponent("npm-home").path
        let npmClaude = try executable("npm-home/.npm-global/bin/claude")
        check(ClaudeProgram.executable(environment: [:], defaults: defaults, home: npmHome) == npmClaude,
              "An npm install under ~/.npm-global is found")
        defaults.set(chosen, forKey: ClaudeProgram.preferenceKey)
        check(ClaudeProgram.executable(environment: [:], defaults: defaults, home: home) == chosen,
              "A chosen program comes before the usual places")
        check(ClaudeProgram.executable(environment: ["NOCCI_CLAUDE_PATH": homeClaude], defaults: defaults, home: home) == homeClaude,
              "The override comes first")
        check(ClaudeProgram.executable(environment: ["NOCCI_CLAUDE_PATH": root.path + "/missing"], defaults: defaults, home: home) == nil,
              "An invalid override finds nothing rather than falling through")
        defaults.set(root.path, forKey: ClaudeProgram.preferenceKey)
        check(ClaudeProgram.executable(environment: [:], defaults: defaults, home: home) == homeClaude,
              "A folder chosen as the program is skipped")
        try manager.createDirectory(at: root.appendingPathComponent("Fake.app/Contents/MacOS"), withIntermediateDirectories: true)
        defaults.set(root.appendingPathComponent("Fake.app").path, forKey: ClaudeProgram.preferenceKey)
        check(ClaudeProgram.executable(environment: [:], defaults: defaults, home: home) == homeClaude,
              "An app bundle chosen as the program is skipped")

        // MARK: Launching
        var opened: [([URL], URL)] = []
        var answers: [Bool] = []
        var scheduled: [(delay: TimeInterval, work: () -> Void)] = []
        let clock = Date()
        let launchDirectory = root.appendingPathComponent("data/Launch")
        let launcher = ProjectLauncher(directory: launchDirectory, open: { items, application, done in
            opened.append((items, application))
            done(answers.isEmpty ? true : answers.removeFirst())
        }, now: { clock }, after: { scheduled.append(($0, $1)) })
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        let project = root.appendingPathComponent("My 'Project' $(x) café").path
        try manager.createDirectory(atPath: project, withIntermediateDirectories: true)
        func request(_ target: LaunchTarget, prompt: String = "fix it", program: String? = "/bin/echo",
                     agent: ProjectAgent = .claude) -> LaunchRequest {
            LaunchRequest(project: project, agent: agent, target: target, program: program, application: terminal, prompt: prompt)
        }
        var outcome: Result<Void, LaunchFailure>?

        launcher.launch(request(.iterm)) { outcome = $0 }
        check(succeeded(outcome), "A terminal start succeeds when the app opens")
        check(opened.count == 1 && opened[0].1 == terminal && opened[0].0.count == 1, "The script is opened with the chosen terminal")
        let script = opened[0].0[0]
        check(script.deletingLastPathComponent().path == launchDirectory.path && script.pathExtension == "command"
              && UUID(uuidString: script.deletingPathExtension().lastPathComponent) != nil,
              "The script is a <UUID>.command file in the Launch folder")
        check(mode(launchDirectory.path) == 0o700 && mode(script.path) == 0o700, "Only the user can read the folder and the script")
        check((try? String(contentsOf: script, encoding: .utf8)) == ProjectRules.script(project: project, program: "/bin/echo", prompt: "fix it",
                                                                        optionTerminator: ProjectAgent.claude.acceptsOptionTerminator),
              "The script is exactly the rule's text")
        check(scheduled.count == 1 && scheduled[0].delay == ProjectLauncher.leftoverAge && manager.fileExists(atPath: script.path),
              "An opened script is left for the terminal, with its removal scheduled a minute later")
        scheduled.removeFirst().work()
        check(!manager.fileExists(atPath: script.path),
              "A script the terminal never ran is deleted once that minute passes, without waiting for another start")

        opened = []; answers = [false]; outcome = nil
        launcher.launch(request(.terminal)) { outcome = $0 }
        check(failure(outcome) == .notOpened && opened.count == 1 && !manager.fileExists(atPath: opened[0].0[0].path),
              "A script whose terminal did not open is deleted at once")
        check(scheduled.isEmpty, "Nothing is scheduled for a script already deleted")

        opened = []; outcome = nil
        launcher.launch(request(.otherTerminal, program: nil)) { outcome = $0 }
        check(failure(outcome) == .notPrepared && opened.isEmpty, "A terminal start without a program opens nothing")

        let blocker = root.appendingPathComponent("a file, not a folder")
        try Data().write(to: blocker)
        let blocked = ProjectLauncher(directory: blocker.appendingPathComponent("Launch"), open: { items, application, done in
            opened.append((items, application)); done(true)
        })
        outcome = nil
        blocked.launch(request(.terminal)) { outcome = $0 }
        check(failure(outcome) == .notPrepared && opened.isEmpty, "A Launch folder that cannot be made fails before anything opens")

        let scriptsBefore = try manager.contentsOfDirectory(atPath: launchDirectory.path).count
        opened = []; outcome = nil
        launcher.launch(request(.vscode, prompt: "a&b", program: nil)) { outcome = $0 }
        check(succeeded(outcome) && opened.map { $0.0 } == [[URL(fileURLWithPath: project, isDirectory: true)],
                                                            [ProjectRules.vscodeLink(prompt: "a&b")]],
              "VS Code opens the folder, then the Claude Code link")
        opened = []; answers = [false]; outcome = nil
        launcher.launch(request(.vscode, program: nil)) { outcome = $0 }
        check(failure(outcome) == .notOpened && opened.count == 1, "No link is sent when the folder did not open")
        opened = []; outcome = nil
        launcher.launch(request(.codexApp, program: nil, agent: .codex)) { outcome = $0 }
        check(succeeded(outcome) && opened.map { $0.0 } == [[ProjectRules.codexLink(project: project, prompt: "fix it")]],
              "The Codex app gets its new-thread link")
        opened = []; outcome = nil
        launcher.launch(request(.nocci)) { outcome = $0 }
        check(failure(outcome) == .notPrepared && opened.isEmpty, "Nocci's own target never reaches the launcher")
        let scriptsAfter = try manager.contentsOfDirectory(atPath: launchDirectory.path).count
        check(scriptsAfter == scriptsBefore && scheduled.isEmpty, "Link targets write no script and schedule nothing")

        // MARK: Leftovers
        let old = launchDirectory.appendingPathComponent(UUID().uuidString + ".command")
        let fresh = launchDirectory.appendingPathComponent(UUID().uuidString + ".command")
        let unrelated = launchDirectory.appendingPathComponent("notes.command")
        let other = launchDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        for url in [old, fresh, unrelated, other] { try Data().write(to: url) }
        for url in [old, unrelated, other] {
            try manager.setAttributes([.modificationDate: clock.addingTimeInterval(-61)], ofItemAtPath: url.path)
        }
        launcher.removeLeftovers()
        check(!manager.fileExists(atPath: old.path) && manager.fileExists(atPath: fresh.path),
              "Only scripts older than a minute are removed")
        check(manager.fileExists(atPath: unrelated.path) && manager.fileExists(atPath: other.path),
              "Nothing but <UUID>.command files is ever touched")
        try manager.setAttributes([.modificationDate: clock.addingTimeInterval(-61)], ofItemAtPath: fresh.path)
        launcher.launch(request(.terminal)) { outcome = $0 }
        check(!manager.fileExists(atPath: fresh.path), "Old scripts are also removed before each new one is written")

        // MARK: The script itself
        let record = root.appendingPathComponent("record").path
        let fake = try executable("bin/fake agent", """
            #!/bin/sh
            pwd -P > '\(record).cwd'
            for argument in "$@"; do printf '%s\\0' "$argument"; done > '\(record).args'

            """)
        let canary = root.appendingPathComponent("canary").path
        let prompts = ["it's \"quoted\" and \\ backslashed", "$(touch \(canary)) `touch \(canary)` $HOME",
                       "-p --dangerously-skip-permissions", "/review the diff", "line one\nline two",
                       "café 日本 🚀", "  spaced  "]
        for prompt in prompts {
            let path = try launcher.writeScript(project: project, program: fake, prompt: prompt, optionTerminator: true)
            let run = Process()
            run.executableURL = URL(fileURLWithPath: "/bin/sh")
            run.arguments = [path.path]
            run.environment = ["SHELL": "/usr/bin/true", "PATH": "/usr/bin:/bin"]
            try run.run()
            run.waitUntilExit()
            let cwd = try String(contentsOfFile: record + ".cwd", encoding: .utf8).trimmingCharacters(in: .newlines)
            let arguments = try Data(contentsOf: URL(fileURLWithPath: record + ".args"))
                .split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
            check(run.terminationStatus == 0, "The script runs cleanly for \(prompt.debugDescription)")
            check(cwd == physical(project), "The agent starts in the project folder for \(prompt.debugDescription)")
            check(arguments == ["--", prompt], "The agent receives exactly -- and the prompt for \(prompt.debugDescription)")
            check(!manager.fileExists(atPath: path.path), "The script deleted itself for \(prompt.debugDescription)")
        }
        check(!manager.fileExists(atPath: canary), "Nothing in a prompt or a folder name is ever run by the shell")

        print("\(checks) project launcher checks passed")
    }
}
