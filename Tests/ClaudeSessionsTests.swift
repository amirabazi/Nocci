import Foundation

// Every pure Claude Code session rule, with fixed dates. No hook, file,
// account or network is touched.
@main
struct ClaudeSessionsTests {
    static func main() {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            guard condition() else { fatalError("FAIL: \(label)") }
            checks += 1
        }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func event(_ name: String, notification: String? = nil, tool: String? = nil) -> ClaudeHookEvent {
            ClaudeHookEvent(name: name, sessionID: "s-1", cwd: "/Users/someone/Code/api-server",
                            notificationType: notification, toolName: tool)
        }
        func record(_ state: ClaudeSessionState, since: TimeInterval = 0, updated: TimeInterval = 0,
                    started: TimeInterval? = nil, dismissed: Bool = false) -> ClaudeSessionRecord {
            ClaudeSessionRecord(state: state, since: ClaudeSessionRules.milliseconds(now.addingTimeInterval(since)),
                                updated: ClaudeSessionRules.milliseconds(now.addingTimeInterval(updated)),
                                project: "api-server", host: "com.example.Editor",
                                started: started.map { ClaudeSessionRules.milliseconds(now.addingTimeInterval($0)) },
                                dismissed: dismissed)
        }

        // States
        check(ClaudeSessionState.permission.needsYou && ClaudeSessionState.question.needsYou
              && ClaudeSessionState.yourTurn.needsYou, "Permission, questions and a finished turn need you")
        check(!ClaudeSessionState.working.needsYou && !ClaudeSessionState.ended.needsYou, "Working and ended never do")
        check(ClaudeSessionState.permission.title == "Needs permission" && ClaudeSessionState.question.title == "Asking a question"
              && ClaudeSessionState.yourTurn.title == "Your turn", "Each state names itself")

        // Parsing reads five fields and nothing else
        let payload = Data("""
        {"session_id":"abc-123","hook_event_name":"Notification","cwd":"/Users/someone/Code/api-server",
         "notification_type":"permission_prompt","tool_name":"Bash","transcript_path":"/secret/t.jsonl",
         "user_prompt":"private prompt","last_assistant_message":"private reply","tool_input":{"command":"rm -rf x"}}
        """.utf8)
        let parsed = ClaudeHookEvent.parse(payload)
        check(parsed == ClaudeHookEvent(name: "Notification", sessionID: "abc-123", cwd: "/Users/someone/Code/api-server",
                                        notificationType: "permission_prompt", toolName: "Bash"),
              "The event, session, folder, notification type and tool are read")
        check(!String(describing: parsed as Any).contains("private") && !String(describing: parsed as Any).contains("secret"),
              "Prompts, replies, tool input and the transcript path never reach the value")
        let probeShape = Data(#"{"cwd":"/tmp/p","hook_event_name":"SessionStart","model":"m","scratchpad_dir":"/tmp/s","session_id":"x","source":"startup","transcript_path":"/tmp/t"}"#.utf8)
        check(ClaudeHookEvent.parse(probeShape)?.name == "SessionStart", "The SessionStart shape seen live on 23 September 2026 parses")
        for bad in ["not json", "[1,2]", #"{"hook_event_name":"Stop"}"#, #"{"hook_event_name":"","session_id":"x"}"#,
                    #"{"hook_event_name":"Stop","session_id":""}"#, #"{"hook_event_name":7,"session_id":"x"}"#] {
            check(ClaudeHookEvent.parse(Data(bad.utf8)) == nil, "Rejected payload: \(bad)")
        }

        // Event to outcome
        let table: [(ClaudeHookEvent, ClaudeSessionOutcome)] = [
            (event("SessionStart"), .set(.working)), (event("UserPromptSubmit"), .set(.working)),
            (event("PostToolUse", tool: "Bash"), .set(.working)),
            (event("PreToolUse", tool: "AskUserQuestion"), .set(.question)),
            (event("PreToolUse", tool: "Bash"), .set(.working)),
            (event("PermissionRequest", tool: "Bash"), .set(.permission)),
            (event("Notification", notification: "permission_prompt"), .set(.permission)),
            (event("Notification", notification: "elicitation_dialog"), .set(.question)),
            (event("Notification", notification: "elicitation_url_dialog"), .set(.question)),
            (event("Notification", notification: "agent_needs_input"), .set(.question)),
            (event("Notification", notification: "idle_prompt"), .ignore),
            (event("Notification", notification: "auth_success"), .ignore),
            (event("Notification"), .ignore),
            (event("Stop"), .set(.yourTurn)), (event("SessionEnd"), .set(.ended)),
            (event("SubagentStop"), .ignore), (event("SomethingNew"), .ignore)]
        for (input, expected) in table {
            check(ClaudeSessionRules.outcome(for: input) == expected,
                  "\(input.name) \(input.notificationType ?? input.toolName ?? "") maps correctly")
        }

        // Merging
        let fresh = ClaudeSessionRules.merge(existing: nil, outcome: .set(.permission), at: now,
                                             project: "api-server", host: "com.example.Editor")
        check(fresh == record(.permission, started: 0), "A first event starts a record and notes when the session started")
        let repeated = ClaudeSessionRules.merge(existing: record(.permission, dismissed: true), outcome: .set(.permission),
                                                at: now.addingTimeInterval(30), project: nil, host: nil)
        check(repeated == record(.permission, since: 0, updated: 30, dismissed: true),
              "The same state again keeps its start, its dismissal, project and host")
        let changed = ClaudeSessionRules.merge(existing: record(.permission, dismissed: true), outcome: .set(.yourTurn),
                                               at: now.addingTimeInterval(40), project: nil, host: nil)
        check(changed == record(.yourTurn, since: 40, updated: 40), "A new state starts fresh and is no longer dismissed")
        check(ClaudeSessionRules.merge(existing: record(.yourTurn, since: 40, updated: 40), outcome: .set(.working),
                                       at: now.addingTimeInterval(39.5), project: nil, host: nil) == nil,
              "An older event never overwrites a newer one")
        check(ClaudeSessionRules.merge(existing: record(.ended, since: 50, updated: 50), outcome: .set(.yourTurn),
                                       at: now.addingTimeInterval(49), project: nil, host: nil) == nil,
              "A late event cannot revive a session that has ended")
        check(ClaudeSessionRules.merge(existing: record(.yourTurn), outcome: .ignore, at: now.addingTimeInterval(5),
                                       project: nil, host: nil) == nil, "An ignored event changes nothing")
        check(ClaudeSessionRules.merge(existing: nil, outcome: .set(.working), at: now.addingTimeInterval(0.0017),
                                       project: nil, host: nil).map { ($0.since.timeIntervalSince1970 * 1000).rounded() }
              == 1_800_000_000_001,
              "Times are kept to the millisecond, so they survive storage exactly")

        // Parallel subagents share one session. Another agent's tool activity
        // must not clear a wait; the waiting agent's own tools, a new prompt
        // and the end of the turn do.
        let withAgent = Data(#"{"session_id":"s","hook_event_name":"PermissionRequest","agent_id":"agent-7f3","tool_name":"Bash"}"#.utf8)
        let agentEvent = ClaudeHookEvent.parse(withAgent)
        check(agentEvent?.agent != nil && agentEvent?.agent != "agent-7f3"
              && agentEvent?.agent == ClaudeHookEvent.parse(withAgent)?.agent,
              "A subagent is told apart by a hash of its ID, never the ID itself")
        var subagentWait = record(.permission)
        subagentWait.agent = "a"
        check(ClaudeSessionRules.merge(existing: subagentWait, outcome: .set(.working), at: now.addingTimeInterval(5),
                                       project: nil, host: nil, agent: "b", fromTool: true) == nil,
              "Another subagent's tool leaves a subagent's permission prompt waiting")
        // Notifications may carry no agent ID, so a wait whose owner is
        // unknown clears on any tool event, as it always did.
        check(ClaudeSessionRules.merge(existing: record(.question), outcome: .set(.working), at: now.addingTimeInterval(5),
                                       project: nil, host: nil, agent: "b", fromTool: true)?.state == .working,
              "A wait whose owner is unknown clears on any agent's tool")
        check(ClaudeSessionRules.merge(existing: subagentWait, outcome: .set(.working), at: now.addingTimeInterval(5),
                                       project: nil, host: nil, agent: "a", fromTool: true)?.state == .working,
              "The waiting subagent's own tool clears its wait")
        check(ClaudeSessionRules.merge(existing: record(.permission), outcome: .set(.working), at: now.addingTimeInterval(5),
                                       project: nil, host: nil, agent: nil, fromTool: true)?.state == .working,
              "The main agent's own tool clears its wait")
        check(ClaudeSessionRules.merge(existing: subagentWait, outcome: .set(.working), at: now.addingTimeInterval(5),
                                       project: nil, host: nil, agent: nil, fromTool: false)?.state == .working,
              "A new prompt clears any wait")
        check(ClaudeSessionRules.merge(existing: nil, outcome: .set(.question), at: now, project: nil, host: nil,
                                       agent: "a", fromTool: true)?.agent == "a", "A wait remembers whose it is")
        check(ClaudeSessionRules.merge(existing: subagentWait, outcome: .set(.permission), at: now.addingTimeInterval(5),
                                       project: nil, host: nil, agent: nil)?.agent == "a",
              "A notification without an agent keeps the waiting agent")
        check(ClaudeSessionRules.merge(existing: subagentWait, outcome: .set(.yourTurn), at: now.addingTimeInterval(5),
                                       project: nil, host: nil, agent: nil)?.agent == nil, "A finished turn belongs to no subagent")

        // When a session started: set by its first event, then never moved.
        let begun = record(.working, started: -600)
        check(ClaudeSessionRules.merge(existing: begun, outcome: .set(.working), at: now.addingTimeInterval(5),
                                       project: nil, host: nil)?.started == begun.started, "The same state keeps the start")
        check(ClaudeSessionRules.merge(existing: begun, outcome: .set(.yourTurn), at: now.addingTimeInterval(5),
                                       project: nil, host: nil)?.started == begun.started, "A new state keeps the start")
        check(ClaudeSessionRules.merge(existing: begun, outcome: .set(.ended), at: now.addingTimeInterval(5),
                                       project: nil, host: nil)?.started == begun.started, "The ended marker keeps the start")
        check(ClaudeSessionRules.merge(existing: record(.working), outcome: .set(.yourTurn), at: now.addingTimeInterval(5),
                                       project: nil, host: nil)?.started == nil,
              "A record from before start times were kept is never back-filled")
        let old = Data(#"{"dismissed":false,"host":"com.example.Editor","project":"api-server","since":1800000000000,"state":"yourTurn","updated":1800000000000}"#.utf8)
        check(ClaudeSessionRecord.decode(old)?.started == nil && ClaudeSessionRecord.decode(old)?.state == .yourTurn,
              "A file written before this change still loads")
        check(ClaudeSessionRecord.decode(begun.encoded())?.started == begun.started, "The start round-trips to the millisecond")

        // Records round-trip
        let stored = record(.question, since: -12.345, updated: 1.5, dismissed: true)
        check(ClaudeSessionRecord.decode(stored.encoded()) == stored, "A record survives encoding exactly")
        check(ClaudeSessionRecord.decode(Data("garbage".utf8)) == nil && ClaudeSessionRecord.decode(Data("{}".utf8)) == nil,
              "Garbage decodes to nothing")

        // File names never carry the identifier or a path
        let name = ClaudeSessionRules.fileName(sessionID: "abc-123")
        check(name == ClaudeSessionRules.fileName(sessionID: "abc-123") && name != ClaudeSessionRules.fileName(sessionID: "abc-124"),
              "One file per session")
        for id in ["abc-123", "../../etc/passwd", "a/b", "", "\u{0}"] {
            let file = ClaudeSessionRules.fileName(sessionID: id)
            check(file.count == 37 && file.hasSuffix(".json") && file.dropLast(5).allSatisfy { "0123456789abcdef".contains($0) },
                  "File name for \(id.debugDescription) is 32 hex digits")
        }
        check(!name.contains("abc"), "The raw session identifier is never stored")

        // Project and host
        check(ClaudeSessionRules.projectName(cwd: "/Users/someone/Code/api-server") == "api-server", "Folder name")
        check(ClaudeSessionRules.projectName(cwd: "/Users/someone/Code/api-server/") == "api-server", "Trailing slash")
        check(ClaudeSessionRules.projectName(cwd: "/") == nil && ClaudeSessionRules.projectName(cwd: "") == nil
              && ClaudeSessionRules.projectName(cwd: nil) == nil, "No folder, no name")
        check(ClaudeSessionRules.hostIdentifier("com.microsoft.VSCode") == "com.microsoft.VSCode"
              && ClaudeSessionRules.hostIdentifier("com.googlecode.iterm2") == "com.googlecode.iterm2", "Bundle identifiers are kept")
        for bad in [nil, "", "Terminal", "com.example app", "../x", "com/example", String(repeating: "a.", count: 200)] {
            check(ClaudeSessionRules.hostIdentifier(bad) == nil, "Rejected host: \(bad ?? "nil")")
        }

        // Attention list
        let items = [
            ClaudeSessionItem(id: "turn-old", record: record(.yourTurn, since: -1200, updated: -1200)),
            ClaudeSessionItem(id: "question", record: record(.question, since: -60, updated: -60)),
            ClaudeSessionItem(id: "permission-new", record: record(.permission, since: -10, updated: -10)),
            ClaudeSessionItem(id: "permission-old", record: record(.permission, since: -300, updated: -300)),
            ClaudeSessionItem(id: "working", record: record(.working, since: -5, updated: -5)),
            ClaudeSessionItem(id: "dismissed", record: record(.permission, since: -20, updated: -20, dismissed: true)),
            ClaudeSessionItem(id: "expired", record: record(.yourTurn, since: -43_200, updated: -43_200)),
            ClaudeSessionItem(id: "ended", record: record(.ended, since: -1, updated: -1))]
        check(ClaudeSessionRules.attention(items, at: now).map(\.id) == ["permission-old", "permission-new", "question", "turn-old"],
              "Only sessions needing you, most urgent first, then longest waiting")
        check(ClaudeSessionRules.isExpired(record(.yourTurn, updated: -43_200), at: now)
              && !ClaudeSessionRules.isExpired(record(.yourTurn, updated: -43_199), at: now), "Twelve hours without news expires")
        check(ClaudeSessionRules.isExpired(record(.ended, updated: -60), at: now)
              && !ClaudeSessionRules.isExpired(record(.ended, updated: -59), at: now), "An ended marker lasts a minute")

        // Labels: detail only where project names clash. `now` is 15 January 2027, 08:00 UTC.
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let vscode = "com.microsoft.VSCode", iterm = "com.googlecode.iterm2"
        func row(_ id: String, _ project: String?, _ host: String?, started: TimeInterval? = nil) -> ClaudeSessionItem {
            ClaudeSessionItem(id: id, record: ClaudeSessionRecord(state: .yourTurn, since: now, updated: now, project: project,
                                                                  host: host, started: started.map { now.addingTimeInterval($0) }))
        }
        func labels(_ rows: [ClaudeSessionItem]) -> [String: String] {
            ClaudeSessionRules.labels(for: rows, now: now, appName: { [vscode: "Visual Studio Code", iterm: "iTerm"][$0] },
                                      calendar: utc, locale: Locale(identifier: "en_GB"))
        }
        check(labels([row("a", "api-server", iterm), row("b", "website", vscode)]) == ["a": "api-server", "b": "website"],
              "Unique project names are unchanged")
        check(labels([row("v", "mobile-app", vscode, started: -100), row("i", "mobile-app", iterm, started: -100)])
              == ["v": "mobile-app · Visual Studio Code", "i": "mobile-app · iTerm"], "A shared name adds the app")
        check(labels([row("x", "mobile-app", iterm, started: -2880), row("y", "mobile-app", iterm, started: -1200)])
              == ["x": "mobile-app · iTerm · from 07:12", "y": "mobile-app · iTerm · from 07:40"],
              "A shared name and app add when each session started")
        check(labels([row("z", "mobile-app", iterm, started: -35_700), row("y", "mobile-app", iterm, started: -1200)])["z"]
              == "mobile-app · iTerm · from 14 Jan at 22:05", "A session from an earlier day names the day")
        check(labels([row("n", "mobile-app", iterm), row("y", "mobile-app", iterm, started: -1200)])
              == ["n": "mobile-app · iTerm", "y": "mobile-app · iTerm · from 07:40"],
              "A session from before start times were kept shows no time; its twin still does")
        check(labels([row("t", "mobile-app", "com.example.Tool"), row("i", "mobile-app", iterm)])
              == ["t": "mobile-app · Tool", "i": "mobile-app · iTerm"],
              "An app that is no longer installed is named from its bundle identifier")
        check(labels([row("h", "mobile-app", nil), row("i", "mobile-app", iterm)]) == ["h": "mobile-app", "i": "mobile-app · iTerm"],
              "A session with no known app adds no app")
        check(labels([row("h1", "mobile-app", nil, started: -2880), row("h2", "mobile-app", nil, started: -1200)])
              == ["h1": "mobile-app · from 07:12", "h2": "mobile-app · from 07:40"], "Two sessions with no known app add their times")
        check(labels([row("x", "mobile-app", iterm, started: -2880), row("y", "mobile-app", iterm, started: -1200),
                      row("v", "mobile-app", vscode, started: -100)])
              == ["x": "mobile-app · iTerm · from 07:12", "y": "mobile-app · iTerm · from 07:40",
                  "v": "mobile-app · Visual Studio Code"], "Only the rows that still clash get a time")
        check(labels([row("p", nil, iterm), row("q", nil, vscode), row("a", "api-server", iterm)])
              == ["p": "Claude Code session · iTerm", "q": "Claude Code session · Visual Studio Code", "a": "api-server"],
              "A session with no project uses the generic name, and clashes like any other")

        // Samples
        let samples = ClaudeSessionSamples.items(now: now)
        check(samples.count == 3 && Set(samples.map(\.record.state)) == [.permission, .question, .yourTurn]
              && ClaudeSessionRules.attention(samples, at: now).count == 3, "Samples show one row per state")

        // MARK: Nocci tabs
        let tab = UUID(), other = UUID()
        check(ClaudeSessionRules.tabID(tab.uuidString) == tab && ClaudeSessionRules.tabID("not-a-uuid") == nil
              && ClaudeSessionRules.tabID(nil) == nil && ClaudeSessionRules.tabID("") == nil, "Only a well-formed tab ID is kept")
        let hostedRecord = ClaudeSessionRules.merge(existing: nil, outcome: .set(.permission), at: now, project: "api",
                                                    host: "com.example.Nocci", tab: tab)!
        check(hostedRecord.tab == tab && ClaudeSessionRecord.decode(hostedRecord.encoded())?.tab == tab, "The tab round-trips")
        check(ClaudeSessionRules.merge(existing: hostedRecord, outcome: .set(.yourTurn), at: now.addingTimeInterval(1),
                                       project: nil, host: nil)?.tab == tab, "A later event without a tab keeps it")
        check(ClaudeSessionRules.merge(existing: hostedRecord, outcome: .set(.permission), at: now.addingTimeInterval(1),
                                       project: nil, host: nil)?.tab == tab, "A repeated state without a tab keeps it")
        check(ClaudeSessionRules.merge(existing: hostedRecord, outcome: .set(.yourTurn), at: now.addingTimeInterval(1),
                                       project: nil, host: nil, tab: other)?.tab == other, "A later event with a tab updates it")
        check(ClaudeSessionRecord.decode(old)?.tab == nil, "A file from before tabs were stored still loads")
        check(String(decoding: hostedRecord.encoded(), as: UTF8.self).contains("\"tab\":\"\(tab.uuidString)\""),
              "The tab is stored as its plain UUID string")
        check(!String(decoding: record(.question).encoded(), as: UTF8.self).contains("tab"), "A record without a tab stores none")
        let hostedItem = ClaudeSessionItem(id: "h", record: hostedRecord)
        let closedItem = ClaudeSessionItem(id: "c", record: ClaudeSessionRules.merge(existing: nil, outcome: .set(.yourTurn), at: now,
                                                                                     project: "web", host: nil, tab: other)!)
        let plainItem = ClaudeSessionItem(id: "p", record: record(.question))
        check(ClaudeSessionRules.isHosted(hostedItem, live: [tab]) && !ClaudeSessionRules.isHosted(hostedItem, live: [])
              && !ClaudeSessionRules.isHosted(plainItem, live: [tab]), "A row is hosted only while its tab is live")
        check(ClaudeSessionRules.hosted([hostedItem, closedItem, plainItem], closed: [other]) == [hostedItem, plainItem],
              "A tab closed this run drops its row at once; live and unhosted rows stay")
        check(ClaudeSessionRules.hosted([hostedItem], closed: []) == [hostedItem], "Nothing closed, nothing dropped")
        let wait = HostedWait(tab: tab, project: "web", since: now)
        let waitItem = ClaudeSessionRules.hostedItem(wait)
        check(waitItem.id == "nocci-tab-" + tab.uuidString && waitItem.record.state == .waiting && waitItem.record.state.needsYou
              && waitItem.record.project == "web" && waitItem.record.tab == tab && waitItem.record.host == nil
              && waitItem.record.since == now && waitItem.record.started == now, "A Codex wait becomes a row with the tab's label")
        check(ClaudeSessionRules.isHostedWait(waitItem) && !ClaudeSessionRules.isHostedWait(hostedItem), "A Codex wait is told apart by its id")
        check(ClaudeSessionState.waiting.urgency > ClaudeSessionState.question.urgency
              && ClaudeSessionState.waiting.urgency < ClaudeSessionState.yourTurn.urgency,
              "A Codex wait ranks between a question and a finished turn")
        check(ClaudeSessionState.waiting.title == "Needs you", "A Codex wait has one generic state")
        check(ClaudeSessionRules.attention([waitItem, hostedItem], at: now).map(\.id) == ["h", waitItem.id],
              "A Codex wait sorts with the others")
        check(ClaudeSessionRules.labels(for: [waitItem], now: now, appName: { _ in nil }, calendar: .current, locale: .current)[waitItem.id] == "web",
              "A Codex wait is labelled by its tab")
        check(ClaudeSessionHosting() == ClaudeSessionHosting(live: [], closed: [], waits: []), "Hosting starts empty")

        print("\(checks) claude-session checks passed")
    }
}
