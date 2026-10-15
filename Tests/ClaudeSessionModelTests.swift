import Foundation
import Combine

// Drives the real session model through a real UsageModel and a temporary
// session directory, with injected status, activation, delivery and clock.
// No hook, Claude Code session, app or notification centre is touched.
final class RecordingDelivery: AlertDelivery {
    var sent: [AlertMessage] = []
    func send(_ message: AlertMessage, sound: Bool) { sent.append(message) }
}

@main
struct ClaudeSessionModelTests {
    static func main() throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            guard condition() else { fatalError("FAIL: \(label)") }
            checks += 1
        }
        let suite = "nocci-session-model-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nocci-session-model-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ClaudeSessionStore(directory: root.appendingPathComponent("Sessions"))

        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        var status = ClaudeHooksStatus.off
        var activated: [String] = []
        let delivery = RecordingDelivery()
        let usage = UsageModel(fetchCodex: { _ in }, loadClaude: { $0(nil) },
                               inspectClaude: { _ in .notConfigured }, defaults: defaults)
        let model = ClaudeSessionModel(usage: usage, store: store, defaults: defaults,
                                       status: { status }, activate: { activated.append($0); return true },
                                       delivery: delivery, now: { clock }, io: { $0() }, main: { $0() }, watch: false)
        func advance(_ seconds: TimeInterval) {
            clock = clock.addingTimeInterval(seconds)
            usage.tick = clock
        }
        func hook(_ name: String, _ id: String, notification: String? = nil, cwd: String = "/Users/someone/Code/api-server",
                  host: String? = "com.example.Editor", tab: UUID? = nil) {
            try? store.apply(ClaudeHookEvent(name: name, sessionID: id, cwd: cwd, notificationType: notification, toolName: nil),
                             at: clock, host: host, tab: tab)
        }

        // Off: nothing is read or shown.
        hook("PermissionRequest", "a")
        advance(5)
        check(!model.enabled && model.items.isEmpty, "Nothing is shown while session status is off")
        check(!model.notify && defaults.object(forKey: "sessions.notify") == nil, "Notifications start off")

        // On: the first scan is a silent baseline.
        model.notify = true
        check(defaults.bool(forKey: "sessions.notify"), "The notification choice is remembered")
        status = .on
        model.refreshStatus()
        check(model.enabled && model.items.map(\.record.state) == [.permission] && model.needsYou,
              "Turning on shows the session that needs you")
        check(delivery.sent.isEmpty, "Sessions already waiting at launch are a silent baseline")
        check(model.waitCount == 0, "Sessions already waiting at launch are not counted as new waits")

        // New waits notify once.
        advance(1)
        hook("Stop", "b", cwd: "/Users/someone/Code/website")
        advance(5)
        check(model.items.map(\.record.project) == ["api-server", "website"], "Most urgent first")
        check(delivery.sent.count == 1 && delivery.sent[0].title == "Claude Code"
              && delivery.sent[0].body == "website finished: your turn" && delivery.sent[0].identifier.hasPrefix("nocci.session."),
              "A new wait sends one notification with the project and state only")
        check(model.waitCount == 1, "A new wait is counted once")
        advance(1)
        hook("Stop", "b", cwd: "/Users/someone/Code/website")
        advance(5)
        check(delivery.sent.count == 1, "The same wait repeated sends nothing more")
        check(model.waitCount == 1, "The same wait repeated is not counted again")
        hook("PreToolUse", "c", cwd: "/Users/someone/Code/mobile-app")
        try? store.apply(ClaudeHookEvent(name: "PreToolUse", sessionID: "c", cwd: "/Users/someone/Code/mobile-app",
                                         notificationType: nil, toolName: "AskUserQuestion"), at: clock, host: nil)
        advance(5)
        check(delivery.sent.last?.body == "mobile-app is asking a question" && model.items.count == 3, "Questions notify too")
        check(model.waitCount == 2, "Each new wait is counted")

        // Presentation mode withholds without a backlog.
        usage.presentation = PresentationState(minutes: 60, from: clock)
        hook("PermissionRequest", "d", cwd: "/Users/someone/Code/docs")
        advance(5)
        check(delivery.sent.count == 2 && model.items.count == 4, "Presentation mode sends nothing, the list still updates")
        check(model.waitCount == 3, "A wait is counted while presenting; the notch decides what to show")
        usage.presentation = PresentationState()
        advance(5)
        check(delivery.sent.count == 2, "Ending presentation mode releases no backlog")

        // Dismissing
        let website = model.items.first { $0.record.project == "website" }!
        model.dismiss(website)
        check(!model.items.contains { $0.id == website.id }, "A dismissed row disappears")
        advance(1)
        hook("Stop", "b", cwd: "/Users/someone/Code/website")
        advance(5)
        check(!model.items.contains { $0.id == website.id }, "The same wait stays dismissed")
        hook("UserPromptSubmit", "b", cwd: "/Users/someone/Code/website")
        advance(1)
        hook("Stop", "b", cwd: "/Users/someone/Code/website")
        advance(5)
        check(model.items.contains { $0.id == website.id }, "A new wait brings the session back")
        model.dismissAll()
        check(model.items.isEmpty && !model.needsYou, "Dismiss All clears the list")

        let beforeForward = model.waitCount
        model.notify = false
        // Bringing an app forward
        hook("PermissionRequest", "e", cwd: "/Users/someone/Code/cli")
        hook("PermissionRequest", "f", cwd: "/Users/someone/Code/nohost", host: nil)
        advance(5)
        check(model.waitCount == beforeForward + 1,
              "Waits arriving together count once, and counting ignores the notification switch")
        model.notify = true
        let withHost = model.items.first { $0.record.project == "cli" }!
        let withoutHost = model.items.first { $0.record.project == "nohost" }!
        check(model.open(withHost) && activated == ["com.example.Editor"], "A click brings the session's app forward")
        check(!model.open(withoutHost) && activated.count == 1, "Without a known app, a click does nothing")

        // Expiry
        advance(43_200)
        check(model.items.isEmpty && store.load().isEmpty, "Twelve hours without news removes every session file")

        // Demo
        hook("PermissionRequest", "g")
        let countBeforeDemo = model.waitCount
        usage.toggleDemo()
        check(model.demo && model.items.map(\.id) == ClaudeSessionSamples.items(now: clock).map(\.id),
              "Demo shows the samples, not the real sessions")
        check(model.waitCount == countBeforeDemo, "Demo samples are never counted as waits")
        check(!model.open(model.items[0]) && activated.count == 1, "Sample rows never activate an app")
        let before = store.load().count
        model.dismiss(model.items[0])
        check(store.load().count == before && store.load().allSatisfy { !$0.record.dismissed }, "Dismissing a sample touches no file")
        usage.toggleDemo()
        check(!model.demo && model.items.map(\.record.project) == ["api-server"], "Leaving demo shows the real sessions again")

        // Turning off
        status = .off
        model.refreshStatus()
        check(!model.enabled && model.items.isEmpty, "Turning off hides everything")
        status = .moved(installedCommand: "'/old/Nocci' --claude-hook")
        model.refreshStatus()
        check(model.enabled, "Hooks from a moved app still count as on until reinstalled")

        // The live path: a file written by a hook shows without waiting for the next tick.
        let watchedStore = ClaudeSessionStore(directory: root.appendingPathComponent("Watched"))
        let watched = ClaudeSessionModel(usage: usage, store: watchedStore, defaults: defaults, status: { .on },
                                         activate: { _ in true }, now: { clock }, watch: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        try? watchedStore.apply(ClaudeHookEvent(name: "PermissionRequest", sessionID: "w", cwd: "/tmp/example/watched",
                                                notificationType: nil, toolName: nil), at: clock, host: nil)
        let deadline = Date().addingTimeInterval(3)
        while watched.items.isEmpty && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        check(watched.items.map(\.record.project) == ["watched"], "A new session file shows without waiting for the next tick")

        // Turning on and off through Settings
        let appFile = root.appendingPathComponent("App/Nocci.app/Contents/MacOS/Nocci")
        try FileManager.default.createDirectory(at: appFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: appFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: appFile.path)
        let paths = ClaudePaths(configDirectory: root.appendingPathComponent("claude"), supportDirectory: root.appendingPathComponent("support"))
        let setupStore = ClaudeSessionStore(directory: root.appendingPathComponent("SetupSessions"))
        let setup = ClaudeSessionModel(usage: usage, store: setupStore, defaults: defaults,
                                       installer: { ClaudeHooksInstaller(paths: paths, appPath: appFile.path) },
                                       activate: { _ in true }, now: { clock }, io: { $0() }, main: { $0() }, watch: false)
        check(!setup.enabled && setup.status == .off, "Status comes from the installer")
        let plan = try setup.reviewPlan()
        check(plan.settingsPath == paths.settingsFile.path && plan.fragment.contains("--claude-hook"), "The review shows the planned hooks")
        try setup.turnOn()
        check(setup.enabled && setup.status == .on, "Turning on installs the hooks")
        try? setupStore.apply(ClaudeHookEvent(name: "Stop", sessionID: "z", cwd: "/tmp/example/setup", notificationType: nil,
                                              toolName: nil), at: clock, host: nil)
        advance(5)
        check(setup.items.map(\.record.project) == ["setup"], "Sessions show once turned on")
        try setup.turnOff()
        check(!setup.enabled && setup.items.isEmpty && !FileManager.default.fileExists(atPath: setupStore.directory.path)
              && ((try? String(contentsOf: paths.settingsFile, encoding: .utf8)) ?? "").contains("--claude-hook") == false,
              "Turning off removes Nocci's hooks and every session file")

        // Rows sharing a project name carry their app's Finder name, looked up once per app.
        let vscode = "com.microsoft.VSCode", iterm = "com.googlecode.iterm2"
        let labelStore = ClaudeSessionStore(directory: root.appendingPathComponent("labels").appendingPathComponent("Sessions"))
        var lookups: [String] = []
        let labelled = ClaudeSessionModel(usage: usage, store: labelStore, defaults: defaults, status: { .on },
                                          activate: { _ in true },
                                          appName: { lookups.append($0); return [vscode: "Visual Studio Code", iterm: "iTerm"][$0] },
                                          now: { clock }, io: { $0() }, main: { $0() }, watch: false)
        for (id, host) in [("vs", vscode), ("it", iterm)] {
            try? labelStore.apply(ClaudeHookEvent(name: "Stop", sessionID: id, cwd: "/Users/someone/Code/mobile-app",
                                                  notificationType: nil, toolName: nil), at: clock, host: host)
        }
        labelled.refreshStatus()
        let hostLabels = Dictionary(uniqueKeysWithValues: labelled.items.map { ($0.record.host ?? "", labelled.labels[$0.id] ?? "") })
        check(hostLabels == [vscode: "mobile-app · Visual Studio Code", iterm: "mobile-app · iTerm"],
              "Two sessions in one project are told apart by their apps")
        _ = labelled.labels
        check(lookups.sorted() == [iterm, vscode], "Each app's name is looked up once")
        labelled.dismiss(labelled.items.first { $0.record.host == vscode }!)
        check(Array(labelled.labels.values) == ["mobile-app"], "A dismissed session no longer forces detail on the other")

        // MARK: Nocci-hosted rows
        model.dismissAll()
        advance(1)
        var summoned: [UUID] = []
        var clearedWaits: [UUID] = []
        model.onSummon = { summoned.append($0) }
        model.onClearWait = { clearedWaits.append($0) }
        let nocci = "com.github.amirabazi.nocci"
        let liveTab = UUID(), oldTab = UUID(), goneTab = UUID()
        hook("PermissionRequest", "hosted", cwd: "/Users/someone/Code/api", host: nocci, tab: liveTab)
        advance(1)
        hook("Stop", "earlier", cwd: "/Users/someone/Code/web", host: nocci, tab: oldTab)
        advance(1)
        hook("Stop", "closed", cwd: "/Users/someone/Code/cli", host: nocci, tab: goneTab)
        advance(5)
        check(model.items.map(\.id) == ["hosted", "earlier", "closed"].map { ClaudeSessionRules.fileName(sessionID: $0).replacingOccurrences(of: ".json", with: "") }
              && !model.isHosted(model.items[0]), "Without hosting every row is ordinary")
        let hostedID = model.items[0].id, earlierID = model.items[1].id
        let sentBefore = delivery.sent.count, countBefore = model.waitCount
        model.setHosting(ClaudeSessionHosting(live: [liveTab], closed: [goneTab], waits: []))
        check(model.items.map(\.id) == [hostedID, earlierID], "A tab closed this run drops its row at once")
        check(model.isHosted(model.items[0]) && !model.isHosted(model.items[1]), "A live tab's row is hosted; an earlier run's is ordinary")
        check(delivery.sent.count == sentBefore && model.waitCount == countBefore, "Hosting changes alone are not new waits")
        activated = []
        check(model.open(model.items[0]) && summoned == [liveTab] && activated.isEmpty, "Clicking a hosted row summons its tab, never its app")
        check(model.open(model.items[1]) && activated == [nocci] && summoned == [liveTab], "An earlier run's row still opens its app")

        // MARK: Codex waits
        let codexTab = UUID()
        let waitSince = clock
        let waitID = ClaudeSessionRules.hostedWaitPrefix + codexTab.uuidString
        model.setHosting(ClaudeSessionHosting(live: [liveTab, codexTab], closed: [goneTab],
                                              waits: [HostedWait(tab: codexTab, project: "mobile", since: waitSince)]))
        check(model.items.map(\.record.state) == [.permission, .waiting, .yourTurn], "A Codex wait joins the list at its urgency")
        check(model.labels[waitID] == "mobile", "A Codex wait is labelled by its tab")
        check(delivery.sent.count == sentBefore + 1 && delivery.sent.last?.title == "Codex" && delivery.sent.last?.body == "mobile needs you"
              && delivery.sent.last?.identifier == "nocci.session." + waitID,
              "A new Codex wait notifies once, naming only the tab")
        check(model.waitCount == countBefore + 1, "A new Codex wait bounces the notch")
        model.setHosting(ClaudeSessionHosting(live: [liveTab, codexTab], closed: [goneTab],
                                              waits: [HostedWait(tab: codexTab, project: "mobile", since: waitSince)]))
        check(delivery.sent.count == sentBefore + 1 && model.waitCount == countBefore + 1, "The same wait again is not news")
        check(model.open(model.items[1]) && summoned.last == codexTab, "Clicking a Codex wait summons its tab")
        model.dismiss(model.items[1])
        check(clearedWaits == [codexTab], "Dismissing a Codex wait clears it in the terminal")
        model.setHosting(ClaudeSessionHosting(live: [liveTab, codexTab], closed: [goneTab], waits: []))
        check(model.items.map(\.id) == [hostedID, earlierID], "A cleared wait leaves the list")

        // MARK: Answering
        check(model.answering == nil, "Nothing is being answered")
        model.toggleAnswer(model.items[1])
        check(model.answering == nil, "An ordinary row cannot be answered from the notch")
        model.toggleAnswer(model.items[0])
        check(model.answering?.id == hostedID, "A hosted row opens its mini view")
        hook("PostToolUse", "hosted", cwd: "/Users/someone/Code/api", host: nocci, tab: liveTab)
        advance(5)
        check(model.items.map(\.id) == [hostedID, earlierID] && model.answering?.id == hostedID,
              "A row being answered stays in the list after its wait ends")
        check(model.items[0].record.state == .working, "The held row shows what the session is doing now")
        model.toggleAnswer(model.items[0])
        check(model.answering == nil && model.items.map(\.id) == [earlierID], "Closing the mini view lets the row go")
        model.toggleAnswer(ClaudeSessionItem(id: hostedID, record: model.items[0].record))
        check(model.answering == nil, "Only a listed, hosted row can be answered")
        hook("PermissionRequest", "hosted", cwd: "/Users/someone/Code/api", host: nocci, tab: liveTab)
        advance(5)
        model.toggleAnswer(model.items[0])
        check(model.answering?.id == hostedID, "The row can be answered again on its next wait")
        model.setHosting(ClaudeSessionHosting(live: [codexTab], closed: [goneTab, liveTab], waits: []))
        check(model.answering == nil && model.items.map(\.id) == [earlierID], "Closing the tab ends the answer and drops the row")
        hook("PermissionRequest", "again", cwd: "/Users/someone/Code/api", host: nocci, tab: codexTab)
        advance(5)
        let againID = model.items[0].id
        model.toggleAnswer(model.items[0])
        check(model.answering?.id == againID, "A row in another live tab can be answered")
        usage.toggleDemo()
        check(model.answering == nil, "Demo mode closes the mini view")
        usage.toggleDemo()
        advance(5)
        model.toggleAnswer(model.items[0])
        check(model.answering?.id == againID, "Answering works again after demo")
        status = .off
        model.refreshStatus()
        check(model.answering == nil && model.items.isEmpty, "Turning Sessions off closes the mini view and hides every row")
        status = .on
        model.refreshStatus()
        advance(5)
        model.toggleAnswer(model.items[0])
        model.endAnswer()
        check(model.answering == nil, "endAnswer closes it from outside")

        // Handing the keyboard back resigns the panel, whose observer ends the
        // answer again from inside the change that is clearing it.
        var reentered = 0
        let reentry = model.$answering.dropFirst().sink { value in
            guard value == nil else { return }
            reentered += 1
            model.endAnswer()
        }
        model.toggleAnswer(model.items[0])
        model.endAnswer()
        check(model.answering == nil && reentered == 1, "Ending an answer from inside its own change is ignored")
        model.toggleAnswer(model.items[0])
        let reentryTab = model.items[0].record.tab!
        model.setHosting(ClaudeSessionHosting(live: [], closed: [reentryTab], waits: []))
        check(model.answering == nil && reentered == 2, "A closed tab ending the answer survives the same re-entry")
        reentry.cancel()

        // MARK: Rows whose tab lives in the notch
        let notchTab = UUID()
        hook("PermissionRequest", "notch", cwd: "/Users/someone/Code/notch", host: nocci, tab: notchTab)
        advance(5)
        model.setHosting(ClaudeSessionHosting(live: [notchTab], closed: [], waits: [], notch: [notchTab]))
        let notchRow = model.items.first { $0.record.tab == notchTab }!
        check(model.isHosted(notchRow) && model.isInNotch(notchRow), "A notch tab's row is hosted, in the notch")
        model.toggleAnswer(notchRow)
        check(model.answering == nil, "A notch row has no mini view")
        summoned = []
        check(model.open(notchRow) && summoned == [notchTab], "Clicking a notch row hands its tab over for AppDelegate to route")
        model.setHosting(ClaudeSessionHosting(live: [notchTab], closed: [], waits: [], notch: []))
        let movedRow = model.items.first { $0.record.tab == notchTab }!
        check(model.isHosted(movedRow) && !model.isInNotch(movedRow), "Once its tab moves to the window the row is an ordinary hosted row")
        model.toggleAnswer(movedRow)
        check(model.answering?.id == movedRow.id, "and it can be answered from a mini view again")
        model.endAnswer()

        // MARK: A hosting change before the first read
        var pending: [() -> Void] = []
        let lateStore = ClaudeSessionStore(directory: root.appendingPathComponent("late").appendingPathComponent("Sessions"))
        try? lateStore.apply(ClaudeHookEvent(name: "PermissionRequest", sessionID: "old", cwd: "/tmp/example/old",
                                             notificationType: nil, toolName: nil), at: clock, host: nil)
        let lateDelivery = RecordingDelivery()
        let late = ClaudeSessionModel(usage: usage, store: lateStore, defaults: defaults, status: { .on }, activate: { _ in true },
                                      delivery: lateDelivery, now: { clock }, io: { pending.append($0) }, main: { $0() }, watch: false)
        late.setHosting(ClaudeSessionHosting(live: [UUID()], closed: [], waits: []))
        check(late.notify && late.items.isEmpty, "A hosting change before the first read shows nothing yet")
        let queued = pending
        pending = []
        queued.forEach { $0() }
        check(late.items.map(\.record.project) == ["old"] && lateDelivery.sent.isEmpty && late.waitCount == 0,
              "A session already waiting stays a silent baseline even when hosting changed first")

        print("\(checks) claude-session model checks passed")
    }
}
