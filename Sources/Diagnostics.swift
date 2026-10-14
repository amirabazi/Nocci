import Foundation

struct DiagnosticRow: Equatable {
    var label: String
    var value: String
}

/// Everything the diagnostic view is allowed to know. It takes scalars rather
/// than the live objects on purpose: there is no way to reach a provider
/// payload, an auth file or a transcript path from here, because none of them
/// are in scope.
struct DiagnosticInput {
    var appVersion: String
    var home: String
    var codexPath: String?
    var codexExecutable: Bool
    var claudeConfigured: Bool
    var bridgePath: String?
    var bridgePresent: Bool
    var claudeStatus: String
    var lastClaudeEvent: Date?
    var lastClaudeRead: Date?
    var lastCodexRead: Date?
    var codexMessage: String
    var now: Date
}

enum Diagnostics {
    /// Paths are shown because the user chose them, but the home directory is
    /// collapsed so a pasted report does not carry an account name.
    static func abbreviate(_ path: String, home: String) -> String {
        guard !home.isEmpty else { return path }
        if path == home { return "~" }
        guard path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    /// Provider errors are reduced to a category. An unrecognised message is
    /// never echoed, because it is the one field that could carry a path or a
    /// token from a future provider change.
    static func category(for message: String) -> String {
        guard !message.isEmpty else { return "none" }
        switch message {
        case CodexReader.Failure.timeout.errorDescription: return "timeout"
        case CodexReader.Failure.disconnected.errorDescription: return "disconnected"
        case CodexReader.Failure.unavailable.errorDescription: return "not configured"
        case CodexReader.Failure.server.errorDescription: return "sign-in required"
        case CodexReader.connectingMessage: return "connecting"
        case CodexReader.noLimitsMessage: return "no limits reported"
        default: return "other"
        }
    }

    static func rows(_ input: DiagnosticInput) -> [DiagnosticRow] {
        func age(_ date: Date?) -> String {
            guard let date else { return "never" }
            let minutes = Freshness.minutesAgo(date, at: input.now)
            return minutes > 0 ? "\(minutes)m ago" : "just now"
        }
        return [
            DiagnosticRow(label: "Nocci", value: input.appVersion),
            DiagnosticRow(label: "Codex executable",
                          value: input.codexPath.map { abbreviate($0, home: input.home) } ?? "not found"),
            DiagnosticRow(label: "Codex executable usable", value: input.codexExecutable ? "yes" : "no"),
            DiagnosticRow(label: "Last Codex read", value: age(input.lastCodexRead)),
            DiagnosticRow(label: "Codex error", value: category(for: input.codexMessage)),
            DiagnosticRow(label: "Claude tracking", value: input.claudeConfigured ? "configured" : "not configured"),
            DiagnosticRow(label: "Bridge script", value: input.bridgePresent ? "present" : "missing"),
            DiagnosticRow(label: "Bridge path",
                          value: input.bridgePath.map { abbreviate($0, home: input.home) } ?? "not installed"),
            DiagnosticRow(label: "Claude connection", value: input.claudeStatus),
            DiagnosticRow(label: "Last Claude event", value: age(input.lastClaudeEvent)),
            DiagnosticRow(label: "Last Claude reading", value: age(input.lastClaudeRead)),
            // Worth stating here rather than cluttering the notch: refreshing
            // rereads Claude's file, it cannot make Claude Code produce one.
            DiagnosticRow(label: "Refresh behaviour",
                          value: "Rereads Claude's saved snapshot and asks Codex directly. It cannot make Claude Code send a new reading.")
        ]
    }

    static func text(_ rows: [DiagnosticRow]) -> String {
        rows.map { "\($0.label): \($0.value)" }.joined(separator: "\n")
    }
}
