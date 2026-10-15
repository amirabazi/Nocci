import Foundation

struct UsageWindow: Codable, Equatable {
    enum Kind: String, Codable { case session, weekly }
    var label: String
    var used: Double
    var reset: Date?
    /// Which allowance this is, independent of the provider's own label.
    /// Optional so snapshots written before this field still decode; keep it
    /// last so the memberwise initializer stays source compatible.
    var kind: Kind?
    /// How long the window lasts, in seconds, when the provider says so.
    /// Optional for the same reason as `kind`, and after it, so every
    /// existing call of the memberwise initializer still compiles.
    var duration: TimeInterval? = nil
    /// Codex derives labels from `windowDurationMins`, and Claude omits absent
    /// windows entirely, so neither the label nor the array index identifies a
    /// window. Stored snapshots without a kind fall back to the label.
    var resolvedKind: Kind { kind ?? (label == "Weekly" ? .weekly : .session) }
    /// Takes the time explicitly, like every other time-dependent rule here.
    /// Reading the wall clock instead made expiry impossible to test and
    /// silently discarded any fixture dated in the past.
    func expired(at now: Date) -> Bool { reset.map { $0 <= now } ?? false }
    /// The share of the window already gone, 0 to 1: where an even spend
    /// would have the bar now. Nil without a reset or a duration, and once
    /// the window has expired.
    func elapsed(at now: Date) -> Double? {
        guard let reset, let duration, duration > 0, reset > now else { return nil }
        return min(1, max(0, 1 - reset.timeIntervalSince(now) / duration))
    }
    /// The complement of the *rounded* used value, so the two display modes
    /// always sum to 100.
    var remaining: Int { 100 - Int(min(100, max(0, used)).rounded()) }
    /// Takes the time explicitly, like `expired(at:)`.
    func countdown(at now: Date) -> String {
        guard let reset else { return "Reset unavailable" }
        let seconds = reset.timeIntervalSince(now)
        guard seconds > 0 else { return "Awaiting new window" }
        let minutes = max(1, Int(ceil(seconds / 60)))
        if minutes >= 1440 { return "Resets in \(minutes / 1440)d \((minutes % 1440) / 60)h" }
        if minutes >= 60 { return "Resets in \(minutes / 60)h \(minutes % 60)m" }
        return "Resets in \(minutes)m"
    }
}
struct UsageSnapshot: Codable, Equatable {
    var windows: [UsageWindow]
    /// When the windows below were actually read from a provider.
    var updated: Date
    /// When a provider last sent anything at all, with or without quotas.
    /// Optional so snapshots written before this field still decode.
    var lastEvent: Date?
}

extension FileManager {
    /// An executable regular file. `isExecutableFile` alone also accepts a
    /// folder, since a folder's x bit means searchable, so an app bundle passed.
    func isRunnableFile(atPath path: String) -> Bool {
        var directory: ObjCBool = false
        return fileExists(atPath: path, isDirectory: &directory) && !directory.boolValue && isExecutableFile(atPath: path)
    }
}

/// How percentages are displayed. Canonical data is always the used share;
/// remaining is computed at render time from a clamped used value.
enum PercentageMode: String { case used, remaining }
/// Which window a provider's compact slot shows when both providers are visible.
enum CompactWindowChoice: String {
    case session, weekly, automatic

    /// An explicitly selected window the provider did not report returns nil.
    /// Never substitute the other quota; the caller renders a dash.
    func window(in windows: [UsageWindow]) -> UsageWindow? {
        func find(_ kind: UsageWindow.Kind) -> UsageWindow? {
            windows.first { $0.resolvedKind == kind }
        }
        switch self {
        case .session: return find(.session)
        case .weekly: return find(.weekly)
        case .automatic: return find(.session) ?? find(.weekly)
        }
    }
}

/// How hovering over the collapsed strip opens the panel. A click always
/// opens it at once, whichever is chosen.
enum HoverOpen: String {
    case instant, pause, clickOnly

    /// Seconds the pointer must rest on the strip; nil means hover never opens it.
    var delay: TimeInterval? {
        switch self {
        case .instant: return 0
        case .pause: return 0.3
        case .clickOnly: return nil
        }
    }
}

struct DisplayPreferences: Equatable {
    var showClaude = true
    var showCodex = true
    var percentages: PercentageMode = .used
    /// Each provider's own compact window.
    var claudeWindow: CompactWindowChoice = .automatic
    var codexWindow: CompactWindowChoice = .automatic
    /// Off by default: pace is an estimate and should be opted into.
    var showPace = false
    /// A short pause by default, so passing over the notch on the way to the
    /// menu bar does not open the panel.
    var hoverOpen: HoverOpen = .pause
    /// Off by default, so nothing changes unless asked.
    var hideInFullScreen = false

    func percent(_ window: UsageWindow) -> Int {
        percentages == .used ? Int(min(100, max(0, window.used)).rounded()) : window.remaining
    }

    var caption: String {
        percentages == .used ? "Percent of allowance used" : "Percent of allowance remaining"
    }

    /// Read through `object(forKey:)`, not `bool(forKey:)`, so an absent key
    /// means the default rather than false. Storage with every provider hidden
    /// is clamped, so a hand-edited domain cannot produce an empty notch.
    static func load(from defaults: UserDefaults = .standard) -> DisplayPreferences {
        var preferences = DisplayPreferences()
        if let value = defaults.object(forKey: "showClaude") as? Bool { preferences.showClaude = value }
        if let value = defaults.object(forKey: "showCodex") as? Bool { preferences.showCodex = value }
        if let raw = defaults.string(forKey: "percentageMode"), let value = PercentageMode(rawValue: raw) {
            preferences.percentages = value
        }
        if let raw = defaults.string(forKey: "claudeCompactWindow"), let value = CompactWindowChoice(rawValue: raw) {
            preferences.claudeWindow = value
        }
        if let raw = defaults.string(forKey: "codexCompactWindow"), let value = CompactWindowChoice(rawValue: raw) {
            preferences.codexWindow = value
        }
        if let value = defaults.object(forKey: "showPace") as? Bool { preferences.showPace = value }
        if let raw = defaults.string(forKey: "hoverOpen"), let value = HoverOpen(rawValue: raw) {
            preferences.hoverOpen = value
        }
        if let value = defaults.object(forKey: "hideInFullScreen") as? Bool { preferences.hideInFullScreen = value }
        if !preferences.showClaude && !preferences.showCodex {
            preferences.showClaude = true
            preferences.showCodex = true
        }
        return preferences
    }

    /// One compact slot. `kind` names a specific window for the one-provider
    /// split strip; nil means "whatever the provider's `choice` selects".
    func reading(provider: String, choice: CompactWindowChoice, kind requested: UsageWindow.Kind?,
                 snapshot: UsageSnapshot?, now: Date) -> CompactReading {
        let windows = snapshot?.windows ?? []
        let window = requested.map { kind in windows.first { $0.resolvedKind == kind } } ?? choice.window(in: windows)
        let stale = snapshot.map { Freshness.isStale($0.updated, at: now) } ?? true
        let label = window.map { "\(provider) \($0.label) usage" } ?? "\(provider) usage"
        let noun = percentages == .used ? "used" : "remaining"

        guard let window, !window.expired(at: now) else {
            let missing = requested ?? (choice == .weekly ? .weekly : .session)
            let name = missing == .weekly ? "weekly" : "session"
            if window?.expired(at: now) == true {
                return CompactReading(value: "—", stale: stale, label: label,
                                      explanation: "\(provider): previous window expired. Waiting for a new provider reading.")
            }
            guard !windows.isEmpty, requested != nil || choice != .automatic else {
                return CompactReading(value: "—", stale: stale, label: label,
                                      explanation: "\(provider): no subscription usage reported yet.")
            }
            let hint = requested == nil
                ? " Choose Automatic in Settings to fall back to the other window."
                : ""
            return CompactReading(value: "—", stale: stale, label: label,
                                  explanation: "\(provider): no \(name) window reported.\(hint)")
        }

        let value = "\(percent(window))%"
        let fraction = Double(percent(window)) / 100
        let used = min(100, max(0, window.used))
        if stale, let snapshot {
            return CompactReading(value: value, stale: true, label: label,
                                  explanation: "\(provider) \(window.label): last reading \(percent(window))% \(noun), "
                                    + "\(snapshot.updated.formatted(date: .abbreviated, time: .shortened)). "
                                    + "Outdated; waiting for a fresh reading.",
                                  fraction: fraction, used: used)
        }
        return CompactReading(value: value, stale: false, label: label,
                              explanation: "\(provider) \(window.label): \(value) of subscription allowance \(noun)",
                              fraction: fraction, used: used)
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(showClaude, forKey: "showClaude")
        defaults.set(showCodex, forKey: "showCodex")
        defaults.set(percentages.rawValue, forKey: "percentageMode")
        defaults.set(claudeWindow.rawValue, forKey: "claudeCompactWindow")
        defaults.set(codexWindow.rawValue, forKey: "codexCompactWindow")
        defaults.set(showPace, forKey: "showPace")
        defaults.set(hoverOpen.rawValue, forKey: "hoverOpen")
        defaults.set(hideInFullScreen, forKey: "hideInFullScreen")
    }
}

/// One slot of the compact strip, resolved from a snapshot and the preferences.
struct CompactReading: Equatable {
    var value: String
    var stale: Bool
    var label: String
    var explanation: String
    /// The displayed share as 0 to 1, in the active percentage mode; nil when
    /// there is no current window.
    var fraction: Double? = nil
    /// The clamped used percentage, which decides the warning colour in
    /// both modes; nil when there is no current window.
    var used: Double? = nil
}

enum UsageParser {
    static func window(_ raw: Any?, label: String, kind: UsageWindow.Kind, claude: Bool = false,
                       duration: TimeInterval? = nil) -> UsageWindow? {
        guard let raw = raw as? [String: Any], let used = raw[claude ? "used_percentage" : "usedPercent"] as? Double, used.isFinite else { return nil }
        let stamp = raw[claude ? "resets_at" : "resetsAt"] as? Double
        var title = label
        var kind = kind
        var duration = duration
        if !claude, let durationNumber = raw["windowDurationMins"] as? NSNumber {
            let minutes = durationNumber.intValue
            title = minutes == 10080 ? "Weekly" : minutes % 60 == 0 ? "\(minutes / 60)-hour" : "\(minutes)-minute"
            // A plan with only a weekly window reports it as `primary`.
            if minutes == 10080 { kind = .weekly }
            if minutes > 0 { duration = TimeInterval(minutes) * 60 }
        }
        return UsageWindow(label: title, used: min(100, max(0, used)), reset: stamp.map(Date.init(timeIntervalSince1970:)),
                           kind: kind, duration: duration)
    }
    static func codex(_ raw: [String: Any]) -> UsageSnapshot {
        let map = raw["rateLimitsByLimitId"] as? [String: [String: Any]]
        let bucket: [String: Any]
        if let map, !map.isEmpty { bucket = map["codex"] ?? [:] }
        else { bucket = raw["rateLimits"] as? [String: Any] ?? [:] }
        return UsageSnapshot(windows: [window(bucket["primary"], label: "Session", kind: .session), window(bucket["secondary"], label: "Weekly", kind: .weekly)].compactMap { $0 }, updated: Date())
    }
    static func claude(_ raw: [String: Any]) -> UsageSnapshot {
        let rate = raw["rate_limits"] as? [String: Any] ?? [:]
        // The names are the durations: five hours and seven days.
        return UsageSnapshot(windows: [window(rate["five_hour"], label: "5-hour", kind: .session, claude: true, duration: 5 * 3600),
                                       window(rate["seven_day"], label: "Weekly", kind: .weekly, claude: true, duration: 7 * 86400)]
                                .compactMap { $0 }, updated: Date())
    }
}

enum Storage {
    static var directory: URL {
        if let path = ProcessInfo.processInfo.environment["NOCCI_DATA_DIR"] { return URL(fileURLWithPath: path) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Nocci")
    }
    static var claudeFile: URL { directory.appendingPathComponent("claude.json") }
    /// Claude Code sends a status-line event at session start, before its first
    /// API response, and that event has no `rate_limits`. Such an event proves
    /// the bridge ran; it does not mean the allowance is unknown. Keep the last
    /// real reading and its own capture time, so a new session cannot erase it.
    static func merge(incoming: UsageSnapshot, existing: UsageSnapshot?, now: Date) -> UsageSnapshot {
        guard incoming.windows.isEmpty, let existing, !existing.windows.isEmpty else {
            var snapshot = incoming
            snapshot.lastEvent = now
            return snapshot
        }
        var snapshot = existing
        snapshot.lastEvent = now
        return snapshot
    }
    static func receiveClaude() throws {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Several sessions run the status line at once. Merging under one lock
        // keeps an event without limits from writing back an older reading
        // over a newer one. A lock that cannot be had in time is skipped
        // rather than failing the user's status line; closing releases it.
        let lock = open(directory.appendingPathComponent(".claude.lock").path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        defer { if lock >= 0 { close(lock) } }
        let deadline = Date().addingTimeInterval(2)
        while lock >= 0, flock(lock, LOCK_EX | LOCK_NB) != 0, errno == EWOULDBLOCK || errno == EINTR, Date() < deadline {
            usleep(10_000)
        }
        let existing = (try? Data(contentsOf: claudeFile)).flatMap { try? JSONDecoder().decode(UsageSnapshot.self, from: $0) }
        let snapshot = merge(incoming: UsageParser.claude(raw), existing: existing, now: Date())
        try JSONEncoder().encode(snapshot).write(to: claudeFile, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: claudeFile.path)
        print(snapshot.windows.map { "\($0.label): \(Int($0.used.rounded()))% used" }.joined(separator: " · "))
    }
}

final class CodexReader {
    enum Failure: LocalizedError {
        case unavailable, timeout, disconnected, server
        var errorDescription: String? {
            switch self {
            case .unavailable: return "Codex wasn’t found. Install it and choose it with Set Up Codex, or hide Codex in Settings › Appearance."
            case .timeout: return "Codex took too long. Try refreshing."
            case .disconnected: return "Codex stopped answering. Check that codex login works in Terminal."
            case .server: return "Usage unavailable. Sign in with ChatGPT in Codex."
            }
        }
    }
    static let connectingMessage = "Connecting to Codex…"
    static let noLimitsMessage = "No subscription limits returned."
    /// A Finder launch gets a minimal PATH, so an npm install's `#!/usr/bin/env
    /// node` finds no `node`. The folder holding the executable (and the one
    /// its link points into) holds the interpreter in npm, nvm and Homebrew
    /// layouts, so both are searched first.
    static func environment(for path: String, base: [String: String]) -> [String: String] {
        var environment = base
        let link = URL(fileURLWithPath: path).deletingLastPathComponent().path
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().deletingLastPathComponent().path
        let inherited = (base["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        var folders: [String] = []
        for folder in [link, resolved, "/opt/homebrew/bin", "/usr/local/bin"] + inherited where !folders.contains(folder) {
            folders.append(folder)
        }
        environment["PATH"] = folders.joined(separator: ":")
        return environment
    }
    static func executable(environment: [String: String] = ProcessInfo.processInfo.environment,
                           savedPath: @autoclosure () -> String? = UserDefaults.standard.string(forKey: "codexPath")) -> String? {
        // An explicit override is authoritative, even if invalid. Tests must
        // never fall through to a real signed-in CLI or saved user preference.
        if let override = environment["NOCCI_CODEX_PATH"] {
            return FileManager.default.isRunnableFile(atPath: override) ? override : nil
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let paths = [savedPath(), "/Applications/Codex.app/Contents/Resources/codex", "/Applications/ChatGPT.app/Contents/Resources/codex", "\(home)/Applications/Codex.app/Contents/Resources/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex", "\(home)/.local/bin/codex", "\(home)/.npm-global/bin/codex", "\(home)/.volta/bin/codex"].compactMap { $0 }
        return paths.first { FileManager.default.isRunnableFile(atPath: $0) }
    }
    // A fresh, read-only app-server connection each poll. Never starts a model turn.
    static func read(path: String? = executable()) throws -> UsageSnapshot {
        guard let path else { throw Failure.unavailable }
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["app-server"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.environment = environment(for: path, base: ProcessInfo.processInfo.environment)
        // Codex can exit between two messages. Without this the next write
        // raises SIGPIPE and ends Nocci; with it the write fails and is
        // reported below. Only this pipe: an app-wide SIG_IGN would be
        // inherited by every shell in the terminal's tabs.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        do { try process.run() } catch { throw Failure.unavailable }
        // A child that ignores SIGTERM would hold the read below open for good.
        let watchdog = DispatchWorkItem {
            guard process.isRunning else { return }
            process.terminate()
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if process.isRunning { kill(pid, SIGKILL) } }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: watchdog)
        defer {
            watchdog.cancel()
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            try? output.fileHandleForReading.close()
        }
        // A child that has already exited makes the write fail; that is a
        // disconnection, never a raw error.
        func send(_ raw: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: raw)
            data.append(10)
            do { try input.fileHandleForWriting.write(contentsOf: data) } catch { throw Failure.disconnected }
        }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        try send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "notch_usage", "title": "Nocci", "version": version]]])
        var buffer = Data()
        let started = Date()
        while Date().timeIntervalSince(started) < 16 {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { throw Date().timeIntervalSince(started) >= 14 ? Failure.timeout : Failure.disconnected }
            buffer.append(chunk)
            guard buffer.count < 2_000_000 else { throw Failure.disconnected }
            while let end = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<end]); buffer.removeSubrange(...end)
                guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let id = message["id"] as? Int else { continue }
                if message["error"] != nil { throw Failure.server }
                if id == 1 {
                    try send(["method": "initialized", "params": [:]])
                    try send(["id": 2, "method": "account/rateLimits/read", "params": [:]])
                } else if id == 2, let result = message["result"] as? [String: Any] { return UsageParser.codex(result) }
            }
        }
        throw Failure.timeout
    }
}
