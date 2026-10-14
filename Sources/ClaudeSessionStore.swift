import Foundation

enum ClaudeSessionStoreError: Error {
    case lockTimeout
    case unavailable
}

/// The session files shared by the `--claude-hook` bridge and the app. Every
/// read-modify-write happens under one lock, because hooks from several
/// sessions, and several hooks from one session, run at the same time.
struct ClaudeSessionStore {
    /// Larger payloads are ignored rather than parsed.
    static let inputLimit = 16 * 1024 * 1024

    let directory: URL

    init(directory: URL = Storage.directory.appendingPathComponent("Sessions")) {
        self.directory = directory
    }

    func withLock<T>(timeout: TimeInterval = 2, _ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let descriptor = open(directory.appendingPathComponent(".lock").path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw ClaudeSessionStoreError.unavailable }
        defer { close(descriptor) }
        let deadline = Date().addingTimeInterval(timeout)
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR, Date() < deadline else { throw ClaudeSessionStoreError.lockTimeout }
            usleep(10_000)
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    func apply(_ event: ClaudeHookEvent, at date: Date, host: String?, tab: UUID? = nil) throws {
        let outcome = ClaudeSessionRules.outcome(for: event)
        guard outcome != .ignore else { return }
        let url = directory.appendingPathComponent(ClaudeSessionRules.fileName(sessionID: event.sessionID))
        try withLock {
            let existing = (try? Data(contentsOf: url)).flatMap(ClaudeSessionRecord.decode)
            guard let merged = ClaudeSessionRules.merge(existing: existing, outcome: outcome, at: date,
                                                        project: ClaudeSessionRules.projectName(cwd: event.cwd),
                                                        host: host, tab: tab, agent: event.agent,
                                                        fromTool: event.name == "PreToolUse" || event.name == "PostToolUse") else { return }
            try write(merged, to: url)
        }
    }

    /// Unreadable files are skipped, never shown.
    func load() -> [ClaudeSessionItem] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(".json") }.compactMap { name in
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)),
                  let record = ClaudeSessionRecord.decode(data) else { return nil }
            return ClaudeSessionItem(id: String(name.dropLast(5)), record: record)
        }
    }

    func removeExpired(at now: Date) throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try withLock {
            for item in load() where ClaudeSessionRules.isExpired(item.record, at: now) {
                try? FileManager.default.removeItem(at: url(for: item.id))
            }
        }
    }

    /// Hides the current wait only. If the session has moved to another
    /// state since the row was shown, the dismissal no longer applies.
    func dismiss(_ id: String, since: Date) throws {
        try withLock {
            let url = url(for: id)
            guard var record = (try? Data(contentsOf: url)).flatMap(ClaudeSessionRecord.decode),
                  record.since == since, !record.dismissed else { return }
            record.dismissed = true
            try write(record, to: url)
        }
    }

    func removeAll() throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    /// The `--claude-hook` entry point. It never throws and never prints: a
    /// hook must not disturb the session that ran it.
    static func receiveHook(input: Data, environment: [String: String], now: Date,
                            store: ClaudeSessionStore = ClaudeSessionStore()) {
        guard input.count <= inputLimit, let event = ClaudeHookEvent.parse(input) else { return }
        // The same name as TerminalRules.tabVariable, which this file is compiled without in tests.
        try? store.apply(event, at: now, host: ClaudeSessionRules.hostIdentifier(environment["__CFBundleIdentifier"]),
                         tab: ClaudeSessionRules.tabID(environment["NOCCI_TERMINAL_TAB"]))
    }

    /// Reads stdin to the end so Claude Code never sees a broken pipe, but
    /// keeps no more than the limit.
    static func readInput(_ handle: FileHandle = .standardInput) -> Data {
        var data = Data()
        while case let chunk = handle.availableData, !chunk.isEmpty {
            if data.count <= inputLimit { data.append(chunk) }
        }
        return data
    }

    private func url(for id: String) -> URL {
        directory.appendingPathComponent(id + ".json")
    }

    private func write(_ record: ClaudeSessionRecord, to url: URL) throws {
        try record.encoded().write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
