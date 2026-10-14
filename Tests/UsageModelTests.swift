import Foundation
import Combine

// Drive the real observable model with delayed completions, without using
// provider accounts, persistent preferences, or timing-dependent sleeps.
@main
struct UsageModelTests {
    static func main() {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            guard condition() else { fatalError("FAIL: \(label)") }
            checks += 1
        }
        func snapshot(_ used: Double) -> UsageSnapshot {
            UsageSnapshot(windows: [.init(label: "5-hour", used: used, reset: nil)],
                          updated: Date(timeIntervalSince1970: 1000))
        }
        var requests: [UsageModel.Completion] = []
        var claudeReads = 0
        let model = UsageModel(fetchCodex: { requests.append($0) }, loadClaude: { done in
            claudeReads += 1
            done(snapshot(12))
        })
        model.refresh()
        model.refresh()
        check(requests.count == 1 && model.refreshing, "Repeated refresh is single-flight")
        model.toggleDemo()
        check(model.demo && !model.refreshing, "Demo stops live loading indicator")
        let readsBeforeDemo = claudeReads
        model.readClaude()
        model.refresh()
        check(claudeReads == readsBeforeDemo && requests.count == 1, "Demo never reads live providers")
        requests[0](.success(snapshot(99)))
        check(model.codex?.windows.first?.used == 21 && model.claude?.windows.first?.used == 38,
              "Late live success cannot replace demo data")
        check(model.codexMessage.isEmpty && !model.refreshing, "Demo stays error-free after completion")

        model.toggleDemo()
        check(!model.demo && model.codex == nil && model.refreshing && requests.count == 2,
              "Leaving demo clears sample data and fetches live data")
        requests[1](.success(snapshot(44)))
        check(model.codex?.windows.first?.used == 44 && !model.refreshing, "Current result is accepted")
        model.refresh()
        requests[2](.failure(CodexReader.Failure.timeout))
        check(model.codex?.windows.first?.used == 44 && !model.codexMessage.isEmpty,
              "Current failure preserves last successful live reading")
        model.refresh()
        model.toggleDemo()
        requests[3](.failure(CodexReader.Failure.server))
        check(model.codexMessage.isEmpty && model.codex?.windows.first?.used == 21,
              "Late live failure cannot contaminate demo")

        model.toggleDemo()
        let previous = requests[4]
        for _ in 0..<10 { model.toggleDemo(); model.toggleDemo() }
        check(requests.count == 5 && model.refreshing, "Rapid mode switches do not spawn more requests")
        previous(.success(snapshot(98)))
        check(requests.count == 6 && model.codex == nil && model.refreshing,
              "Stale completion starts exactly one replacement without publishing")
        previous(.failure(CodexReader.Failure.timeout))
        check(requests.count == 6 && model.refreshing && model.codexMessage == "Connecting to Codex…",
              "Duplicate old completion cannot stop newer request")
        requests[5](.success(snapshot(17)))
        check(model.codex?.windows.first?.used == 17 && !model.refreshing, "Latest live generation wins")

        model.refresh()
        model.codexConnectionChanged()
        model.codexConnectionChanged()
        check(model.codex == nil && requests.count == 7, "Connection change clears old quota without overlapping work")
        requests[6](.failure(CodexReader.Failure.server))
        check(requests.count == 8 && model.codexMessage == "Connecting to Codex…",
              "Old connection failure is discarded and latest connection is refreshed")
        requests[7](.success(snapshot(23)))
        check(model.codex?.windows.first?.used == 23 && model.codexMessage.isEmpty,
              "New connection result is accepted")
        model.refresh()
        requests[7](.success(snapshot(88)))
        check(model.refreshing && model.codex?.windows.first?.used == 23,
              "Completed request cannot overwrite a later request in the same generation")
        requests[8](.success(UsageSnapshot(windows: [], updated: Date())))
        check(model.codex?.windows.isEmpty == true && !model.codexMessage.isEmpty,
              "Missing quotas remain missing, not zero")
        let readTimestamp = model.claude?.updated
        model.readClaude()
        check(model.claude?.updated == readTimestamp, "Rereading Claude preserves the captured timestamp")

        var previewReads = 0
        let preview = UsageModel(demo: true, fetchCodex: { _ in previewReads += 1 },
                                 loadClaude: { done in previewReads += 1; done(nil) })
        preview.refresh()
        preview.codexConnectionChanged()
        check(previewReads == 0 && preview.codex?.windows.first?.used == 21,
              "Appearance preview never connects to live sources")

        // The Appearance Preview keeps its menus, but nothing chosen there may
        // go live or reach the app's saved state.
        let sampleSuite = "nocci-sample-only-tests-" + UUID().uuidString
        let sampleDefaults = UserDefaults(suiteName: sampleSuite)!
        var sampleReads = 0
        let sampleOnly = UsageModel(demo: true, sampleOnly: true, fetchCodex: { _ in sampleReads += 1 },
                                    loadClaude: { sampleReads += 1; $0(nil) }, defaults: sampleDefaults)
        sampleOnly.toggleDemo()
        check(sampleOnly.demo && sampleReads == 0, "The preview never leaves sample data")
        sampleOnly.presentation = .untilEnded
        check(sampleDefaults.object(forKey: "presentationUntil") == nil,
              "Presentation Mode chosen in the preview is never saved for the app")
        UserDefaults().removePersistentDomain(forName: sampleSuite)

        // Sample data draws pace and the wings from the same preferences, so
        // the panel must be measured again in demo mode too.
        let demoLayoutSuite = "nocci-demo-layout-tests-" + UUID().uuidString
        let demoLayout = UsageModel(demo: true, fetchCodex: { _ in }, loadClaude: { $0(nil) },
                                    defaults: UserDefaults(suiteName: demoLayoutSuite)!)
        var demoLayouts = 0
        demoLayout.onLayout = { demoLayouts += 1 }
        demoLayout.preferences.showPace = true
        check(demoLayouts == 1 && demoLayout.claudePace != nil,
              "Turning pace on with sample data remeasures the panel and shows the sample line")
        demoLayout.preferences.showCodex = false
        check(demoLayouts == 2, "Hiding a provider with sample data remeasures the panel")
        UserDefaults().removePersistentDomain(forName: demoLayoutSuite)

        // A reader error that is not one of Codex's own categories is never
        // shown verbatim: it could carry a path or a system message.
        var rawRequests: [UsageModel.Completion] = []
        let rawSuite = "nocci-raw-error-tests-" + UUID().uuidString
        let rawErrors = UsageModel(fetchCodex: { rawRequests.append($0) }, loadClaude: { $0(nil) },
                                   inspectClaude: { _ in .notConfigured },
                                   defaults: UserDefaults(suiteName: rawSuite)!)
        rawErrors.refresh()
        rawRequests[0](.failure(NSError(domain: NSPOSIXErrorDomain, code: Int(EPIPE),
                                        userInfo: [NSLocalizedDescriptionKey: "Broken pipe at /Users/someone"])))
        check(rawErrors.codexMessage == CodexReader.Failure.disconnected.errorDescription,
              "An unexpected reader error reads as disconnected")
        UserDefaults().removePersistentDomain(forName: rawSuite)

        // A Codex installed with npm is a script run by `node`, which a Finder
        // launch's PATH does not reach; its own folder holds `node` too.
        let codexFolder = FileManager.default.temporaryDirectory.appendingPathComponent("nocci-codex-\(UUID().uuidString)")
        let linkFolder = codexFolder.appendingPathComponent("bin")
        let packageFolder = codexFolder.appendingPathComponent("lib/codex/bin")
        try? FileManager.default.createDirectory(at: linkFolder, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: packageFolder, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: packageFolder.appendingPathComponent("codex.js").path, contents: Data())
        try? FileManager.default.createSymbolicLink(atPath: linkFolder.appendingPathComponent("codex").path,
                                                    withDestinationPath: packageFolder.appendingPathComponent("codex.js").path)
        let childEnvironment = CodexReader.environment(for: linkFolder.appendingPathComponent("codex").path,
                                                       base: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": "/Users/x"])
        let searched = childEnvironment["PATH"]?.split(separator: ":").map(String.init) ?? []
        check(searched.first == linkFolder.resolvingSymlinksInPath().path || searched.first == linkFolder.path,
              "The Codex executable's own folder is searched first")
        check(searched.contains(packageFolder.resolvingSymlinksInPath().path),
              "The folder the executable's link points into is searched too")
        check(searched.contains("/opt/homebrew/bin") && searched.contains("/usr/local/bin") && searched.contains("/usr/bin"),
              "Homebrew's folders are added and the inherited PATH is kept")
        check(Set(searched).count == searched.count, "No folder is searched twice")
        check(childEnvironment["HOME"] == "/Users/x", "The rest of the environment is passed through")
        check(CodexReader.environment(for: "/usr/local/bin/codex", base: [:])["PATH"]?.hasPrefix("/usr/local/bin") == true,
              "A launch without any PATH still gets one")
        try? FileManager.default.removeItem(at: codexFolder)

        // A plan whose only window is weekly reports it as `primary`; its
        // duration, not its position, says which window it is.
        let weeklyPrimary = UsageParser.codex(["rateLimits": ["primary": ["usedPercent": 12.0, "windowDurationMins": 10080]]])
        check(weeklyPrimary.windows.first?.kind == .weekly && weeklyPrimary.windows.first?.label == "Weekly",
              "A weekly primary window is the weekly window")
        let usual = UsageParser.codex(["rateLimits": ["primary": ["usedPercent": 1.0, "windowDurationMins": 300],
                                                      "secondary": ["usedPercent": 2.0, "windowDurationMins": 10080]]])
        check(usual.windows.map(\.kind) == [.session, .weekly], "The usual pair keeps session then weekly")

        var preferenceReads = 0
        func savedPath() -> String? { preferenceReads += 1; return "/bin/sh" }
        check(CodexReader.executable(environment: ["NOCCI_CODEX_PATH": "/bin/echo"], savedPath: savedPath()) == "/bin/echo",
              "Explicit executable override wins")
        check(preferenceReads == 0, "Explicit override never reads saved preferences")
        check(CodexReader.executable(environment: ["NOCCI_CODEX_PATH": "/nonexistent/notch-fixture"], savedPath: savedPath()) == nil,
              "Invalid explicit override fails closed")
        check(preferenceReads == 0, "Invalid override never falls back to preferences")
        check(CodexReader.executable(environment: [:], savedPath: savedPath()) == "/bin/sh" && preferenceReads == 1,
              "Normal launch still honors saved executable")
        // An app bundle is a searchable folder, so a plain executable check accepts it.
        let bundle = FileManager.default.temporaryDirectory.appendingPathComponent("nocci-tests-\(UUID().uuidString).app")
        try? FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        check(CodexReader.executable(environment: ["NOCCI_CODEX_PATH": bundle.path]) == nil,
              "An app bundle is not a runnable Codex executable")
        check(CodexReader.executable(environment: [:], savedPath: bundle.path) != bundle.path,
              "A saved app bundle is never used as the Codex executable")
        check(FileManager.default.isRunnableFile(atPath: "/bin/sh") && !FileManager.default.isRunnableFile(atPath: bundle.path)
              && !FileManager.default.isRunnableFile(atPath: "/nonexistent/notch-fixture")
              && !FileManager.default.isRunnableFile(atPath: "/etc/hosts"),
              "Only an executable regular file is runnable")
        try? FileManager.default.removeItem(at: bundle)
        // MARK: An event without rate limits must not discard the last reading
        //
        // Claude Code sends a status-line event at session start, before its
        // first API response, and that event carries no rate_limits.

        let captured = Date(timeIntervalSince1970: 1_000_000)
        let eventTime = Date(timeIntervalSince1970: 1_000_600)
        let known = UsageSnapshot(windows: [.init(label: "5-hour", used: 7, reset: nil),
                                            .init(label: "Weekly", used: 4, reset: nil)],
                                  updated: captured)
        let empty = UsageSnapshot(windows: [], updated: eventTime)
        let kept = Storage.merge(incoming: empty, existing: known, now: eventTime)
        check(kept.windows.count == 2 && kept.windows[0].used == 7,
              "An event without rate limits keeps the last known windows")
        check(kept.updated == captured, "Keeping windows keeps the time they were actually read")
        check(kept.lastEvent == eventTime, "The event is still recorded as proof the bridge ran")

        let fresh = UsageSnapshot(windows: [.init(label: "5-hour", used: 11, reset: nil)], updated: eventTime)
        let replaced = Storage.merge(incoming: fresh, existing: known, now: eventTime)
        check(replaced.windows.count == 1 && replaced.windows[0].used == 11, "Real usage replaces the previous reading")
        check(replaced.updated == eventTime && replaced.lastEvent == eventTime, "A real reading updates both times")

        let first = Storage.merge(incoming: empty, existing: nil, now: eventTime)
        check(first.windows.isEmpty && first.lastEvent == eventTime,
              "A first event without rate limits records the event and no windows")
        let stillEmpty = Storage.merge(incoming: empty, existing: UsageSnapshot(windows: [], updated: captured), now: eventTime)
        check(stillEmpty.windows.isEmpty && stillEmpty.lastEvent == eventTime,
              "Repeated empty events keep advancing the event time")

        var inspected = 0
        let aging = UsageModel(fetchCodex: { _ in }, loadClaude: { $0(known) }, inspectClaude: { _ in
            inspected += 1
            return inspected == 1 ? .receiving : .stale
        })
        aging.tick = captured
        aging.readClaude()
        check(aging.claudeConnection == .receiving, "Initial observation publishes connection")
        aging.tick = captured.addingTimeInterval(299)
        aging.readClaude()
        check(inspected == 1, "Unchanged recent snapshot does not reread settings")
        aging.tick = captured.addingTimeInterval(300)
        aging.readClaude()
        check(inspected == 2 && aging.claudeConnection == .stale, "Clock crossing freshness limit updates connection without a new event")
        aging.readClaude()
        check(inspected == 2, "Already-stale snapshots do not repeat configuration checks")
        // MARK: Window identity and percentage rounding
        //
        // Selection cannot be index-based: a Claude account reporting only
        // seven_day yields a single-element array whose index 0 is weekly.
        // It cannot be label-based either: Codex derives labels from
        // windowDurationMins.
        var displayChecks = 0
        func display(_ condition: @autoclosure () -> Bool, _ label: String) {
            guard condition() else { fatalError("FAIL: \(label)") }
            displayChecks += 1
        }

        let bothClaude = UsageParser.claude(["rate_limits": [
            "five_hour": ["used_percentage": 38.0],
            "seven_day": ["used_percentage": 62.0]]])
        display(bothClaude.windows.first?.kind == .session, "Claude five_hour is the session window")
        display(bothClaude.windows.last?.kind == .weekly, "Claude seven_day is the weekly window")

        let bothCodex = UsageParser.codex(["rateLimitsByLimitId": ["codex": [
            "primary": ["usedPercent": 21.0],
            "secondary": ["usedPercent": 45.0]]]])
        display(bothCodex.windows.first?.kind == .session, "Codex primary is the session window")
        display(bothCodex.windows.last?.kind == .weekly, "Codex secondary is the weekly window")

        let weeklyOnly = UsageParser.claude(["rate_limits": ["seven_day": ["used_percentage": 62.0]]])
        display(weeklyOnly.windows.count == 1 && weeklyOnly.windows[0].resolvedKind == .weekly,
                "A weekly-only account does not present its weekly window as a session window")

        let storedWeekly = try! JSONDecoder().decode(UsageWindow.self,
                                                     from: Data(#"{"label":"Weekly","used":62}"#.utf8))
        display(storedWeekly.kind == nil && storedWeekly.resolvedKind == .weekly,
                "A window stored before kind existed resolves by label")
        let storedSession = try! JSONDecoder().decode(UsageWindow.self,
                                                      from: Data(#"{"label":"5-hour","used":38}"#.utf8))
        display(storedSession.resolvedKind == .session, "A stored non-weekly window resolves as session")

        display(UsageWindow(label: "x", used: 38.5, reset: nil).remaining == 61,
                "Remaining is the complement of the rounded used value, so the modes sum to 100")
        display(UsageWindow(label: "x", used: 120, reset: nil).remaining == 0, "Remaining clamps at zero")
        display(UsageWindow(label: "x", used: -5, reset: nil).remaining == 100, "Remaining clamps at one hundred")


        // MARK: How much of a window has gone
        display(bothClaude.windows.map(\.duration) == [18000, 604800], "Claude's windows are five hours and seven days long")
        let timedCodex = UsageParser.codex(["rateLimits": ["primary": ["usedPercent": 1.0, "windowDurationMins": 300],
                                                           "secondary": ["usedPercent": 2.0, "windowDurationMins": 10080]]])
        display(timedCodex.windows.map(\.duration) == [18000, 604800], "Codex's durations come from windowDurationMins")
        display(bothCodex.windows.allSatisfy { $0.duration == nil }, "A Codex window without a duration has none, not a guess")
        display(UsageParser.codex(["rateLimits": ["primary": ["usedPercent": 1.0, "windowDurationMins": 0]]]).windows[0].duration == nil,
                "A zero duration is no duration")
        let storedWithout = try! JSONDecoder().decode(UsageWindow.self,
                                                      from: Data(#"{"label":"5-hour","used":38,"kind":"session"}"#.utf8))
        display(storedWithout.duration == nil, "A window stored before durations existed still decodes")
        let roundTrip = try! JSONDecoder().decode(UsageWindow.self, from: JSONEncoder().encode(timedCodex.windows[1]))
        display(roundTrip == timedCodex.windows[1], "A duration is stored with its window")
        let gone = Date(timeIntervalSince1970: 100_000)
        func window(resetIn seconds: TimeInterval?, duration: TimeInterval?) -> UsageWindow {
            UsageWindow(label: "5-hour", used: 10, reset: seconds.map { gone.addingTimeInterval($0) }, kind: .session, duration: duration)
        }
        display(window(resetIn: 18000, duration: 18000).elapsed(at: gone) == 0, "A window that just began has nothing gone")
        display(window(resetIn: 4500, duration: 18000).elapsed(at: gone) == 0.75, "Three quarters gone with an hour and a quarter left of five")
        display(window(resetIn: 30000, duration: 18000).elapsed(at: gone) == 0, "A reset further off than the duration clamps to nothing gone")
        display(window(resetIn: 0, duration: 18000).elapsed(at: gone) == nil
                && window(resetIn: -10, duration: 18000).elapsed(at: gone) == nil, "An expired window has no mark")
        display(window(resetIn: nil, duration: 18000).elapsed(at: gone) == nil
                && window(resetIn: 60, duration: nil).elapsed(at: gone) == nil
                && window(resetIn: 60, duration: 0).elapsed(at: gone) == nil, "Without a reset or a duration there is no mark")

        // MARK: Expiry is evaluated at a given time, not the wall clock
        //
        // While this read `Date()` directly, any fixture dated in the past was
        // silently expired and filtered out before reaching the alert engine,
        // the pace estimator or the model. It cost three wrong tests to notice.
        let expiryMoment = Date(timeIntervalSince1970: 1_500)
        let lapsed = UsageWindow(label: "x", used: 20, reset: Date(timeIntervalSince1970: 1_000), kind: .session)
        let ahead = UsageWindow(label: "x", used: 20, reset: Date(timeIntervalSince1970: 2_000), kind: .session)
        let endless = UsageWindow(label: "x", used: 20, reset: nil, kind: .session)

        display(lapsed.expired(at: expiryMoment), "A reset already passed is expired")
        display(!ahead.expired(at: expiryMoment), "A reset still ahead is not expired")
        display(ahead.expired(at: Date(timeIntervalSince1970: 2_000)), "A window expires exactly at its reset")
        display(!endless.expired(at: expiryMoment), "A window without a reset never expires")
        display(!lapsed.expired(at: Date(timeIntervalSince1970: 500)),
                "Expiry answers for the time it is asked about, not for now")

        // MARK: Compact window selection
        //
        // An explicitly selected window that the provider did not report must
        // return nothing. Substituting the other quota would misreport usage.
        let sessionWindow = UsageWindow(label: "5-hour", used: 38, reset: nil, kind: .session)
        let weeklyWindow = UsageWindow(label: "Weekly", used: 62, reset: nil, kind: .weekly)
        let both = [sessionWindow, weeklyWindow]

        let preferences = DisplayPreferences()
        display(preferences.claudeWindow == .automatic && preferences.codexWindow == .automatic,
                "Automatic is each provider's default compact window")
        display(preferences.showClaude && preferences.showCodex, "Both providers are shown by default")
        display(preferences.percentages == .used, "Used is the default percentage mode")

        let session = CompactWindowChoice.session, weekly = CompactWindowChoice.weekly
        let automatic = CompactWindowChoice.automatic
        display(session.window(in: both)?.kind == .session, "Session selects the session window")
        display(session.window(in: [weeklyWindow]) == nil, "Session never substitutes the weekly window")
        display(session.window(in: []) == nil, "Session finds nothing in an empty reading")

        display(weekly.window(in: both)?.kind == .weekly, "Weekly selects the weekly window")
        display(weekly.window(in: [sessionWindow]) == nil, "Weekly never substitutes the session window")
        display(weekly.window(in: []) == nil, "Weekly finds nothing in an empty reading")

        display(automatic.window(in: both)?.kind == .session, "Automatic prefers the session window")
        display(automatic.window(in: [weeklyWindow])?.kind == .weekly, "Automatic falls back to the weekly window")
        display(automatic.window(in: [sessionWindow])?.kind == .session, "Automatic uses a lone session window")
        display(automatic.window(in: []) == nil, "Automatic finds nothing in an empty reading")

        // Automatic must reproduce today's `windows.first` behaviour exactly,
        // including a stored snapshot that predates `kind`.
        let storedOnlyWeekly = [UsageWindow(label: "Weekly", used: 62, reset: nil)]
        display(automatic.window(in: storedOnlyWeekly)?.label == "Weekly",
                "Automatic resolves a stored weekly-only snapshot without a kind")

        // MARK: Percentage mode
        //
        // Canonical data stays "used". Remaining is derived at render time and
        // the two modes must always sum to 100 for the same window.
        var used = DisplayPreferences()
        used.percentages = .used
        var left = DisplayPreferences()
        left.percentages = .remaining

        let fractional = UsageWindow(label: "5-hour", used: 38.5, reset: nil, kind: .session)
        display(used.percent(fractional) == 39, "Used rounds to the nearest whole percent")
        display(left.percent(fractional) == 61, "Remaining is the complement of the displayed used value")
        display(used.percent(fractional) + left.percent(fractional) == 100, "The two modes always sum to 100")

        let zeroWindow = UsageWindow(label: "5-hour", used: 0, reset: nil, kind: .session)
        display(used.percent(zeroWindow) == 0 && left.percent(zeroWindow) == 100, "A real zero shows 0 used and 100 remaining")
        let exhausted = UsageWindow(label: "5-hour", used: 100, reset: nil, kind: .session)
        display(used.percent(exhausted) == 100 && left.percent(exhausted) == 0, "A full window shows 100 used and 0 remaining")

        let over = UsageWindow(label: "5-hour", used: 120, reset: nil, kind: .session)
        display(used.percent(over) == 100 && left.percent(over) == 0, "Out-of-range usage clamps high")
        let under = UsageWindow(label: "5-hour", used: -5, reset: nil, kind: .session)
        display(used.percent(under) == 0 && left.percent(under) == 100, "Out-of-range usage clamps low")

        display(used.caption == "Percent of allowance used", "Used mode names the used share")
        display(left.caption == "Percent of allowance remaining", "Remaining mode names the remaining share")

        // MARK: Persistence
        //
        // An isolated suite, removed afterwards. These checks must never touch
        // UserDefaults.standard or the user's real preferences.
        let suiteName = "nocci-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!

        display(DisplayPreferences.load(from: defaults) == DisplayPreferences(),
                "Absent keys mean defaults, not false")

        var stored = DisplayPreferences()
        stored.showCodex = false
        stored.percentages = .remaining
        stored.claudeWindow = .weekly
        stored.codexWindow = .session
        stored.save(to: defaults)
        display(DisplayPreferences.load(from: defaults) == stored, "Saved preferences round trip")
        let reloaded = DisplayPreferences.load(from: defaults)
        display(reloaded.claudeWindow == .weekly && reloaded.codexWindow == .session,
                "Each provider keeps its own compact window")
        display(DisplayPreferences.load(from: defaults).showCodex == false,
                "A hidden provider is not read back as visible")

        var hideEverything = DisplayPreferences()
        hideEverything.showClaude = false
        hideEverything.showCodex = false
        hideEverything.save(to: defaults)
        let clamped = DisplayPreferences.load(from: defaults)
        display(clamped.showClaude && clamped.showCodex,
                "Storage with every provider hidden clamps back to both visible")

        defaults.set("nonsense", forKey: "percentageMode")
        defaults.set("nonsense", forKey: "claudeCompactWindow")
        defaults.set("nonsense", forKey: "codexCompactWindow")
        let unreadable = DisplayPreferences.load(from: defaults)
        display(unreadable.percentages == .used && unreadable.claudeWindow == .automatic
                    && unreadable.codexWindow == .automatic,
                "Unrecognised stored values fall back to the defaults")

        UserDefaults().removePersistentDomain(forName: suiteName)

        // MARK: Visibility gates provider reads
        //
        // Hiding a provider must stop its reads without breaking the
        // single-flight and generation guarantees above.
        let gateSuite = "nocci-tests-" + UUID().uuidString
        let gateDefaults = UserDefaults(suiteName: gateSuite)!
        var gateRequests: [UsageModel.Completion] = []
        var gateClaudeReads = 0
        var gateInspections = 0
        let gated = UsageModel(fetchCodex: { gateRequests.append($0) },
                               loadClaude: { done in gateClaudeReads += 1; done(snapshot(12)) },
                               inspectClaude: { _ in gateInspections += 1; return .receiving },
                               defaults: gateDefaults)
        gated.refresh()
        display(gateRequests.count == 1 && gateClaudeReads == 1, "Both providers visible reads both")

        gated.preferences.showCodex = false
        display(gateRequests.count == 1, "Hiding Codex starts no new request")
        gateRequests[0](.success(snapshot(77)))
        display(gated.codex == nil && gateRequests.count == 1,
                "A request in flight when Codex is hidden drains without publishing or replacing itself")
        gated.refresh()
        display(gateRequests.count == 1, "A refresh while Codex is hidden never reaches the reader")
        display(gated.codexMessage.isEmpty, "Hiding Codex clears its connection message")

        gated.preferences.showCodex = true
        display(gateRequests.count == 2, "Re-enabling Codex issues exactly one request")
        gateRequests[1](.success(snapshot(55)))
        display(gated.codex?.windows.first?.used == 55, "The re-enabled provider publishes its reading")

        let claudeReadsBeforeHiding = gateClaudeReads
        let inspectionsBeforeHiding = gateInspections
        gated.preferences.showClaude = false
        gated.refresh()
        gated.readClaude()
        gated.refreshClaudeConnection()
        display(gateClaudeReads == claudeReadsBeforeHiding,
                "Hiding Claude stops its snapshot reads")
        display(gateInspections == inspectionsBeforeHiding,
                "Hiding Claude stops inspecting its configuration, so setup is never touched")
        display(gated.claude != nil, "Hiding a provider retains its last reading in memory")
        display(DisplayPreferences.load(from: gateDefaults).showClaude == false,
                "Changing a preference persists it immediately")

        gated.preferences.showClaude = true
        display(gateClaudeReads == claudeReadsBeforeHiding + 1, "Re-enabling Claude reads its snapshot once")

        var demoReads = 0
        let demoGated = UsageModel(demo: true,
                                   fetchCodex: { _ in demoReads += 1 },
                                   loadClaude: { done in demoReads += 1; done(nil) },
                                   defaults: gateDefaults)
        demoGated.preferences.showCodex = false
        demoGated.preferences.showCodex = true
        demoGated.preferences.showClaude = false
        display(demoReads == 0, "Preference changes in demo mode never touch live providers")

        // Sample data is built directly rather than through UsageParser, so it
        // must set kinds itself instead of relying on the label fallback.
        let demoData = UsageModel(demo: true, fetchCodex: { _ in }, loadClaude: { $0(nil) }, defaults: gateDefaults)
        demoData.refresh()
        display(demoData.claude?.windows.first?.kind == .session && demoData.claude?.windows.last?.kind == .weekly,
                "Sample Claude data carries explicit window kinds")
        display(demoData.codex?.windows.first?.kind == .session && demoData.codex?.windows.last?.kind == .weekly,
                "Sample Codex data carries explicit window kinds")

        UserDefaults().removePersistentDomain(forName: gateSuite)

        // MARK: Compact reading
        //
        // The strip's value, staleness and explanation are pure functions of
        // the snapshot and the preferences, so they are tested here rather
        // than by inspecting the view.
        let readAt = Date(timeIntervalSince1970: 2_000_000)
        let liveSnapshot = UsageSnapshot(windows: [sessionWindow, weeklyWindow], updated: readAt)

        let showUsed = DisplayPreferences()
        let usedReading = showUsed.reading(provider: "Claude", choice: .automatic, kind: nil, snapshot: liveSnapshot, now: readAt)
        display(usedReading.value == "38%", "Used mode shows the used share in the strip")
        display(!usedReading.stale, "A fresh reading is not stale")
        display(usedReading.label == "Claude 5-hour usage", "The accessibility label names the provider and window")
        display(usedReading.explanation.contains("38% of subscription allowance used"),
                "Used mode names the used share in the explanation")

        var showLeft = DisplayPreferences()
        showLeft.percentages = .remaining
        let leftReading = showLeft.reading(provider: "Claude", choice: .automatic, kind: nil, snapshot: liveSnapshot, now: readAt)
        display(leftReading.value == "62%", "Remaining mode shows the remaining share in the strip")
        display(leftReading.explanation.contains("62% of subscription allowance remaining"),
                "Remaining mode names the remaining share in the explanation")

        let staleReading = showUsed.reading(provider: "Claude", choice: .automatic, kind: nil, snapshot: liveSnapshot,
                                            now: readAt.addingTimeInterval(300))
        display(staleReading.value == "38%", "Age alone never hides a percentage")
        display(staleReading.stale, "A reading five minutes old is stale")
        display(staleReading.explanation.contains("last reading 38% used"),
                "The stale explanation reports the original value")

        let expiredSnapshot = UsageSnapshot(windows: [UsageWindow(label: "5-hour", used: 38,
                                                                  reset: Date(timeIntervalSince1970: 1), kind: .session)],
                                            updated: readAt)
        let expiredReading = showUsed.reading(provider: "Claude", choice: .automatic, kind: nil, snapshot: expiredSnapshot, now: readAt)
        display(expiredReading.value == "—", "An expired window shows a dash")
        display(expiredReading.explanation.contains("previous window expired"),
                "The expired explanation says the window ended")

        let absentReading = showUsed.reading(provider: "Claude", choice: .automatic, kind: nil, snapshot: nil, now: readAt)
        display(absentReading.value == "—" && absentReading.stale, "No snapshot shows a dash")
        display(absentReading.label == "Claude usage", "With no window the label names only the provider")

        let sessionOnly = UsageSnapshot(windows: [sessionWindow], updated: readAt)
        let unmet = showUsed.reading(provider: "Claude", choice: .weekly, kind: nil, snapshot: sessionOnly, now: readAt)
        display(unmet.value == "—", "A selected window the provider did not report shows a dash")
        display(unmet.explanation.contains("no weekly window"),
                "The explanation names the window that is missing")
        display(unmet.explanation.contains("Automatic"),
                "The explanation points at the setting that would fill the gap")

        let splitSlot = showUsed.reading(provider: "Claude", choice: .automatic, kind: .weekly, snapshot: sessionOnly, now: readAt)
        display(splitSlot.value == "—", "An empty split slot shows a dash")
        display(splitSlot.explanation.contains("no weekly window") && !splitSlot.explanation.contains("Automatic"),
                "A split slot does not suggest a setting that would not change it")
        let splitFilled = showUsed.reading(provider: "Claude", choice: .automatic, kind: .weekly, snapshot: liveSnapshot, now: readAt)
        display(splitFilled.value == "62%", "A split slot renders its own window, ignoring the window preference")
        let claudeWeekly = showUsed.reading(provider: "Claude", choice: .weekly, kind: nil, snapshot: liveSnapshot, now: readAt)
        let codexSession = showUsed.reading(provider: "Codex", choice: .session, kind: nil, snapshot: liveSnapshot, now: readAt)
        display(claudeWeekly.value == "62%" && claudeWeekly.label == "Claude Weekly usage"
                    && codexSession.value == "38%" && codexSession.label == "Codex 5-hour usage",
                "Each slot reads the window its own provider's choice names")

        // MARK: Alert delivery
        var alertChecks = 0
        func alert(_ condition: @autoclosure () -> Bool, _ label: String) {
            guard condition() else { fatalError("FAIL: \(label)") }
            alertChecks += 1
        }
        //
        // The model decides which readings are eligible. Demo, hidden, stale
        // and disabled providers must never reach the engine at all.
        //
        // Windows use `reset: nil` to keep these checks about delivery rather
        // than about window identity, which the engine's own suite covers.
        final class FakeDelivery: AlertDelivery {
            var sent: [(AlertMessage, Bool)] = []
            func send(_ message: AlertMessage, sound: Bool) { sent.append((message, sound)) }
        }

        let alertSuite = "nocci-alert-tests-" + UUID().uuidString
        let alertDefaults = UserDefaults(suiteName: alertSuite)!
        let delivery = FakeDelivery()
        let observed = Date(timeIntervalSince1970: 3_000_000)
        var claudeReading = UsageSnapshot(
            windows: [UsageWindow(label: "5-hour", used: 10, reset: nil, kind: .session)],
            updated: observed)
        let alerting = UsageModel(fetchCodex: { _ in },
                                  loadClaude: { $0(claudeReading) },
                                  inspectClaude: { _ in .receiving },
                                  defaults: alertDefaults,
                                  delivery: delivery)
        alerting.tick = observed

        alerting.readClaude()
        alert(delivery.sent.isEmpty, "Alerts stay silent while they are switched off")

        alerting.alertPreferences.claude = true
        alert(delivery.sent.isEmpty, "Enabling alerts baselines instead of notifying")

        claudeReading.windows[0].used = 85
        alerting.readClaude()
        alert(delivery.sent.count == 1, "Crossing a threshold delivers one notification")
        alert(delivery.sent[0].0.body == "5-hour allowance: 80% used",
                "The delivered message names the window and the used share")
        alert(delivery.sent[0].1 == false, "Sound is off by default")

        alerting.readClaude()
        alert(delivery.sent.count == 1, "Re-reading the same snapshot does not repeat the alert")

        claudeReading.windows[0].used = 95
        alerting.tick = observed.addingTimeInterval(300)
        alerting.readClaude()
        alert(delivery.sent.count == 1, "A reading five minutes old never alerts")

        claudeReading.updated = observed.addingTimeInterval(300)
        alerting.readClaude()
        alert(delivery.sent.count == 2 && delivery.sent[1].0.body.contains("90% used"),
                "A fresh reading alerts again at the next threshold")

        alerting.preferences.showClaude = false
        claudeReading.windows[0].used = 100
        claudeReading.updated = alerting.tick
        alerting.readClaude()
        alert(delivery.sent.count == 2, "A hidden provider never alerts")

        alerting.alertPreferences.sound = true
        alert(delivery.sent.count == 2, "Changing the sound preference alone delivers nothing")
        alerting.preferences.showClaude = true
        alert(delivery.sent.count == 3 && delivery.sent[2].1 == true,
                "Showing the provider again alerts, and the sound preference reaches delivery")

        alert(AlertState.load(from: alertDefaults).windows["claude.session"]?.handled == [80, 90, 100],
                "Delivered thresholds are persisted so a relaunch cannot repeat them")

        let pastDelivery = FakeDelivery()
        var pastWindow = UsageSnapshot(
            windows: [UsageWindow(label: "Weekly", used: 95,
                                  reset: Date(timeIntervalSince1970: 1), kind: .weekly)],
            updated: Date())
        let pastModel = UsageModel(fetchCodex: { _ in }, loadClaude: { $0(pastWindow) },
                                      inspectClaude: { _ in .receiving },
                                      defaults: alertDefaults, delivery: pastDelivery)
        pastModel.tick = pastWindow.updated
        pastModel.alertPreferences.claude = true
        pastModel.readClaude()
        alert(pastDelivery.sent.isEmpty, "An expired window never alerts")
        alert(AlertState.load(from: alertDefaults).windows["claude.weekly"] == nil,
                "An expired window does not even record a baseline")

        alerting.alertPreferences.claude = false
        alert(AlertState.load(from: alertDefaults).windows.isEmpty,
                "Turning alerts off forgets the provider's windows")

        let demoAlerts = FakeDelivery()
        pastWindow.windows[0].used = 99
        let demoModel = UsageModel(demo: true, fetchCodex: { _ in }, loadClaude: { $0(pastWindow) },
                                   defaults: alertDefaults, delivery: demoAlerts)
        demoModel.alertPreferences.claude = true
        demoModel.refresh()
        demoModel.readClaude()
        alert(demoAlerts.sent.isEmpty, "Sample data never raises an alert")

        // MARK: Editing custom thresholds establishes a provider-only baseline
        let customSuite = "nocci-custom-alert-tests-" + UUID().uuidString
        let customDefaults = UserDefaults(suiteName: customSuite)!
        var customPreferences = AlertPreferences()
        customPreferences.claude = true
        customPreferences.codex = true
        customPreferences.save(to: customDefaults)
        AlertState(windows: [
            "claude.session": AlertWindowState(reset: nil, handled: [80]),
            "codex.session": AlertWindowState(reset: nil, handled: [80])
        ]).save(to: customDefaults)
        let customDelivery = FakeDelivery()
        var customReading = UsageSnapshot(
            windows: [UsageWindow(label: "5-hour", used: 78, reset: nil, kind: .session)],
            updated: observed)
        let customModel = UsageModel(fetchCodex: { _ in }, loadClaude: { $0(customReading) },
                                     inspectClaude: { _ in .receiving },
                                     defaults: customDefaults, delivery: customDelivery)
        customModel.tick = observed
        var editedPreferences = customModel.alertPreferences
        editedPreferences.setThresholds([85, 70, 85], for: .claude)
        customModel.alertPreferences = editedPreferences
        alert(AlertState.load(from: customDefaults).windows.keys.sorted() == ["codex.session"],
              "Editing Claude thresholds forgets only Claude's previous window state")
        alert(AlertPreferences.load(from: customDefaults).claudeThresholds == [70, 85],
              "Edited thresholds are normalized and persisted immediately")

        customModel.readClaude()
        alert(customDelivery.sent.isEmpty
              && AlertState.load(from: customDefaults).windows["claude.session"]?.handled == [70],
              "The current reading becomes a silent baseline after editing thresholds")
        customReading.windows[0].used = 86
        customReading.updated = observed.addingTimeInterval(60)
        customModel.tick = customReading.updated
        customModel.readClaude()
        alert(customDelivery.sent.count == 1
              && customDelivery.sent[0].0.body == "5-hour allowance: 85% used",
              "A later reading alerts at the next custom threshold")
        alert(AlertState.load(from: customDefaults).windows["codex.session"]?.handled == [80],
              "Editing and crossing Claude thresholds preserves Codex alert state")

        // MARK: Reset alerts through the model
        //
        // Fixed dates: expiry is evaluated at the model's `tick`, so nothing
        // here depends on when the suite happens to run.
        let resetSuite = "nocci-reset-tests-" + UUID().uuidString
        let resetDefaults = UserDefaults(suiteName: resetSuite)!
        let resetDelivery = FakeDelivery()
        let resetBase = Date(timeIntervalSince1970: 11_000_000)
        let firstReset = resetBase.addingTimeInterval(3_600)
        var resetting = UsageSnapshot(
            windows: [UsageWindow(label: "5-hour", used: 20, reset: firstReset, kind: .session)],
            updated: resetBase)
        let resetModel = UsageModel(fetchCodex: { _ in }, loadClaude: { $0(resetting) },
                                    inspectClaude: { _ in .receiving },
                                    defaults: resetDefaults, delivery: resetDelivery)
        resetModel.tick = resetting.updated
        resetModel.alertPreferences.claude = true
        resetModel.alertPreferences.resets = true

        resetModel.readClaude()
        alert(resetDelivery.sent.isEmpty, "The first reading of a window is the silent baseline")

        resetting.windows[0].used = 92
        resetting.updated = resetBase.addingTimeInterval(60)
        resetModel.tick = resetting.updated
        resetModel.readClaude()
        alert(resetDelivery.sent.count == 1 && resetDelivery.sent[0].0.body.contains("90% used"),
              "The window is warned about before it resets")

        resetting.windows[0] = UsageWindow(label: "5-hour", used: 3,
                                           reset: firstReset.addingTimeInterval(18_000), kind: .session)
        resetting.updated = resetBase.addingTimeInterval(120)
        resetModel.tick = resetting.updated
        resetModel.readClaude()
        alert(resetDelivery.sent.count == 2 && resetDelivery.sent[1].0.body == "5-hour allowance has reset",
              "A confirmed successor window announces the reset through the model")

        resetModel.alertPreferences.resets = false
        resetting.windows[0] = UsageWindow(label: "5-hour", used: 95,
                                           reset: firstReset.addingTimeInterval(18_000), kind: .session)
        resetting.updated = resetBase.addingTimeInterval(180)
        resetModel.tick = resetting.updated
        resetModel.readClaude()
        resetting.windows[0] = UsageWindow(label: "5-hour", used: 4,
                                           reset: firstReset.addingTimeInterval(36_000), kind: .session)
        resetting.updated = resetBase.addingTimeInterval(240)
        resetModel.tick = resetting.updated
        resetModel.readClaude()
        alert(resetDelivery.sent.allSatisfy { !$0.0.body.contains("has reset") || $0.0.body.contains("5-hour allowance has reset") }
                && resetDelivery.sent.filter { $0.0.body == "5-hour allowance has reset" }.count == 1,
              "With reset alerts switched off no further reset is announced")

        // MARK: Presentation mode suppresses delivery without queuing a burst
        //
        // Advance baseline and handled state, discard
        // delivery. Ending presentation mode must not release a backlog.
        let quietSuite = "nocci-quiet-tests-" + UUID().uuidString
        let quietDefaults = UserDefaults(suiteName: quietSuite)!
        let quietDelivery = FakeDelivery()
        var quietReading = UsageSnapshot(
            windows: [UsageWindow(label: "5-hour", used: 10, reset: nil, kind: .session)],
            updated: Date(timeIntervalSince1970: 4_000_000))
        let quiet = UsageModel(fetchCodex: { _ in }, loadClaude: { $0(quietReading) },
                               inspectClaude: { _ in .receiving },
                               defaults: quietDefaults, delivery: quietDelivery)
        quiet.tick = quietReading.updated
        quiet.alertPreferences.claude = true
        quiet.readClaude()
        alert(quietDelivery.sent.isEmpty, "Baseline recorded before presentation mode")

        quiet.presentation = PresentationState(minutes: 60, from: quiet.tick)
        alert(quiet.presentation.isActive(at: quiet.tick), "Presentation mode is active")

        quietReading.windows[0].used = 95
        quiet.readClaude()
        alert(quietDelivery.sent.isEmpty, "No alert is delivered while presenting")
        alert(quiet.claude?.windows.first?.used == 95, "Provider readings continue while presenting")
        alert(AlertState.load(from: quietDefaults).windows["claude.session"]?.handled == [80, 90],
              "Thresholds crossed while presenting are marked handled, not queued")

        quiet.presentation = PresentationState()
        quiet.readClaude()
        alert(quietDelivery.sent.isEmpty, "Ending presentation mode releases no backlog")

        quietReading.windows[0].used = 100
        quiet.readClaude()
        alert(quietDelivery.sent.count == 1 && quietDelivery.sent[0].0.body.contains("100% used"),
              "A threshold crossed after presentation mode ends is delivered normally")

        alert(PresentationState.load(from: quietDefaults, now: quiet.tick) == PresentationState(),
              "Ending presentation mode clears the stored expiry")
        quiet.presentation = PresentationState.untilEnded
        alert(PresentationState.load(from: quietDefaults, now: quiet.tick) == PresentationState.untilEnded,
              "An active session is persisted for a relaunch")

        // MARK: User-requested real-notification probe
        let probeSuite = "nocci-probe-tests-" + UUID().uuidString
        let probeDefaults = UserDefaults(suiteName: probeSuite)!
        let probeDelivery = FakeDelivery()
        let probe = UsageModel(fetchCodex: { _ in }, loadClaude: { $0(nil) },
                               defaults: probeDefaults, delivery: probeDelivery)
        probe.tick = Date(timeIntervalSince1970: 5_000_000)
        probe.sendTestNotification()
        alert(probeDelivery.sent.count == 1,
              "The test action uses the production delivery boundary")
        alert(probeDelivery.sent[0].0.title == "Nocci test"
              && probeDelivery.sent[0].0.body.contains("Click to open the notch")
              && probeDelivery.sent[0].0.identifier == "nocci.test",
              "The test notification is clearly labelled and contains no usage data")
        alert(probeDelivery.sent[0].1 == false,
              "The test follows the default silent setting")
        probe.alertPreferences.sound = true
        probe.sendTestNotification()
        alert(probeDelivery.sent.count == 2 && probeDelivery.sent[1].1,
              "The test follows the enabled sound setting")
        probe.presentation = PresentationState(minutes: 30, from: probe.tick)
        probe.sendTestNotification()
        alert(probeDelivery.sent.count == 2,
              "Presentation Mode suppresses the test action as well as real alerts")

        UserDefaults().removePersistentDomain(forName: probeSuite)
        UserDefaults().removePersistentDomain(forName: quietSuite)

        UserDefaults().removePersistentDomain(forName: resetSuite)

        UserDefaults().removePersistentDomain(forName: customSuite)

        UserDefaults().removePersistentDomain(forName: alertSuite)

        // MARK: How hovering opens the panel
        let hoverSuite = "nocci-hover-open-tests-" + UUID().uuidString
        let hoverDefaults = UserDefaults(suiteName: hoverSuite)!
        display(DisplayPreferences.load(from: hoverDefaults).hoverOpen == .pause,
                "Hover opens after a short pause by default")
        var hoverPreferences = DisplayPreferences.load(from: hoverDefaults)
        hoverPreferences.hoverOpen = .clickOnly
        hoverPreferences.save(to: hoverDefaults)
        display(DisplayPreferences.load(from: hoverDefaults).hoverOpen == .clickOnly, "The hover choice is remembered")
        hoverDefaults.set("sometimes", forKey: "hoverOpen")
        display(DisplayPreferences.load(from: hoverDefaults).hoverOpen == .pause,
                "An unknown stored choice loads as the default")
        display(HoverOpen.instant.delay == 0 && HoverOpen.pause.delay == 0.3 && HoverOpen.clickOnly.delay == nil,
                "Each choice maps to its delay; click only never opens from hover")
        UserDefaults().removePersistentDomain(forName: hoverSuite)

        // MARK: The compact ring
        //
        // The ring fills to the same share as the number beside it, in either
        // mode, but its colour always follows the used share. Missing and
        // expired windows draw an empty ring.
        let ringNow = Date(timeIntervalSince1970: 10_000)
        let ringSnapshot = UsageSnapshot(windows: [UsageWindow(label: "5-hour", used: 38.4, reset: nil, kind: .session)],
                                         updated: ringNow)
        let usedRing = DisplayPreferences().reading(provider: "Claude", choice: .session, kind: nil,
                                                    snapshot: ringSnapshot, now: ringNow)
        display(usedRing.fraction == 0.38 && usedRing.used == 38.4, "The ring fills to the displayed used share")
        var remainingMode = DisplayPreferences()
        remainingMode.percentages = .remaining
        let remainingRing = remainingMode.reading(provider: "Claude", choice: .session, kind: nil,
                                                  snapshot: ringSnapshot, now: ringNow)
        display(remainingRing.fraction == 0.62 && remainingRing.used == 38.4,
                "In remaining mode the ring fills to the remaining share and its colour still follows use")
        let missingRing = DisplayPreferences().reading(provider: "Claude", choice: .weekly, kind: nil,
                                                       snapshot: ringSnapshot, now: ringNow)
        display(missingRing.fraction == nil && missingRing.used == nil, "A missing window draws an empty ring")
        let expiredRingSnapshot = UsageSnapshot(windows: [UsageWindow(label: "5-hour", used: 38,
                                                                      reset: Date(timeIntervalSince1970: 5_000),
                                                                      kind: .session)], updated: ringNow)
        display(DisplayPreferences().reading(provider: "Claude", choice: .session, kind: nil,
                                             snapshot: expiredRingSnapshot, now: ringNow).fraction == nil,
                "An expired window draws an empty ring")

        // MARK: Hide in full screen
        let fullSuite = "nocci-full-screen-tests-" + UUID().uuidString
        let fullDefaults = UserDefaults(suiteName: fullSuite)!
        display(!DisplayPreferences.load(from: fullDefaults).hideInFullScreen,
                "The notch stays over full-screen apps unless asked")
        var fullPreferences = DisplayPreferences.load(from: fullDefaults)
        fullPreferences.hideInFullScreen = true
        fullPreferences.save(to: fullDefaults)
        display(DisplayPreferences.load(from: fullDefaults).hideInFullScreen, "The choice is remembered")
        UserDefaults().removePersistentDomain(forName: fullSuite)

        print("\(displayChecks) display-preference checks passed")
        // MARK: Background ingestion
        //
        // Claude's snapshot is decoded off the main thread, so reads complete
        // asynchronously the way Codex reads already do. Disk work must never
        // sit on the path that also drives 30 Hz hover polling.
        var ingestionChecks = 0
        func ingestion(_ condition: @autoclosure () -> Bool, _ label: String) {
            guard condition() else { fatalError("FAIL: \(label)") }
            ingestionChecks += 1
        }

        var pending: [(UsageSnapshot?) -> Void] = []
        let ingestSuite = "nocci-ingest-tests-" + UUID().uuidString
        let ingestDefaults = UserDefaults(suiteName: ingestSuite)!
        let ingesting = UsageModel(fetchCodex: { _ in },
                                   loadClaude: { pending.append($0) },
                                   inspectClaude: { _ in .receiving },
                                   defaults: ingestDefaults)
        var published = 0
        let subscription = ingesting.$claude.dropFirst().sink { _ in published += 1 }

        ingesting.readClaude()
        ingestion(pending.count == 1, "Reading Claude starts one load")
        ingestion(ingesting.claude == nil, "The snapshot is not published before the load completes")

        ingesting.readClaude()
        ingesting.readClaude()
        ingestion(pending.count == 1, "A read already in flight is not duplicated by the timer")

        let firstRead = UsageSnapshot(windows: [UsageWindow(label: "5-hour", used: 41, reset: nil, kind: .session)],
                                  updated: Date(timeIntervalSince1970: 7_000_000))
        pending[0](firstRead)
        ingestion(ingesting.claude?.windows.first?.used == 41, "A completed load publishes its snapshot")
        ingestion(published == 1, "Publishing happens exactly once per changed reading")

        ingesting.readClaude()
        ingestion(pending.count == 2, "A finished read allows the next one")
        pending[1](firstRead)
        ingestion(published == 1, "Re-reading an unchanged file republishes nothing")

        var changed = firstRead
        changed.windows[0].used = 44
        ingesting.readClaude()
        pending[2](changed)
        ingestion(ingesting.claude?.windows.first?.used == 44 && published == 2,
                  "A changed reading publishes again")

        ingesting.readClaude()
        ingestion(pending.count == 4, "A further read starts while the earlier completion is outstanding")
        pending[0](nil)
        ingestion(published == 2 && ingesting.claude?.windows.first?.used == 44,
                  "A stale completion cannot publish over a newer read in flight")
        var newest = firstRead
        newest.windows[0].used = 57
        pending[3](newest)
        ingestion(ingesting.claude?.windows.first?.used == 57 && published == 3,
                  "The current read still publishes after a stale one was discarded")

        subscription.cancel()
        UserDefaults().removePersistentDomain(forName: ingestSuite)
        print("\(ingestionChecks) ingestion checks passed")
        // MARK: Pace
        //
        // Pace is off by default and feeds from a bounded in-memory buffer, so
        // it works whether or not persistent history recording is enabled.
        var paceChecks = 0
        func pace(_ condition: @autoclosure () -> Bool, _ label: String) {
            guard condition() else { fatalError("FAIL: \(label)") }
            paceChecks += 1
        }

        let paceSuite = "nocci-pace-tests-" + UUID().uuidString
        let paceDefaults = UserDefaults(suiteName: paceSuite)!
        let paceStart = Date(timeIntervalSince1970: 10_000_000)
        var paceReading = UsageSnapshot(
            windows: [UsageWindow(label: "5-hour", used: 10,
                                  reset: paceStart.addingTimeInterval(4 * 3600), kind: .session)],
            updated: paceStart)
        let pacing = UsageModel(fetchCodex: { _ in }, loadClaude: { $0(paceReading) },
                                inspectClaude: { _ in .receiving },
                                defaults: paceDefaults)
        pace(!pacing.preferences.showPace, "Pace is off by default")

        pacing.preferences.showPace = true
        // Seven readings ten minutes apart, rising five points each time.
        for step in 0...6 {
            let moment = paceStart.addingTimeInterval(Double(step) * 600)
            paceReading = UsageSnapshot(
                windows: [UsageWindow(label: "5-hour", used: 10 + Double(step) * 5,
                                      reset: paceStart.addingTimeInterval(4 * 3600), kind: .session)],
                updated: moment)
            pacing.tick = moment
            pacing.readClaude()
        }
        pace(pacing.claudePace?.verdict == .mayRunOut,
             "A steady climb toward the reset is reported as possibly running out")
        pace(pacing.claudePace?.basisMinutes == 60, "The estimate reports the span it used")

        pacing.preferences.showPace = false
        pace(pacing.claudePace == nil, "Turning pace off clears the estimate")

        // Warm-up: a freshly launched app has an empty buffer, so it says so
        // rather than estimating from one reading.
        let coldSuite = "nocci-cold-pace-tests-" + UUID().uuidString
        let coldDefaults = UserDefaults(suiteName: coldSuite)!
        var cold = DisplayPreferences()
        cold.showPace = true
        cold.save(to: coldDefaults)
        let unpaced = UsageModel(fetchCodex: { _ in }, loadClaude: { $0(paceReading) },
                                 inspectClaude: { _ in .receiving }, defaults: coldDefaults)
        unpaced.tick = paceReading.updated
        unpaced.readClaude()
        pace(unpaced.claudePace?.verdict == .insufficient,
             "A single reading after launch reports not enough data rather than estimating")

        // Heavy use: Claude Code can deliver a new reading on every
        // five-second read, and the buffer must still reach back far enough.
        let busySuite = "nocci-busy-pace-tests-" + UUID().uuidString
        let busyDefaults = UserDefaults(suiteName: busySuite)!
        cold.save(to: busyDefaults)
        var busyReading = paceReading
        let busy = UsageModel(fetchCodex: { _ in }, loadClaude: { $0(busyReading) },
                              inspectClaude: { _ in .receiving }, defaults: busyDefaults)
        for step in 0...(45 * 12) {
            let moment = paceStart.addingTimeInterval(Double(step) * 5)
            busyReading = UsageSnapshot(
                windows: [UsageWindow(label: "5-hour", used: 10 + Double(step) * 0.05,
                                      reset: paceStart.addingTimeInterval(4 * 3600), kind: .session)],
                updated: moment)
            busy.tick = moment
            busy.readClaude()
        }
        pace(busy.claudePace?.verdict == .mayRunOut,
             "A new reading every five seconds still gives an estimate after 45 minutes")

        UserDefaults().removePersistentDomain(forName: paceSuite)
        UserDefaults().removePersistentDomain(forName: coldSuite)
        UserDefaults().removePersistentDomain(forName: busySuite)
        print("\(paceChecks) pace-model checks passed")



        print("\(alertChecks) alert-delivery checks passed")
        print("\(checks) refresh-isolation checks passed")
    }
}
