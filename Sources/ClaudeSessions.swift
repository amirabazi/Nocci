import CryptoKit
import Foundation

/// What a Claude Code session is doing, as far as its hooks have said.
/// `working` and `ended` are tracked so a session can leave the list; only
/// the other three need the user.
enum ClaudeSessionState: String, Codable {
    case working, permission, question, yourTurn, ended
    /// A Codex tab in Nocci's terminal that sent a notification. Never stored
    /// in a file; the notification does not say which kind of wait it is.
    case waiting

    var needsYou: Bool { self == .permission || self == .question || self == .yourTurn || self == .waiting }

    var title: String {
        switch self {
        case .working: return "Working"
        case .permission: return "Needs permission"
        case .question: return "Asking a question"
        case .yourTurn: return "Your turn"
        case .waiting: return "Needs you"
        case .ended: return "Ended"
        }
    }

    /// Lower is more urgent: an approval blocks work, a question waits on an
    /// answer, a Codex wait may be either, a finished turn only waits for the
    /// next prompt.
    var urgency: Int {
        switch self {
        case .permission: return 0
        case .question: return 1
        case .waiting: return 2
        case .yourTurn: return 3
        case .working: return 4
        case .ended: return 5
        }
    }
}

/// The only parts of a hook payload Nocci reads. Prompts, replies, tool
/// input and output, and the transcript path are never copied into a value.
struct ClaudeHookEvent: Equatable {
    var name: String
    var sessionID: String
    var cwd: String?
    var notificationType: String?
    var toolName: String?
    /// Which subagent sent the event, as `ClaudeSessionRules.agentKey`; nil
    /// for the main agent. The raw ID is never kept.
    var agent: String? = nil

    static func parse(_ data: Data) -> ClaudeHookEvent? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = root["hook_event_name"] as? String, !name.isEmpty,
              let session = root["session_id"] as? String, !session.isEmpty else { return nil }
        return ClaudeHookEvent(name: name, sessionID: session, cwd: root["cwd"] as? String,
                               notificationType: root["notification_type"] as? String,
                               toolName: root["tool_name"] as? String,
                               agent: (root["agent_id"] as? String).flatMap { $0.isEmpty ? nil : ClaudeSessionRules.agentKey($0) })
    }
}

enum ClaudeSessionOutcome: Equatable {
    case set(ClaudeSessionState)
    case ignore
}

struct ClaudeSessionRecord: Codable, Equatable {
    var state: ClaudeSessionState
    /// When the current state began.
    var since: Date
    /// The newest event applied. Older events are dropped against it.
    var updated: Date
    var project: String?
    var host: String?
    /// When Nocci first heard from the session: its real start when the hooks
    /// were already installed. Files from before it was kept have none.
    var started: Date?
    var dismissed = false
    /// The Nocci terminal tab the session runs in, when it runs in one. A
    /// random ID, never the session ID; optional so older files still decode.
    var tab: UUID? = nil
    /// The subagent whose permission prompt or question this is, as a hash;
    /// nil for the main agent and for any other state.
    var agent: String? = nil

    /// Milliseconds since 1970, so times compare exactly after a round trip.
    static func decode(_ data: Data) -> ClaudeSessionRecord? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try? decoder.decode(ClaudeSessionRecord.self, from: data)
    }

    func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)) ?? Data()
    }
}

struct ClaudeSessionItem: Equatable, Identifiable {
    var id: String
    var record: ClaudeSessionRecord
}

/// A Codex tab in Nocci's terminal that needs the user.
struct HostedWait: Equatable {
    var tab: UUID
    var project: String
    var since: Date
}

/// What the terminal tells the session list: the tabs with a session, the
/// tabs closed since Nocci started, and the Codex waits.
struct ClaudeSessionHosting: Equatable {
    var live: Set<UUID> = []
    var closed: Set<UUID> = []
    var waits: [HostedWait] = []
    /// Live tabs shown in the Projects tile rather than the window.
    var notch: Set<UUID> = []
}

enum ClaudeSessionRules {
    static let expiry: TimeInterval = 12 * 3600
    /// An ended marker only has to outlive hooks still finishing for that session.
    static let endedLifetime: TimeInterval = 60

    static func outcome(for event: ClaudeHookEvent) -> ClaudeSessionOutcome {
        switch event.name {
        case "SessionStart", "UserPromptSubmit", "PostToolUse":
            return .set(.working)
        case "PreToolUse":
            return .set(event.toolName == "AskUserQuestion" ? .question : .working)
        case "PermissionRequest":
            return .set(.permission)
        case "Notification":
            switch event.notificationType {
            case "permission_prompt": return .set(.permission)
            case "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input": return .set(.question)
            default: return .ignore
            }
        case "Stop":
            return .set(.yourTurn)
        // Marked rather than deleted, so a hook from the same session that
        // finishes a moment later cannot bring the row back.
        case "SessionEnd":
            return .set(.ended)
        default:
            return .ignore
        }
    }

    /// Hooks run asynchronously and can finish out of order, so an event older
    /// than the stored one is dropped. Nil means leave the file as it is.
    /// `fromTool` marks PreToolUse and PostToolUse, the events parallel
    /// subagents keep sending while another one waits for the user.
    static func merge(existing: ClaudeSessionRecord?, outcome: ClaudeSessionOutcome, at date: Date,
                      project: String?, host: String?, tab: UUID? = nil,
                      agent: String? = nil, fromTool: Bool = false) -> ClaudeSessionRecord? {
        let at = milliseconds(date)
        if let existing, at < existing.updated { return nil }
        guard case .set(let state) = outcome else { return nil }
        // A subagent's wait clears only on that subagent's own tools; a new
        // prompt, the end of the turn and the end of the session clear any
        // wait. A wait whose owner is unknown (a notification may carry no
        // agent ID) clears on any tool, so it can never outstay its answer.
        if let existing, existing.state == .permission || existing.state == .question,
           let waiting = existing.agent, state == .working, fromTool, waiting != agent { return nil }
        if var record = existing, record.state == state {
            record.updated = at
            record.project = project ?? record.project
            record.host = host ?? record.host
            record.tab = tab ?? record.tab
            return record
        }
        return ClaudeSessionRecord(state: state, since: at, updated: at, project: project ?? existing?.project,
                                   host: host ?? existing?.host, started: existing == nil ? at : existing?.started,
                                   dismissed: false, tab: tab ?? existing?.tab,
                                   agent: state == .permission || state == .question ? agent : nil)
    }

    /// A subagent ID is only compared, so a short hash is all that is kept.
    static func agentKey(_ id: String) -> String {
        SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    /// The first 32 hex digits of the identifier's SHA-256, so the identifier
    /// is never stored and can never form a path.
    static func fileName(sessionID: String) -> String {
        let digest = SHA256.hash(data: Data(sessionID.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(32) + ".json"
    }

    static func projectName(cwd: String?) -> String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        let name = URL(fileURLWithPath: cwd).lastPathComponent
        return name.isEmpty || name == "/" ? nil : name
    }

    /// Kept only when it looks like a bundle identifier, since it comes from
    /// the environment and is later used to find a running app.
    static func hostIdentifier(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value.count <= 255, value.contains("."),
              !value.hasPrefix("."), !value.hasSuffix("."), !value.contains("..") else { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
        return value.unicodeScalars.allSatisfy { allowed.contains($0) } ? value : nil
    }

    static let hostedWaitPrefix = "nocci-tab-"

    /// Kept only when it parses as a UUID, since it comes from the environment.
    static func tabID(_ value: String?) -> UUID? {
        guard let value else { return nil }
        return UUID(uuidString: value)
    }

    static func isHosted(_ item: ClaudeSessionItem, live: Set<UUID>) -> Bool {
        item.record.tab.map(live.contains) ?? false
    }

    static func isHostedWait(_ item: ClaudeSessionItem) -> Bool { item.id.hasPrefix(hostedWaitPrefix) }

    /// A tab closed in this run drops its rows at once rather than waiting
    /// for the 12-hour expiry; a tab from an earlier run is an ordinary row.
    static func hosted(_ items: [ClaudeSessionItem], closed: Set<UUID>) -> [ClaudeSessionItem] {
        items.filter { item in item.record.tab.map { !closed.contains($0) } ?? true }
    }

    static func hostedItem(_ wait: HostedWait) -> ClaudeSessionItem {
        let since = milliseconds(wait.since)
        return ClaudeSessionItem(id: hostedWaitPrefix + wait.tab.uuidString,
                                 record: ClaudeSessionRecord(state: .waiting, since: since, updated: since, project: wait.project,
                                                             host: nil, started: since, dismissed: false, tab: wait.tab))
    }

    static func isExpired(_ record: ClaudeSessionRecord, at now: Date) -> Bool {
        now.timeIntervalSince(record.updated) >= (record.state == .ended ? endedLifetime : expiry)
    }

    /// Sessions that need the user, most urgent first, then longest waiting.
    static func attention(_ items: [ClaudeSessionItem], at now: Date) -> [ClaudeSessionItem] {
        items.filter { $0.record.state.needsYou && !$0.record.dismissed && !isExpired($0.record, at: now) }
            .sorted {
                if $0.record.state.urgency != $1.record.state.urgency {
                    return $0.record.state.urgency < $1.record.state.urgency
                }
                return $0.record.since != $1.record.since ? $0.record.since < $1.record.since : $0.id < $1.id
            }
    }

    /// Labels for the waiting rows, keyed by id. A project name no other row
    /// shares stands alone; rows sharing one add their app, and rows that still
    /// clash add when the session started. An app not installed any more is
    /// named from the last part of its bundle identifier.
    static func labels(for items: [ClaudeSessionItem], now: Date, appName: (String) -> String?,
                       calendar: Calendar, locale: Locale) -> [String: String] {
        let base = name(of:)
        func named(_ item: ClaudeSessionItem) -> String {
            guard let host = item.record.host,
                  let app = appName(host) ?? host.split(separator: ".").last.map(String.init) else { return base(item) }
            return "\(base(item)) · \(app)"
        }
        func formatter(_ configure: (DateFormatter) -> Void) -> DateFormatter {
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            configure(formatter)
            return formatter
        }
        let today = formatter { $0.timeStyle = .short }
        let earlier = formatter { $0.setLocalizedDateFormatFromTemplate("dMMMjmm") }
        var labels: [String: String] = [:]
        for group in Dictionary(grouping: items, by: base).values {
            guard group.count > 1 else {
                labels[group[0].id] = base(group[0])
                continue
            }
            for clash in Dictionary(grouping: group, by: named).values {
                for item in clash {
                    guard clash.count > 1, let started = item.record.started else {
                        labels[item.id] = named(item)
                        continue
                    }
                    let time = (calendar.isDate(started, inSameDayAs: now) ? today : earlier).string(from: started)
                    labels[item.id] = "\(named(item)) · from \(time)"
                }
            }
        }
        return labels
    }

    /// A session's own name: its project folder, or a generic one without it.
    static func name(of item: ClaudeSessionItem) -> String { item.record.project ?? "Claude Code session" }

    static func milliseconds(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1000).rounded(.down) / 1000)
    }
}

/// Shown in demo mode and the appearance preview. Never read from disk.
enum ClaudeSessionSamples {
    static func items(now: Date) -> [ClaudeSessionItem] {
        func sample(_ id: String, _ state: ClaudeSessionState, _ project: String, minutes: Double) -> ClaudeSessionItem {
            let since = ClaudeSessionRules.milliseconds(now.addingTimeInterval(-minutes * 60))
            return ClaudeSessionItem(id: id, record: ClaudeSessionRecord(state: state, since: since, updated: since,
                                                                          project: project, host: nil))
        }
        return [sample("sample-permission", .permission, "api-server", minutes: 2),
                sample("sample-question", .question, "website", minutes: 6),
                sample("sample-turn", .yourTurn, "mobile-app", minutes: 12)]
    }
}
