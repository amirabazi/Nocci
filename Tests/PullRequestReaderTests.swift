import Foundation

// Executable resolution, the subprocess runner against temporary shell
// scripts, and both forge readers against a fake runner. No real gh, glab,
// account or network is used.
@main
struct PullRequestReaderTests {
    static func main() throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            guard condition() else { fatalError("FAIL: \(label)") }
            checks += 1
        }
        func failure(_ body: () throws -> Any?) -> PullRequestFailure? {
            do { _ = try body(); return nil } catch { return error as? PullRequestFailure }
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nocci-pr-reader-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func script(_ name: String, _ body: String) throws -> String {
            let url = directory.appendingPathComponent(name)
            try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            return url.path
        }

        // Resolution
        let suite = "nocci-pr-reader-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let saved = try script("saved-gh", "exit 0")
        let override = try script("override-gh", "exit 0")
        defaults.set(saved, forKey: ForgeCLI.preferenceKey(.github))
        check(ForgeCLI.preferenceKey(.github) == "pullRequests.ghPath" && ForgeCLI.preferenceKey(.gitlab) == "pullRequests.glabPath",
              "Saved paths use the documented keys")
        check(ForgeCLI.executable(.github, environment: ["NOCCI_GH_PATH": override], defaults: defaults) == override,
              "An override wins over the saved path")
        check(ForgeCLI.executable(.github, environment: ["NOCCI_GH_PATH": directory.appendingPathComponent("missing").path],
                                  defaults: defaults) == nil,
              "An invalid override never falls through to a saved or installed CLI")
        check(ForgeCLI.executable(.github, environment: [:], defaults: defaults) == saved,
              "The saved path is used without an override")
        check(ForgeCLI.executable(.gitlab, environment: ["NOCCI_GLAB_PATH": override], defaults: defaults) == override,
              "glab has its own override")
        let bundle = directory.appendingPathComponent("GitHub CLI.app")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        check(ForgeCLI.executable(.github, environment: ["NOCCI_GH_PATH": bundle.path], defaults: defaults) == nil,
              "An app bundle is not a runnable gh")
        defaults.set(bundle.path, forKey: ForgeCLI.preferenceKey(.github))
        check(ForgeCLI.executable(.github, environment: [:], defaults: defaults) != bundle.path,
              "A saved app bundle is never used as gh")
        defaults.set(saved, forKey: ForgeCLI.preferenceKey(.github))

        // The runner
        let echo = try script("echo", #"printf '%s\n' "$#" "$1" "$GH_HOST" "$GH_PROMPT_DISABLED" "$GLAB_CHECK_UPDATE" "$GLAB_NO_PROMPT""#)
        let echoed = try ForgeCLI.run(echo, ["a b; echo injected"])
        check(String(decoding: echoed.stdout, as: UTF8.self) == "1\na b; echo injected\ngithub.com\n1\nfalse\n1\n",
              "One array entry per argument, no shell, prompts off, gh pinned to github.com")
        check(ForgeCLI.childEnvironment["NO_PROMPT"] == nil,
              "NO_PROMPT is never set: glab 1.89.0 answers it with a deprecation warning on stdout, ahead of the JSON")
        check(echoed.status == 0, "A clean exit reports status 0")
        let auth = try script("auth", "echo 'To get started with GitHub CLI, please run:  gh auth login' >&2; exit 4")
        let denied = try ForgeCLI.run(auth, [])
        check(denied.status == 4 && denied.stderr.contains("gh auth login"), "Exit status and stderr are captured")
        let slow = try script("slow", "exec /bin/sleep 5")
        let started = Date()
        check(failure { try ForgeCLI.run(slow, [], timeout: 0.5) } == .timeout, "The watchdog stops a hung CLI")
        check(Date().timeIntervalSince(started) < 3, "A timeout returns promptly")
        check(failure { try ForgeCLI.run(directory.appendingPathComponent("missing").path, []) } == .executableMissing,
              "A missing executable is its own category")
        let pidFile = directory.appendingPathComponent("stubborn.pid").path
        let stubborn = try script("stubborn", #"echo $$ > "$1"; trap '' TERM; exec /bin/sleep 6"#)
        let stubbornStart = Date()
        check(failure { try ForgeCLI.run(stubborn, [pidFile], timeout: 0.5) } == .timeout, "A child that ignores SIGTERM times out")
        check(Date().timeIntervalSince(stubbornStart) < 4, "A child that ignores SIGTERM cannot hold the call open")
        let stubbornPID = pid_t((try? String(contentsOfFile: pidFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
        var reaped = false
        for _ in 0..<20 where !reaped {
            reaped = kill(stubbornPID, 0) != 0
            if !reaped { Thread.sleep(forTimeInterval: 0.05) }
        }
        check(stubbornPID > 0 && reaped, "A child that ignores SIGTERM is killed, not left running")
        let lingering = try script("lingering", "(/bin/sleep 5) & echo '[]'")
        let lingeringStart = Date()
        check(failure { try ForgeCLI.run(lingering, [], timeout: 0.5) } == .timeout,
              "A background process holding the output open times out instead of hanging the refresh")
        check(Date().timeIntervalSince(lingeringStart) < 4, "Draining after exit is bounded too")
        let floodPID = directory.appendingPathComponent("flood.pid").path
        let flood = try script("flood", #"echo $$ > "$1"; exec /usr/bin/yes"#)
        let floodStart = Date()
        check(failure { try ForgeCLI.run(flood, [floodPID], timeout: 8) } == .unreadable,
              "Output past 4 MB is refused as unreadable while it is still arriving")
        check(Date().timeIntervalSince(floodStart) < 4, "Reading stops at the cap instead of waiting for the watchdog")
        let floodChild = pid_t((try? String(contentsOfFile: floodPID, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
        var floodReaped = false
        for _ in 0..<40 where !floodReaped {
            floodReaped = kill(floodChild, 0) != 0
            if !floodReaped { Thread.sleep(forTimeInterval: 0.05) }
        }
        check(floodChild > 0 && floodReaped, "The child is stopped once its output passes the cap")
        func peakFootprint() -> UInt64 {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            return result == KERN_SUCCESS ? UInt64(info.ledger_phys_footprint_peak) : 0
        }
        let chatty = try script("chatty", "exec /usr/bin/yes >&2")
        let peakBefore = peakFootprint()
        check(failure { try ForgeCLI.run(chatty, [], timeout: 1) } == .timeout, "A child flooding stderr is stopped by the watchdog")
        check(peakBefore > 0 && peakFootprint() - peakBefore < 64_000_000,
              "Only the first 8 KB of stderr is kept, so a flood never grows in memory")
        let large = try script("large", "/bin/dd if=/dev/zero bs=1000 count=4100 2>/dev/null")
        check(failure { try ForgeCLI.run(large, []) } == .unreadable, "A finished reply over 4 MB is unreadable")
        let fits = try script("fits", "/bin/dd if=/dev/zero bs=1000 count=3900 2>/dev/null")
        check((try? ForgeCLI.run(fits, []))?.stdout.count == 3_900_000, "A reply under the cap is read whole")
        setenv("GH_HOST", "ghe.example.com", 1)
        let pinned = try ForgeCLI.run(echo, [])
        unsetenv("GH_HOST")
        check(String(decoding: pinned.stdout, as: UTF8.self).split(separator: "\n").dropFirst().first == "github.com",
              "gh stays on github.com when Nocci itself was started with another GH_HOST")

        // A fake runner keyed by arguments
        var calls: [[String]] = []
        let lock = NSLock()
        func fake(_ answer: @escaping ([String]) -> CommandOutput) -> ForgeCLI.Run {
            return { _, arguments in
                lock.lock(); calls.append(arguments); lock.unlock()
                return answer(arguments)
            }
        }
        func ok(_ text: String) -> CommandOutput { CommandOutput(status: 0, stdout: Data(text.utf8), stderr: "") }
        func githubRow(_ number: Int, minutes: Int) -> String {
            let stamp = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 1_800_000_000 - Double(minutes * 60)))
            return #"{"number":\#(number),"title":"PR \#(number)","url":"https://github.com/o/r/pull/\#(number)","updatedAt":"\#(stamp)","repository":{"nameWithOwner":"o/r"}}"#
        }

        // GitHub
        let github = fake { arguments in
            if arguments.contains("--author=@me") { return ok("[\(githubRow(1, minutes: 5)),\(githubRow(2, minutes: 50))]") }
            if arguments.contains("--assignee=@me") { return ok("[\(githubRow(1, minutes: 5))]") }
            if arguments.contains("user-review-requested:@me") { return ok("[]") }
            if arguments.last == "statusCheckRollup" {
                if arguments[2].hasSuffix("/2") { return CommandOutput(status: 1, stdout: Data(), stderr: "HTTP 502") }
                return ok(#"{"statusCheckRollup":[{"state":"SUCCESS","targetUrl":"https://ci.example/run/1"}]}"#)
            }
            return CommandOutput(status: 1, stdout: Data(), stderr: "unexpected")
        }
        let result = try PullRequestReader.github(executable: "/fake/gh", run: github)
        check(result.items.count == 2 && !result.truncated, "Found under two roles, listed once")
        check(result.items.first { $0.number == 1 }?.roles == [.authored, .assigned], "Both roles are kept")
        check(result.items.first { $0.number == 1 }?.checks == .passing, "CI state is attached")
        check(result.items.first { $0.number == 1 }?.ciLink == URL(string: "https://ci.example/run/1"),
              "The CI run's link is attached beside its state")
        check(result.items.first { $0.number == 2 }?.checks == nil, "A failed CI lookup drops only that glyph")
        check(calls.filter { $0.first == "search" }.count == 3 && calls.filter { $0.last == "statusCheckRollup" }.count == 2,
              "Three searches, then one CI lookup per pull request")

        calls.removeAll()
        let signedOut = fake { _ in CommandOutput(status: 4, stdout: Data(), stderr: "") }
        check(failure { try PullRequestReader.github(executable: "/fake/gh", run: signedOut) } == .notSignedIn,
              "A failed search fails the host instead of returning a partial list")
        check(calls.count == 1, "Nothing else runs after the first failed search")
        check(failure { try PullRequestReader.github(executable: nil, run: github) } == .executableMissing,
              "No executable, no call")

        calls.removeAll()
        let many = (1...40).map { githubRow($0, minutes: $0) }.joined(separator: ",")
        let crowded = fake { arguments in
            if arguments.contains("--author=@me") { return ok("[\(many)]") }
            if arguments.first == "search" { return ok("[]") }
            return ok(#"{"statusCheckRollup":[{"state":"PENDING"}]}"#)
        }
        let capped = try PullRequestReader.github(executable: "/fake/gh", run: crowded)
        check(calls.filter { $0.last == "statusCheckRollup" }.count == PullRequestCommands.checkLimit,
              "CI is looked up for at most 30 pull requests per refresh")
        check(capped.items.filter { $0.checks != nil }.map(\.number).sorted() == Array(1...30),
              "The 30 most recently updated get a glyph; the rest show none")
        check(capped.items.count == 40, "Rows beyond the CI cap are still listed")

        let page = (1...50).map { githubRow($0, minutes: $0) }.joined(separator: ",")
        let full = try PullRequestReader.github(executable: "/fake/gh", run: fake { arguments in
            if arguments.contains("--assignee=@me") { return ok("[\(page)]") }
            if arguments.first == "search" { return ok("[]") }
            return ok(#"{"statusCheckRollup":[]}"#)
        })
        check(full.truncated, "A full page from any role marks the host as truncated")

        calls.removeAll()
        func oddRow(_ number: Int, url: String) -> String {
            #"{"number":\#(number),"title":"PR \#(number)","url":"\#(url)","updatedAt":"2026-09-22T10:06:41Z","repository":{"nameWithOwner":"o/r"}}"#
        }
        let odd = try PullRequestReader.github(executable: "/fake/gh", run: fake { arguments in
            if arguments.contains("--author=@me") {
                return ok("[\(githubRow(1, minutes: 5)),\(oddRow(2, url: "--web")),\(oddRow(3, url: "https://elsewhere.example/o/r/pull/3"))]")
            }
            if arguments.first == "search" { return ok("[]") }
            return ok(#"{"statusCheckRollup":[{"state":"SUCCESS"}]}"#)
        })
        check(calls.filter { $0.last == "statusCheckRollup" }.map { $0[2] } == ["https://github.com/o/r/pull/1"],
              "CI is looked up only for links on github.com, so a reply can never become an option")
        check(odd.items.count == 3 && odd.items.filter { $0.checks != nil }.map(\.number) == [1],
              "Rows with other links are still listed, without a glyph")

        // GitLab
        func gitlabRow(_ iid: Int) -> String {
            #"{"iid":\#(iid),"project_id":99,"title":"MR \#(iid)","web_url":"https://git.example.org/g/p/-/merge_requests/\#(iid)","updated_at":"2026-09-22T10:06:41.123Z","references":{"full":"g/p!\#(iid)"}}"#
        }
        calls.removeAll()
        let gitlab = fake { arguments in
            guard arguments.count == 4, arguments[1] == "--hostname", arguments[2] == "git.example.org" else {
                return CommandOutput(status: 1, stdout: Data(), stderr: "wrong host")
            }
            let path = arguments[3]
            if path == "user" { return ok(#"{"username":"tanuki"}"#) }
            if path.hasSuffix("scope=created_by_me") { return ok("[\(gitlabRow(12))]") }
            if path.hasSuffix("scope=assigned_to_me") { return ok("[]") }
            if path.hasSuffix("scope=all&reviewer_username=tanuki") { return ok("[\(gitlabRow(12)),\(gitlabRow(13))]") }
            if path == "projects/99/merge_requests/12" {
                return ok(#"{"head_pipeline":{"status":"running","web_url":"https://git.example.org/g/p/-/pipelines/7"}}"#)
            }
            if path == "projects/99/merge_requests/13" { return ok(#"{"head_pipeline":null}"#) }
            return CommandOutput(status: 1, stdout: Data(), stderr: "unexpected \(path)")
        }
        let lab = try PullRequestReader.gitlab(host: "git.example.org", executable: "/fake/glab", run: gitlab)
        check(lab.items.count == 2 && lab.items.first { $0.number == 12 }?.roles == [.authored, .reviewRequested],
              "GitLab roles merge by merge request")
        check(lab.items.first { $0.number == 12 }?.checks == .running && lab.items.first { $0.number == 13 }?.checks == nil,
              "Pipelines come from each merge request; none means no glyph")
        check(lab.items.first { $0.number == 12 }?.ciLink == URL(string: "https://git.example.org/g/p/-/pipelines/7")
              && lab.items.first { $0.number == 13 }?.ciLink == nil, "The pipeline page is attached; no pipeline, no link")
        check(calls.first == ["api", "--hostname", "git.example.org", "user"], "The login is asked for first, on this host")
        check(calls.allSatisfy { $0.count == 4 && $0[2] == "git.example.org" }, "Every call names the chosen host")
        let webPage = fake { _ in ok("<html><body>Sign in</body></html>") }
        check(failure { try PullRequestReader.gitlab(host: "git.example.org", executable: "/fake/glab", run: webPage) } == .unreadable,
              "A host answering with a web page is unreadable, not empty")
        let unauthorized = fake { _ in
            CommandOutput(status: 1, stdout: Data(), stderr: "GET https://git.example.org/api/v4/user: 401 {message: 401 Unauthorized}")
        }
        check(failure { try PullRequestReader.gitlab(host: "git.example.org", executable: "/fake/glab", run: unauthorized) } == .notSignedIn,
              "glab's 401 means not signed in")

        // Account lookup
        check((try? PullRequestReader.login(.github, executable: "/fake/gh", run: fake { _ in ok(#"{"login":"octo"}"#) })) == "octo",
              "The GitHub login is read")
        check(failure { try PullRequestReader.login(.github, executable: nil, run: github) } == .executableMissing,
              "No executable means no account lookup")

        print("\(checks) pull-request reader checks passed")
    }
}
