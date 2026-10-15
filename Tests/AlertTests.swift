import Foundation

// Pure threshold-alert rules. No UserNotifications, no notification centre,
// no real user preferences: the engine is a function and is tested as one.
@main
struct AlertTests {
    static func main() {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            guard condition() else { fatalError("FAIL: \(label)") }
            checks += 1
        }
        let now = Date(timeIntervalSince1970: 1_000_000)
        let reset = Date(timeIntervalSince1970: 1_018_000)
        func reading(_ used: Double, kind: UsageWindow.Kind = .session,
                     provider: AlertProvider = .claude, reset: Date? = reset,
                     label: String = "5-hour") -> AlertReading {
            AlertReading(provider: provider, kind: kind, label: label, used: used, reset: reset)
        }

        // MARK: Baseline
        let baseline = evaluate(state: AlertState(), readings: [reading(85)], now: now)
        check(baseline.messages.isEmpty, "The first sight of a window never alerts, however high")
        check(baseline.state.windows["claude.session"]?.handled == [80],
              "The baseline marks the thresholds already crossed as handled")

        let quiet = evaluate(state: baseline.state, readings: [reading(88)], now: now)
        check(quiet.messages.isEmpty, "Rising within a handled threshold stays quiet")

        // MARK: Crossing
        let crossed = evaluate(state: baseline.state, readings: [reading(91)], now: now)
        check(crossed.messages.count == 1, "Crossing the next threshold alerts once")
        check(crossed.messages[0].body == "5-hour allowance: 90% used", "The message names the window and the used share")
        check(crossed.messages[0].title == "Claude usage", "The message names the provider")
        check(crossed.state.windows["claude.session"]?.handled == [80, 90], "The crossed threshold is recorded")

        let repeated = evaluate(state: crossed.state, readings: [reading(91)], now: now)
        check(repeated.messages.isEmpty, "The same reading twice alerts once")
        let higher = evaluate(state: crossed.state, readings: [reading(100)], now: now)
        check(higher.messages.count == 1 && higher.messages[0].body.contains("100% used"),
              "Reaching the last threshold alerts")

        // MARK: Custom thresholds
        check(AlertThreshold.normalize([90, 50, 90, 0, 101]) == [50, 90],
              "Threshold normalization sorts, deduplicates and bounds values")
        check(AlertThreshold.parse("90, 50; 90 75") == [50, 75, 90],
              "Threshold text accepts commas, semicolons and whitespace")
        check(AlertThreshold.parse("80, ninety") == nil && AlertThreshold.parse("0, 80") == nil,
              "Threshold text rejects non-integers and out-of-range values")
        check(AlertThreshold.text([100, 80, 90]) == "80, 90, 100",
              "Threshold text has one stable display format")

        let customThresholds: [AlertProvider: [Int]] = [.claude: [70, 85, 95], .codex: [50]]
        let customBaseline = evaluate(state: AlertState(), readings: [reading(72)],
                                      thresholdsByProvider: customThresholds, now: now)
        check(customBaseline.messages.isEmpty
              && customBaseline.state.windows["claude.session"]?.handled == [70],
              "A custom configuration establishes a silent baseline")
        let customCrossing = evaluate(state: customBaseline.state, readings: [reading(86)],
                                      thresholdsByProvider: customThresholds, now: now)
        check(customCrossing.messages.first?.body == "5-hour allowance: 85% used",
              "The engine sends the provider's configured threshold")
        check(customCrossing.state.windows["claude.session"]?.handled == [70, 85],
              "Custom handled levels are persisted like defaults")

        let providerSpecific = AlertState(windows: [
            "claude.session": AlertWindowState(reset: reset, handled: []),
            "codex.session": AlertWindowState(reset: reset, handled: [])])
        let providerSpecificResult = evaluate(
            state: providerSpecific,
            readings: [reading(60), reading(60, provider: .codex)],
            thresholdsByProvider: customThresholds, now: now)
        check(providerSpecificResult.messages.map(\.title) == [AlertProvider.codex.title],
              "Claude and Codex use independent threshold lists")

        let customNoReset = AlertState(windows: ["claude.session":
            AlertWindowState(reset: nil, handled: [70, 85])])
        let customDrop = evaluate(state: customNoReset, readings: [reading(69, reset: nil)],
                                  thresholdsByProvider: customThresholds, now: now)
        check(customDrop.state.windows["claude.session"]?.handled == [],
              "No-reset windows rearm below the provider's lowest custom threshold")

        // MARK: Highest applicable only
        let leap = evaluate(state: AlertState(windows: ["claude.session": AlertWindowState(reset: reset, handled: [])]),
                            readings: [reading(95)], now: now)
        check(leap.messages.count == 1 && leap.messages[0].body.contains("90% used"),
              "One reading crossing two thresholds sends only the highest")
        check(leap.state.windows["claude.session"]?.handled == [80, 90],
              "The skipped lower threshold is marked handled, not left to fire later")

        // MARK: Window identity
        let seen = AlertState(windows: ["claude.session": AlertWindowState(reset: reset, handled: [80, 90])])

        let corrected = evaluate(state: seen, readings: [reading(91, reset: reset.addingTimeInterval(120))], now: now)
        check(corrected.messages.isEmpty, "A reset correction inside the tolerance does not rearm")
        let farCorrection = evaluate(state: seen, readings: [reading(91, reset: reset.addingTimeInterval(601))], now: now)
        check(farCorrection.messages.count == 1, "A reset moving beyond the tolerance is a new window")

        let successor = evaluate(state: seen, readings: [reading(4, reset: reset.addingTimeInterval(18_000))], now: now)
        check(successor.messages.isEmpty, "A fresh window below every threshold is silent")
        check(successor.state.windows["claude.session"]?.handled == [], "A new window rearms every threshold")
        let successorHigh = evaluate(state: seen, readings: [reading(85, reset: reset.addingTimeInterval(18_000))], now: now)
        check(successorHigh.messages.count == 1 && successorHigh.messages[0].body.contains("80% used"),
              "A successor window alerts even when its first reading is already high")

        let appeared = evaluate(state: AlertState(windows: ["claude.session": AlertWindowState(reset: nil, handled: [80, 90])]),
                                readings: [reading(91)], now: now)
        check(appeared.messages.count == 1, "A reset time appearing counts as a new window")
        let vanished = evaluate(state: seen, readings: [reading(91, reset: nil)], now: now)
        check(vanished.messages.count == 1, "A reset time disappearing counts as a new window")

        // MARK: No reset metadata
        let noReset = AlertState(windows: ["claude.session": AlertWindowState(reset: nil, handled: [80, 90])])
        let dip = evaluate(state: noReset, readings: [reading(88, reset: nil)], now: now)
        check(dip.messages.isEmpty, "Without reset metadata a small dip does not rearm")
        let dropped = evaluate(state: noReset, readings: [reading(3, reset: nil)], now: now)
        check(dropped.state.windows["claude.session"]?.handled == [],
              "Without reset metadata a drop below the lowest threshold rearms")
        let decrease = evaluate(state: seen, readings: [reading(12)], now: now)
        check(decrease.state.windows["claude.session"]?.handled == [80, 90],
              "With a known reset a decrease never rearms")

        // MARK: Coalescing
        let bothWindows = AlertState(windows: [
            "claude.session": AlertWindowState(reset: reset, handled: []),
            "claude.weekly": AlertWindowState(reset: reset, handled: [])])
        let together = evaluate(state: bothWindows,
                                readings: [reading(91),
                                           reading(81, kind: .weekly, label: "Weekly")], now: now)
        check(together.messages.count == 1, "Two windows crossing together make one notification")
        check(together.messages[0].body == "5-hour allowance: 90% used · Weekly allowance: 80% used",
              "The coalesced body names both windows")
        check(together.messages[0].identifier.contains("+"), "The coalesced identifier covers both crossings")

        let twoProviders = AlertState(windows: [
            "claude.session": AlertWindowState(reset: reset, handled: []),
            "codex.session": AlertWindowState(reset: reset, handled: [])])
        let separate = evaluate(state: twoProviders,
                                readings: [reading(91),
                                           reading(91, provider: .codex)], now: now)
        check(separate.messages.count == 2, "Different providers are never coalesced together")
        check(separate.messages.map(\.title) == [AlertProvider.claude.title, AlertProvider.codex.title], "Provider messages keep a stable order")

        // MARK: Out-of-range usage and untouched windows
        //
        // The clamp in the engine is defensive: UsageParser already clamps, and
        // 140 would cross the last threshold either way. This pins the visible
        // behaviour rather than claiming to test the clamp.
        let over = evaluate(state: AlertState(windows: ["claude.session": AlertWindowState(reset: reset, handled: [])]),
                            readings: [reading(140)], now: now)
        check(over.messages.count == 1 && over.messages[0].body.contains("100% used"),
              "Usage beyond 100 alerts at the last threshold and no higher")
        let untouched = evaluate(state: seen, readings: [], now: now)
        check(untouched.state == seen && untouched.messages.isEmpty,
              "A provider that sends no reading keeps its stored state exactly")

        // MARK: Reset alerts
        //
        // A reset needs a previously known period plus a
        // fresh observation confirming the successor. Anything less stays quiet.
        let later = reset.addingTimeInterval(18_000)
        let notifiedWindow = AlertState(windows: ["claude.session":
            AlertWindowState(reset: reset, handled: [80, 90], notified: true)])

        let confirmed = evaluate(state: notifiedWindow, readings: [reading(5, reset: later)],
                                 resetAlerts: true, now: now)
        check(confirmed.messages.count == 1, "A confirmed successor window announces the reset")
        check(confirmed.messages[0].body == "5-hour allowance has reset",
              "The reset message names the window")
        check(confirmed.state.windows["claude.session"]?.notified == false,
              "The successor starts as not yet notified about")
        check(confirmed.state.windows["claude.session"]?.handled == [], "The successor rearms every threshold")

        let disabled = evaluate(state: notifiedWindow, readings: [reading(5, reset: later)],
                                resetAlerts: false, now: now)
        check(disabled.messages.isEmpty, "Reset alerts stay silent while switched off")

        let neverTold = AlertState(windows: ["claude.session":
            AlertWindowState(reset: reset, handled: [80], notified: false)])
        let quietReset = evaluate(state: neverTold, readings: [reading(5, reset: later)],
                                  resetAlerts: true, now: now)
        check(quietReset.messages.isEmpty,
              "A window we never warned about does not announce its reset")

        // MARK: Reset alerts suppressed when the period is not confident
        let backwards = evaluate(state: notifiedWindow,
                                 readings: [reading(5, reset: reset.addingTimeInterval(-18_000))],
                                 resetAlerts: true, now: now)
        check(backwards.messages.isEmpty, "A reset moving backwards is a correction, not a new allowance")
        check(backwards.state.windows["claude.session"]?.handled == [], "A backwards jump still rearms thresholds")

        let appearing = evaluate(state: AlertState(windows: ["claude.session":
                                    AlertWindowState(reset: nil, handled: [80], notified: true)]),
                                 readings: [reading(5, reset: later)], resetAlerts: true, now: now)
        check(appearing.messages.isEmpty, "A reset time appearing cannot confirm a successor")
        let vanishing = evaluate(state: notifiedWindow, readings: [reading(5, reset: nil)],
                                 resetAlerts: true, now: now)
        check(vanishing.messages.isEmpty, "A reset time disappearing cannot confirm a successor")
        let guessed = evaluate(state: AlertState(windows: ["claude.session":
                                  AlertWindowState(reset: nil, handled: [80, 90], notified: true)]),
                               readings: [reading(3, reset: nil)], resetAlerts: true, now: now)
        check(guessed.messages.isEmpty, "The usage-drop fallback is a guess and never announces a reset")
        let tolerated = evaluate(state: notifiedWindow,
                                 readings: [reading(91, reset: reset.addingTimeInterval(120))],
                                 resetAlerts: true, now: now)
        check(tolerated.messages.isEmpty, "A correction inside the tolerance is not a reset")

        // MARK: A threshold crossing marks the window as notified
        let fresh = AlertState(windows: ["claude.session": AlertWindowState(reset: reset, handled: [])])
        let told = evaluate(state: fresh, readings: [reading(85)], resetAlerts: true, now: now)
        check(told.state.windows["claude.session"]?.notified == true,
              "Delivering a threshold alert records that we warned about this window")
        let baselined = evaluate(state: AlertState(), readings: [reading(85)], resetAlerts: true, now: now)
        check(baselined.state.windows["claude.session"]?.notified == false,
              "A silent baseline does not count as having warned")

        // MARK: Reset and crossing together
        let both = evaluate(state: notifiedWindow, readings: [reading(85, reset: later)],
                            resetAlerts: true, now: now)
        check(both.messages.count == 1, "A reset and a crossing in one reading make one notification")
        check(both.messages[0].body == "5-hour allowance has reset · 5-hour allowance: 80% used",
              "The combined body reports the reset and the crossing")

        // MARK: Forgetting a provider
        var mixed = AlertState(windows: [
            "claude.session": AlertWindowState(reset: reset, handled: [80]),
            "claude.weekly": AlertWindowState(reset: reset, handled: [80, 90]),
            "codex.session": AlertWindowState(reset: reset, handled: [80])])
        mixed.forget(.claude)
        check(mixed.windows.keys.sorted() == ["codex.session"],
              "Turning Claude's alerts off forgets only Claude's windows")
        let rebaselined = evaluate(state: mixed, readings: [reading(85)], now: now)
        check(rebaselined.messages.isEmpty, "Re-enabling a forgotten provider baselines instead of alerting")

        // MARK: Preferences and state persistence
        let suiteName = "notch-alert-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!

        check(AlertPreferences.load(from: defaults) == AlertPreferences(), "Alerts default to off")
        check(!AlertPreferences().claude && !AlertPreferences().codex && !AlertPreferences().sound,
              "Both providers and sound start off")
        check(AlertPreferences.load(from: defaults).claudeThresholds == [80, 90, 100]
              && AlertPreferences.load(from: defaults).codexThresholds == [80, 90, 100],
              "Both providers default to the suggested thresholds")

        var preferences = AlertPreferences()
        preferences.claude = true
        preferences.sound = true
        preferences.setThresholds([90, 50, 90, 101], for: .claude)
        preferences.setThresholds([25], for: .codex)
        preferences.save(to: defaults)
        check(AlertPreferences.load(from: defaults) == preferences, "Alert preferences round trip")
        check(AlertPreferences.load(from: defaults).thresholds(for: .claude) == [50, 90]
              && AlertPreferences.load(from: defaults).thresholds(for: .codex) == [25],
              "Per-provider custom thresholds survive a relaunch")
        check(AlertPreferences.load(from: defaults).codex == false, "An off provider is not read back as on")
        check(preferences.enabled(for: .claude) && !preferences.enabled(for: .codex),
              "Enablement is reported per provider")

        defaults.set([-2, 0, 101], forKey: "claudeAlertThresholds")
        defaults.set([70, 0, 70, 90], forKey: "codexAlertThresholds")
        let recoveredPreferences = AlertPreferences.load(from: defaults)
        check(recoveredPreferences.claudeThresholds == [80, 90, 100],
              "A stored threshold list with no valid value recovers to defaults")
        check(recoveredPreferences.codexThresholds == [70, 90],
              "Valid stored thresholds survive invalid and duplicate neighbours")

        check(AlertState.load(from: defaults) == AlertState(), "Absent state loads empty")
        let stored = AlertState(windows: ["claude.session": AlertWindowState(reset: reset, handled: [80, 90])])
        stored.save(to: defaults)
        check(AlertState.load(from: defaults) == stored, "Alert state round trips through storage")
        check(AlertState.load(from: defaults).windows["claude.session"]?.handled == [80, 90],
              "Handled thresholds survive a relaunch, so nothing repeats")
        defaults.set("not json", forKey: "alertState")
        check(AlertState.load(from: defaults) == AlertState(), "Unreadable stored state falls back to empty")

        UserDefaults().removePersistentDomain(forName: suiteName)

        print("\(checks) alert-engine checks passed")
    }
}
