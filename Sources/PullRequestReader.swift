import Foundation

struct CommandOutput {
    var status: Int32
    var stdout: Data
    var stderr: String
}

/// Resolves and runs `gh` and `glab`. Arguments go to the executable as an
/// array; nothing is ever interpreted by a shell.
enum ForgeCLI {
    typealias Run = (_ executable: String, _ arguments: [String]) throws -> CommandOutput

    /// Prompts, update checks and colour are off: nobody can answer a prompt
    /// from here, and escape codes would corrupt the JSON. `GH_HOST` keeps gh
    /// on github.com even when the user's default is an Enterprise server.
    /// glab 1.89 prints a deprecation warning on stdout for the older
    /// `NO_PROMPT`, which would sit ahead of the JSON, so only its
    /// replacement is set.
    static let childEnvironment = ["GH_HOST": "github.com", "GH_PROMPT_DISABLED": "1",
                                   "GH_NO_UPDATE_NOTIFIER": "1", "GLAB_CHECK_UPDATE": "false",
                                   "GLAB_NO_PROMPT": "1", "NO_COLOR": "1"]

    static let outputLimit = 4_000_000

    static func preferenceKey(_ forge: Forge) -> String { "pullRequests.\(forge.cli)Path" }
    static func overrideKey(_ forge: Forge) -> String { forge == .github ? "NOCCI_GH_PATH" : "NOCCI_GLAB_PATH" }

    static func executable(_ forge: Forge,
                           environment: [String: String] = ProcessInfo.processInfo.environment,
                           defaults: UserDefaults = .standard) -> String? {
        // An explicit override is authoritative, even if invalid, so tests
        // never fall through to the user's signed-in CLI.
        if let override = environment[overrideKey(forge)] {
            return FileManager.default.isRunnableFile(atPath: override) ? override : nil
        }
        let paths = [defaults.string(forKey: preferenceKey(forge)),
                     "/opt/homebrew/bin/\(forge.cli)", "/usr/local/bin/\(forge.cli)"].compactMap { $0 }
        return paths.first { FileManager.default.isRunnableFile(atPath: $0) }
    }

    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 15) throws -> CommandOutput {
        let process = Process(), output = Pipe(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(childEnvironment) { _, ours in ours }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { throw PullRequestFailure.executableMissing }
        // Both pipes drain at once, so a chatty stderr cannot stall the child
        // while stdout is being read. Stdout stops at the cap and the child is
        // stopped, so an endless reply never grows past it in memory. The
        // readers block for the whole call, so they get threads of their own:
        // on GCD's capped pool, several hosts' CI lookups at once could leave
        // a reader waiting to start until its call timed out.
        var outputData = Data(), errorData = Data(), overflowed = false
        let drained = DispatchGroup()
        drained.enter()
        Thread {
            while let chunk = try? output.fileHandleForReading.read(upToCount: 65_536), !chunk.isEmpty {
                outputData.append(chunk)
                if outputData.count > outputLimit {
                    overflowed = true
                    process.terminate()
                    break
                }
            }
            drained.leave()
        }.start()
        drained.enter()
        Thread {
            // Only the start is kept, for classifying the failure; the rest is
            // read and dropped so the child never blocks on a full pipe. Each
            // read is autoreleased, so the pool is drained per chunk.
            var reading = true
            while reading {
                autoreleasepool {
                    guard let chunk = try? errors.fileHandleForReading.read(upToCount: 65_536), !chunk.isEmpty else {
                        reading = false
                        return
                    }
                    if errorData.count < 8192 { errorData.append(chunk.prefix(8192 - errorData.count)) }
                }
            }
            drained.leave()
        }.start()
        guard exited.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            // A child that ignores SIGTERM is killed outright rather than left running.
            if exited.wait(timeout: .now() + 2) == .timedOut { kill(process.processIdentifier, SIGKILL) }
            _ = drained.wait(timeout: .now() + 2)
            throw PullRequestFailure.timeout
        }
        // A background process that inherited the pipes can keep them open after
        // the child exits, so draining is bounded as well.
        guard drained.wait(timeout: .now() + 2) == .success else { throw PullRequestFailure.timeout }
        guard !overflowed else { throw PullRequestFailure.unreadable }
        return CommandOutput(status: process.terminationStatus, stdout: outputData,
                             stderr: String(decoding: errorData.prefix(8192), as: UTF8.self))
    }
}

enum PullRequestReader {
    static let live: ForgeCLI.Run = { executable, arguments in try ForgeCLI.run(executable, arguments) }

    /// Every search must succeed, so a partial list is never shown as
    /// complete. A failed CI lookup only drops that row's glyph.
    static func github(executable: String?, run: @escaping ForgeCLI.Run = live) throws -> HostResult {
        guard let executable else { throw PullRequestFailure.executableMissing }
        var lists: [[PullRequest]] = []
        for role in PullRequestRole.allCases {
            lists.append(try PullRequestParser.githubSearch(
                call(run, executable, PullRequestCommands.githubSearch(role)), role: role))
        }
        // The link is passed to gh as an argument, so only a github.com link
        // is: a reply shaped like an option is never handed on.
        let items = withChecks(PullRequestGrouping.merge(lists)) { item in
            guard item.isSafeToOpen else { return nil }
            return try? PullRequestParser.githubChecks(call(run, executable, PullRequestCommands.githubChecks(item.url)))
        }
        return HostResult(items: items, truncated: lists.contains { $0.count >= PullRequestCommands.limit })
    }

    /// The login is asked for on every refresh, so switching glab accounts can
    /// never leave a stale reviewer filter behind.
    static func gitlab(host: String, executable: String?, run: @escaping ForgeCLI.Run = live) throws -> HostResult {
        guard let executable else { throw PullRequestFailure.executableMissing }
        let target = PullRequestTarget(forge: .gitlab, host: host)
        let login = try PullRequestParser.login(call(run, executable, PullRequestCommands.user(target)))
        var lists: [[PullRequest]] = []
        for role in PullRequestRole.allCases {
            lists.append(try PullRequestParser.gitlabList(
                call(run, executable, PullRequestCommands.gitlabList(role, host: host, login: login)),
                host: host, role: role))
        }
        let items = withChecks(PullRequestGrouping.merge(lists)) { item in
            guard let project = item.projectID else { return nil }
            return try? PullRequestParser.gitlabPipeline(call(run, executable,
                PullRequestCommands.gitlabPipeline(host: host, projectID: project, iid: item.number)))
        }
        return HostResult(items: items, truncated: lists.contains { $0.count >= PullRequestCommands.limit })
    }

    static func login(_ target: PullRequestTarget, executable: String?,
                      run: @escaping ForgeCLI.Run = live) throws -> String {
        guard let executable else { throw PullRequestFailure.executableMissing }
        return try PullRequestParser.login(call(run, executable, PullRequestCommands.user(target)))
    }

    /// CI for the `limit` most recently updated items, at most four lookups at
    /// once. Order is preserved; every other item keeps no status and no link.
    static func withChecks(_ items: [PullRequest], limit: Int = PullRequestCommands.checkLimit,
                           lookup: @escaping (PullRequest) -> CheckResult?) -> [PullRequest] {
        var results = items
        let chosen = items.indices.sorted { items[$0].updated > items[$1].updated }.prefix(limit)
        let lock = NSLock(), gate = DispatchSemaphore(value: 4), group = DispatchGroup()
        for index in chosen {
            gate.wait()
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                let result = lookup(items[index])
                lock.lock()
                results[index].checks = result?.state
                results[index].ciLink = result?.link
                lock.unlock()
                gate.signal()
                group.leave()
            }
        }
        group.wait()
        return results
    }

    private static func call(_ run: ForgeCLI.Run, _ executable: String, _ arguments: [String]) throws -> Data {
        let output = try run(executable, arguments)
        guard output.status == 0 else {
            throw PullRequestFailure.classify(status: output.status, stderr: output.stderr)
        }
        return output.stdout
    }
}
