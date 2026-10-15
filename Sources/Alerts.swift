import Foundation

enum AlertProvider: String, CaseIterable {
    case claude, codex
    var title: String { self == .claude ? "Claude usage" : "Codex usage" }
}

enum AlertThreshold {
    static let defaults = [80, 90, 100]

    static func normalize(_ values: [Int]) -> [Int] {
        Array(Set(values.filter { (1...100).contains($0) })).sorted()
    }

    static func parse(_ text: String) -> [Int]? {
        let parts = text.split { character in
            character == "," || character == ";" || character.isWhitespace
        }
        guard !parts.isEmpty else { return nil }
        var values: [Int] = []
        for part in parts {
            guard let value = Int(part), (1...100).contains(value) else { return nil }
            values.append(value)
        }
        return normalize(values)
    }

    static func text(_ values: [Int]) -> String {
        normalize(values).map(String.init).joined(separator: ", ")
    }
}

struct AlertPreferences: Equatable {
    var claude = false
    var codex = false
    var sound = false
    /// Offered separately from thresholds.
    var resets = false
    var claudeThresholds = AlertThreshold.defaults
    var codexThresholds = AlertThreshold.defaults

    func enabled(for provider: AlertProvider) -> Bool {
        provider == .claude ? claude : codex
    }

    func thresholds(for provider: AlertProvider) -> [Int] {
        provider == .claude ? claudeThresholds : codexThresholds
    }

    mutating func setThresholds(_ values: [Int], for provider: AlertProvider) {
        let normalized = AlertThreshold.normalize(values)
        guard !normalized.isEmpty else { return }
        if provider == .claude { claudeThresholds = normalized }
        else { codexThresholds = normalized }
    }

    var thresholdsByProvider: [AlertProvider: [Int]] {
        [.claude: claudeThresholds, .codex: codexThresholds]
    }

    static func load(from defaults: UserDefaults = .standard) -> AlertPreferences {
        var preferences = AlertPreferences()
        if let value = defaults.object(forKey: "claudeAlerts") as? Bool { preferences.claude = value }
        if let value = defaults.object(forKey: "codexAlerts") as? Bool { preferences.codex = value }
        if let value = defaults.object(forKey: "alertSound") as? Bool { preferences.sound = value }
        if let value = defaults.object(forKey: "resetAlerts") as? Bool { preferences.resets = value }
        preferences.claudeThresholds = loadThresholds("claudeAlertThresholds", from: defaults)
        preferences.codexThresholds = loadThresholds("codexAlertThresholds", from: defaults)
        return preferences
    }

    private static func loadThresholds(_ key: String, from defaults: UserDefaults) -> [Int] {
        guard let stored = defaults.array(forKey: key) else { return AlertThreshold.defaults }
        let values = stored.compactMap { ($0 as? NSNumber)?.intValue }
        let normalized = AlertThreshold.normalize(values)
        return normalized.isEmpty ? AlertThreshold.defaults : normalized
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(claude, forKey: "claudeAlerts")
        defaults.set(codex, forKey: "codexAlerts")
        defaults.set(sound, forKey: "alertSound")
        defaults.set(resets, forKey: "resetAlerts")
        defaults.set(claudeThresholds, forKey: "claudeAlertThresholds")
        defaults.set(codexThresholds, forKey: "codexAlertThresholds")
    }
}

/// One reading the engine is allowed to consider. The caller filters out demo,
/// hidden, disabled, stale and expired readings, so an ineligible window never
/// reaches the engine and its stored state cannot be advanced.
struct AlertReading: Equatable {
    var provider: AlertProvider
    var kind: UsageWindow.Kind
    var label: String
    var used: Double
    var reset: Date?
    var key: String { "\(provider.rawValue).\(kind.rawValue)" }
}

struct AlertWindowState: Codable, Equatable {
    var reset: Date?
    var handled: Set<Int> = []
    /// True once a threshold alert was actually delivered for this window. A
    /// silent baseline fills `handled` without setting this, which is how a
    /// reset alert tells "we warned you about this" from "we never spoke".
    var notified = false
}

struct AlertState: Codable, Equatable {
    /// A missing key means the window has never been seen, which is what
    /// distinguishes a baseline from a provider that reports no reset time.
    var windows: [String: AlertWindowState] = [:]

    /// Unreadable stored state falls back to empty rather than throwing. The
    /// cost of losing it is one suppressed baseline, never a repeated alert.
    static func load(from defaults: UserDefaults = .standard) -> AlertState {
        guard let data = defaults.data(forKey: "alertState"),
              let state = try? JSONDecoder().decode(AlertState.self, from: data) else { return AlertState() }
        return state
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: "alertState")
    }

    /// Turning a provider's alerts off forgets its windows, so turning them
    /// back on baselines afresh instead of resuming against stale thresholds.
    mutating func forget(_ provider: AlertProvider) {
        windows = windows.filter { !$0.key.hasPrefix(provider.rawValue + ".") }
    }
}

struct AlertMessage: Equatable {
    var title: String
    var body: String
    var identifier: String
}

/// Implemented by the UserNotifications adapter in the app and by a fake in
/// tests. Declared here so the engine's test binary needs no framework.
protocol AlertDelivery: AnyObject {
    func send(_ message: AlertMessage, sound: Bool)
}

/// Same window when both reset times exist and sit within ten minutes of each
/// other, which tolerates a provider correcting itself without rearming.
private let resetTolerance: TimeInterval = 600

func evaluate(state: AlertState, readings: [AlertReading],
              thresholdsByProvider: [AlertProvider: [Int]] = [:],
              resetAlerts: Bool = false, now: Date)
    -> (state: AlertState, messages: [AlertMessage]) {
    var state = state
    var parts: [AlertProvider: [(body: String, identifier: String)]] = [:]

    for reading in readings {
        let used = min(100, max(0, reading.used))
        let configured = AlertThreshold.normalize(
            thresholdsByProvider[reading.provider] ?? AlertThreshold.defaults)
        let thresholds = configured.isEmpty ? AlertThreshold.defaults : configured
        let lowestThreshold = thresholds.first ?? AlertThreshold.defaults[0]
        let stored = state.windows[reading.key]
        var handled = stored?.handled ?? []
        var notified = stored?.notified ?? false
        let stamp = reading.reset.map { String(Int($0.timeIntervalSince1970)) } ?? "none"
        var confirmedReset = false

        if let stored {
            switch (stored.reset, reading.reset) {
            case let (previous?, current?):
                if abs(current.timeIntervalSince(previous)) > resetTolerance {
                    // Only a reset moving *forward* confirms a successor period.
                    // A backwards jump is a correction, so it rearms but stays quiet.
                    confirmedReset = current > previous
                    handled = []
                    notified = false
                }
            case (nil, nil):
                // Without reset metadata only a real drop can mean a new window,
                // and a guess must never announce a reset.
                if used < Double(lowestThreshold) { handled = []; notified = false }
            default:
                handled = []
                notified = false
            }
        } else {
            // Baseline: record where this window already stands, say nothing.
            state.windows[reading.key] = AlertWindowState(
                reset: reading.reset,
                handled: Set(thresholds.filter { used >= Double($0) }),
                notified: false)
            continue
        }

        // Announce the reset only when we actually warned about the window it replaces.
        if confirmedReset, resetAlerts, stored?.notified == true {
            parts[reading.provider, default: []].append(
                (body: "\(reading.label) allowance has reset",
                 identifier: "\(reading.key).\(stamp).reset"))
        }

        let crossed = thresholds.filter { used >= Double($0) && !handled.contains($0) }
        handled.formUnion(crossed)
        if !crossed.isEmpty { notified = true }
        state.windows[reading.key] = AlertWindowState(reset: reading.reset, handled: handled, notified: notified)
        guard let highest = crossed.max() else { continue }

        parts[reading.provider, default: []].append(
            (body: "\(reading.label) allowance: \(highest)% used",
             identifier: "\(reading.key).\(stamp).\(highest)"))
    }

    // One notification per provider; two windows crossing together coalesce.
    let messages = AlertProvider.allCases.compactMap { provider -> AlertMessage? in
        guard let entries = parts[provider], !entries.isEmpty else { return nil }
        return AlertMessage(title: provider.title,
                            body: entries.map(\.body).joined(separator: " · "),
                            identifier: entries.map(\.identifier).joined(separator: "+"))
    }
    return (state, messages)
}
