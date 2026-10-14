import AppKit

/// Finds the `claude` program for terminal sessions, the same way `gh`,
/// `glab` and Codex are found.
enum ClaudeProgram {
    static let overrideKey = "NOCCI_CLAUDE_PATH"
    static let preferenceKey = "projects.claudePath"

    static func executable(environment: [String: String] = ProcessInfo.processInfo.environment,
                           defaults: UserDefaults = .standard,
                           home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> String? {
        // An explicit override is authoritative, even if invalid, so tests
        // never fall through to a real installation.
        if let override = environment[overrideKey] {
            return FileManager.default.isRunnableFile(atPath: override) ? override : nil
        }
        // The native installer, the older local one, npm with its own prefix
        // and Volta come before the system-wide places, which may hold an
        // older copy.
        let paths = [defaults.string(forKey: preferenceKey), home + "/.local/bin/claude", home + "/.claude/local/claude",
                     home + "/.npm-global/bin/claude", home + "/.volta/bin/claude",
                     "/opt/homebrew/bin/claude", "/usr/local/bin/claude"].compactMap { $0 }
        return paths.first { FileManager.default.isRunnableFile(atPath: $0) }
    }
}

/// Everything a start needs, resolved on the main thread before anything is
/// written or opened.
struct LaunchRequest: Equatable {
    var project: String
    var agent: ProjectAgent
    var target: LaunchTarget
    /// The agent's program. Only terminal targets use it.
    var program: String?
    var application: URL
    var prompt: String
}

enum LaunchFailure: Error, Equatable { case notPrepared, notOpened }

/// Starts sessions: a self-deleting script for terminals, a link for VS Code
/// and the Codex app. This launcher never runs an agent itself.
final class ProjectLauncher {
    typealias Open = (_ items: [URL], _ application: URL, _ completion: @escaping (Bool) -> Void) -> Void
    typealias After = (_ delay: TimeInterval, _ work: @escaping () -> Void) -> Void

    static let leftoverAge: TimeInterval = 60
    static let otherTerminalKey = "projects.otherTerminalPath"

    let directory: URL
    private let open: Open
    private let now: () -> Date
    private let after: After

    init(directory: URL = Storage.directory.appendingPathComponent("Launch"),
         open: @escaping Open = ProjectLauncher.liveOpen, now: @escaping () -> Date = Date.init,
         after: @escaping After = ProjectLauncher.liveAfter) {
        self.directory = directory
        self.open = open
        self.now = now
        self.after = after
    }

    func launch(_ request: LaunchRequest, completion: @escaping (Result<Void, LaunchFailure>) -> Void) {
        switch request.target {
        case .terminal, .iterm, .otherTerminal:
            guard let program = request.program,
                  let script = try? writeScript(project: request.project, program: program, prompt: request.prompt,
                                                optionTerminator: request.agent.acceptsOptionTerminator) else {
                return completion(.failure(.notPrepared))
            }
            open([script], request.application) { [after] opened in
                if opened {
                    // A terminal that accepts the file but never runs it would
                    // otherwise leave the prompt on disk until the next start.
                    after(Self.leftoverAge) { try? FileManager.default.removeItem(at: script) }
                } else {
                    try? FileManager.default.removeItem(at: script)
                }
                completion(opened ? .success(()) : .failure(.notOpened))
            }
        case .vscode:
            let open = open
            open([URL(fileURLWithPath: request.project, isDirectory: true)], request.application) { opened in
                guard opened else { return completion(.failure(.notOpened)) }
                open([ProjectRules.vscodeLink(prompt: request.prompt)], request.application) { linked in
                    completion(linked ? .success(()) : .failure(.notOpened))
                }
            }
        case .codexApp:
            open([ProjectRules.codexLink(project: request.project, prompt: request.prompt)], request.application) { opened in
                completion(opened ? .success(()) : .failure(.notOpened))
            }
        case .nocci:
            // Nocci's own window starts its sessions (TerminalModel); none come here.
            completion(.failure(.notPrepared))
        }
    }

    /// Writes `Launch/<UUID>.command`, folder and file readable
    /// only by the user. Older leftovers go first.
    func writeScript(project: String, program: String, prompt: String, optionTerminator: Bool) throws -> URL {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        removeLeftovers()
        let script = directory.appendingPathComponent(UUID().uuidString + ".command")
        let text = ProjectRules.script(project: project, program: program, prompt: prompt, optionTerminator: optionTerminator)
        guard manager.createFile(atPath: script.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o700]) else {
            throw LaunchFailure.notPrepared
        }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        return script
    }

    /// Scripts a terminal never ran. Only `<UUID>.command` files older than a
    /// minute are removed; nothing else in the folder is touched.
    func removeLeftovers() {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: directory.path) else { return }
        let cutoff = now().addingTimeInterval(-Self.leftoverAge)
        for name in names where name.hasSuffix(".command") && UUID(uuidString: String(name.dropLast(8))) != nil {
            let path = directory.appendingPathComponent(name).path
            guard let modified = (try? manager.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
                  modified < cutoff else { continue }
            try? manager.removeItem(atPath: path)
        }
    }

    static func liveAfter(_ delay: TimeInterval, _ work: @escaping () -> Void) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: work)
    }

    static func liveOpen(_ items: [URL], _ application: URL, _ completion: @escaping (Bool) -> Void) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(items, withApplicationAt: application, configuration: configuration) { _, error in
            DispatchQueue.main.async { completion(error == nil) }
        }
    }

    /// The installed application for a target, or nil. Never launches anything.
    static func liveApplication(_ target: LaunchTarget, defaults: UserDefaults = .standard) -> URL? {
        switch target {
        case .terminal, .iterm, .vscode:
            guard let identifier = target.bundleIdentifier,
                  let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier),
                  ProviderActionService.isApplicationBundle(url) else { return nil }
            return url
        case .otherTerminal:
            guard let path = defaults.string(forKey: otherTerminalKey) else { return nil }
            let url = URL(fileURLWithPath: path)
            return ProviderActionService.isApplicationBundle(url) ? url : nil
        case .codexApp:
            return ProviderActionService(defaults: defaults).application(for: .codex)
        case .nocci:
            return nil
        }
    }

    /// The name Finder and the Dock show, such as "iTerm".
    static func liveAppName(_ url: URL) -> String {
        let name = FileManager.default.displayName(atPath: url.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }
}
