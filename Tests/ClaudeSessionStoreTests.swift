import Foundation

// The locked session files, against a temporary directory. No hook, Claude
// Code session or real Nocci data is touched.
@main
struct ClaudeSessionStoreTests {
    static func main() throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            guard condition() else { fatalError("FAIL: \(label)") }
            checks += 1
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nocci-sessions-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Sessions")
        let store = ClaudeSessionStore(directory: directory)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func event(_ name: String, id: String = "s-1", notification: String? = nil, tool: String? = nil) -> ClaudeHookEvent {
            ClaudeHookEvent(name: name, sessionID: id, cwd: "/Users/someone/Code/api-server",
                            notificationType: notification, toolName: tool)
        }
        func state(_ id: String = "s-1") -> ClaudeSessionState? {
            let file = String(ClaudeSessionRules.fileName(sessionID: id).dropLast(5))
            return store.load().first { $0.id == file }?.record.state
        }
        func mode(_ url: URL) -> Int {
            ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber)?.intValue ?? -1
        }

        // Writing
        try store.apply(event("PermissionRequest", tool: "Bash"), at: now, host: "com.example.Editor")
        let first = store.load()
        check(first.count == 1 && first[0].record.state == .permission && first[0].record.project == "api-server"
              && first[0].record.host == "com.example.Editor", "A permission request is recorded with project and host")
        check(first[0].id == String(ClaudeSessionRules.fileName(sessionID: "s-1").dropLast(5)), "Items are named by the hashed session")
        check(mode(directory) == 0o700 && mode(directory.appendingPathComponent(ClaudeSessionRules.fileName(sessionID: "s-1"))) == 0o600,
              "The directory is private to the owner and each file is 0600")
        try store.apply(event("PostToolUse", tool: "Bash"), at: now.addingTimeInterval(5), host: nil)
        check(state() == .working, "An answered permission goes back to working")
        try store.apply(event("Stop"), at: now.addingTimeInterval(10), host: nil)
        try store.apply(event("PostToolUse", tool: "Bash"), at: now.addingTimeInterval(9), host: nil)
        check(state() == .yourTurn, "A hook that finishes late cannot undo a finished turn")
        check(store.load()[0].record.host == "com.example.Editor", "The host survives events that lack one")
        try store.apply(event("SessionEnd"), at: now.addingTimeInterval(20), host: nil)
        try store.apply(event("Stop"), at: now.addingTimeInterval(19), host: nil)
        check(state() == .ended, "A session that ended stays ended")
        try store.apply(event("Notification", id: "s-idle", notification: "idle_prompt"), at: now, host: nil)
        check(state("s-idle") == nil, "An ignored event creates nothing")

        // Dismissing
        try store.apply(event("PermissionRequest", id: "s-2"), at: now, host: nil)
        let second = store.load().first { $0.record.state == .permission }!
        try store.dismiss(second.id, since: now.addingTimeInterval(-1))
        check(store.load().first { $0.id == second.id }?.record.dismissed == false,
              "A dismissal for an older wait changes nothing")
        try store.dismiss(second.id, since: second.record.since)
        check(store.load().first { $0.id == second.id }?.record.dismissed == true, "Dismissing marks the current wait")

        // Loading skips what is not a record
        try Data("garbage".utf8).write(to: directory.appendingPathComponent("0123.json"))
        check(store.load().count == 2 && !store.load().contains { $0.id == "0123" || $0.id == ".lock" },
              "Corrupt files and the lock file are skipped")

        // Expiry
        try store.removeExpired(at: now.addingTimeInterval(81))
        check(state() == nil && store.load().count == 1, "An ended marker is removed after a minute")
        try store.removeExpired(at: now.addingTimeInterval(43_200))
        check(store.load().isEmpty, "Twelve hours without news removes a waiting session")

        // The lock
        let holder = open(directory.appendingPathComponent(".lock").path, O_RDWR)
        check(holder >= 0 && flock(holder, LOCK_EX | LOCK_NB) == 0, "A second descriptor can hold the lock")
        let started = Date()
        var timedOut = false
        do { _ = try store.withLock(timeout: 0.2) { true } } catch { timedOut = true }
        check(timedOut && Date().timeIntervalSince(started) < 1, "Waiting for a held lock gives up promptly")
        flock(holder, LOCK_UN)
        close(holder)
        check((try? store.withLock(timeout: 0.2) { 7 }) == 7, "A free lock is taken")

        // The bridge
        let payload = #"{"session_id":"s-3","hook_event_name":"Stop","cwd":"/tmp/example/website","user_prompt":"PRIVATE"}"#
        ClaudeSessionStore.receiveHook(input: Data(payload.utf8), environment: ["__CFBundleIdentifier": "com.example.Editor"],
                                       now: now, store: store)
        check(state("s-3") == .yourTurn && store.load().first?.record.host == "com.example.Editor"
              && store.load().first?.record.project == "website", "The bridge records state, project and host")
        let text = String(decoding: try Data(contentsOf: directory.appendingPathComponent(ClaudeSessionRules.fileName(sessionID: "s-3"))),
                          as: UTF8.self)
        check(!text.contains("PRIVATE") && !text.contains("s-3"), "Nothing private is stored")
        ClaudeSessionStore.receiveHook(input: Data("{".utf8), environment: [:], now: now, store: store)
        ClaudeSessionStore.receiveHook(input: Data(repeating: 32, count: ClaudeSessionStore.inputLimit + 1), environment: [:],
                                       now: now, store: store)
        ClaudeSessionStore.receiveHook(input: Data(#"{"session_id":"s-4","hook_event_name":"Stop"}"#.utf8),
                                       environment: ["__CFBundleIdentifier": "not a bundle"], now: now, store: store)
        check(store.load().count == 2 && store.load().first { $0.record.project == nil }?.record.host == nil,
              "Garbage and oversized input do nothing; a malformed host is dropped")
        let tab = UUID()
        ClaudeSessionStore.receiveHook(input: Data(#"{"session_id":"s-5","hook_event_name":"PermissionRequest","cwd":"/tmp/x/api"}"#.utf8),
                                       environment: ["__CFBundleIdentifier": "com.example.Nocci", "NOCCI_TERMINAL_TAB": tab.uuidString],
                                       now: now, store: store)
        check(store.load().first { $0.record.project == "api" }?.record.tab == tab, "The bridge stores the tab it inherited")
        ClaudeSessionStore.receiveHook(input: Data(#"{"session_id":"s-6","hook_event_name":"Stop","cwd":"/tmp/x/web"}"#.utf8),
                                       environment: ["NOCCI_TERMINAL_TAB": "../../etc"], now: now, store: store)
        check(store.load().first { $0.record.project == "web" }?.record.tab == nil, "A malformed tab is dropped")
        ClaudeSessionStore.receiveHook(input: Data(#"{"session_id":"s-5","hook_event_name":"Stop","cwd":"/tmp/x/api"}"#.utf8),
                                       environment: [:], now: now.addingTimeInterval(1), store: store)
        check(store.load().first { $0.record.project == "api" }?.record.tab == tab && state("s-5") == .yourTurn,
              "A later hook without the variable keeps the tab")

        // Turning off
        try store.removeAll()
        check(!FileManager.default.fileExists(atPath: directory.path) && store.load().isEmpty, "Turning off removes every session file")

        print("\(checks) claude-session store checks passed")
    }
}
