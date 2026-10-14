import Foundation

@main
struct ShortcutTests {
    static func main() {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            guard condition() else { fatalError("FAIL: \(label)") }
            checks += 1
        }
        typealias M = GlobalShortcut.Modifiers
        func shortcut(_ code: UInt32, _ modifiers: M, _ key: String = "N") -> GlobalShortcut {
            GlobalShortcut(keyCode: code, modifiers: modifiers, key: key)
        }

        // MARK: Which combinations are allowed
        check(shortcut(45, [.control, .option]).problem == nil, "Control-Option-N is allowed")
        check(shortcut(32, [.command, .shift], "U").problem == nil, "Command-Shift-U is allowed")
        check(shortcut(45, [.control, .option, .shift, .command]).problem == nil, "All four modifiers are allowed")
        check(shortcut(45, []).problem == .needsModifiers, "A bare letter would take typing away from every app")
        check(shortcut(45, [.command]).problem == .needsModifiers, "Command alone would take an app's own shortcut")
        check(shortcut(45, [.option]).problem == .needsModifiers, "Option alone would take a typed character")
        check(shortcut(45, [.control]).problem == .needsModifiers, "Control alone would take an editing key")
        check(shortcut(45, [.shift]).problem == .needsModifiers, "Shift alone types a capital")
        check(shortcut(49, [.option], "Space").problem == .needsModifiers, "Option-Space needs a second modifier too")
        check(shortcut(105, [], "F13").problem == nil, "A function key may stand alone")
        check(shortcut(122, [.shift], "F1").problem == nil, "A function key with Shift is allowed")
        check(GlobalShortcut.functionKeys.count == 20, "F1 to F20 are the function keys")
        check(GlobalShortcut.functionKeys.allSatisfy { GlobalShortcut.namedKeys[$0]?.hasPrefix("F") == true },
              "Every function key has its name")

        // MARK: What macOS keeps
        for code: UInt32 in [20, 21, 23, 22] {
            check(shortcut(code, [.command, .shift], "3").problem == .reserved, "Screenshot shortcut \(code) is macOS's")
        }
        check(shortcut(53, [.command, .option], "Escape").problem == .reserved, "Force Quit is macOS's")
        check(shortcut(12, [.command, .shift], "Q").problem == .reserved, "Log Out is macOS's")
        check(shortcut(12, [.command, .control], "Q").problem == .reserved, "Lock Screen is macOS's")
        check(shortcut(49, [.command, .control], "Space").problem == .reserved, "Emoji & Symbols is macOS's")
        check(shortcut(12, [.command, .control, .option], "Q").problem == nil,
              "Only the exact reserved combination is refused")
        check(shortcut(20, [.command, .shift, .option], "3").problem == nil, "A third modifier makes it another shortcut")

        // MARK: Labels
        check(GlobalShortcut.label(keyCode: 49, typed: " ") == "Space", "Space is named")
        check(GlobalShortcut.label(keyCode: 126, typed: "") == "↑", "An arrow is drawn as one")
        check(GlobalShortcut.label(keyCode: 45, typed: "n") == "N", "A letter is shown as a capital")
        check(GlobalShortcut.label(keyCode: 12, typed: "a") == "A", "The layout's own letter wins over the US one")
        check(GlobalShortcut.label(keyCode: 27, typed: "ß") == "SS", "A letter's capital form is used, as the menu bar does")
        check(GlobalShortcut.label(keyCode: 50, typed: "\u{10}") == "Key 50", "A key that types nothing visible shows its code")
        check(GlobalShortcut.label(keyCode: 50, typed: "") == "Key 50", "So does a key that types nothing")
        check(GlobalShortcut.label(keyCode: 7, typed: "xxxxxxxx").count == 4, "A label is kept short")
        check(shortcut(45, [.command, .shift, .option, .control]).display == "⌃⌥⇧⌘N", "Symbols follow Apple's order")
        check(shortcut(45, [.control, .option]).spoken == "Control-Option-N", "VoiceOver hears the modifiers by name")
        check(shortcut(122, [], "F1").display == "F1" && shortcut(122, [], "F1").spoken == "F1", "A bare function key reads as itself")

        // MARK: Storage
        let suite = "nocci-shortcut-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        check(ShortcutSettings.load(from: defaults) == ShortcutSettings(), "Nothing is set until the user records a shortcut")
        let glance = shortcut(45, [.control, .option])
        GlobalShortcut.save(glance, for: .glance, to: defaults)
        check(GlobalShortcut.load(.glance, from: defaults) == glance, "A saved shortcut loads back")
        check(GlobalShortcut.load(.session, from: defaults) == nil, "Each action has its own key")
        check(ShortcutSettings.load(from: defaults)[.glance] == glance, "The settings load each action")
        GlobalShortcut.save(nil, for: .glance, to: defaults)
        check(defaults.object(forKey: "shortcuts.glance") == nil, "Clearing removes the stored value")
        func stored(_ value: [String: Any]) -> GlobalShortcut? {
            defaults.set(value, forKey: "shortcuts.glance")
            return GlobalShortcut.load(.glance, from: defaults)
        }
        let control = Int(M.control.rawValue), option = Int(M.option.rawValue)
        check(stored(["keyCode": 45, "modifiers": control | option, "key": "N"]) == glance, "A hand-written value in range loads")
        check(stored(["keyCode": 200, "modifiers": control | option, "key": "N"]) == nil, "An impossible key code is dropped")
        check(stored(["keyCode": -1, "modifiers": control | option, "key": "N"]) == nil, "A negative key code is dropped")
        check(stored(["keyCode": 45, "modifiers": -5, "key": "N"]) == nil, "Negative modifiers are dropped")
        check(stored(["keyCode": 45, "modifiers": control | option, "key": ""]) == nil, "An empty label is dropped")
        check(stored(["keyCode": 45, "modifiers": control | option]) == nil, "A missing label is dropped")
        check(stored(["keyCode": "45", "modifiers": control | option, "key": "N"]) == nil, "A key code of the wrong type is dropped")
        check(stored(["keyCode": 45, "modifiers": control, "key": "N"]) == nil,
              "A stored shortcut the rules refuse is not registered")
        check(stored(["keyCode": 45, "modifiers": control | option | 1, "key": "N"]) == glance,
              "Bits that are not modifiers are ignored")
        defaults.set("Control-Option-N", forKey: "shortcuts.glance")
        check(GlobalShortcut.load(.glance, from: defaults) == nil, "A value that is not a dictionary is ignored")

        // MARK: One combination, one action
        var settings = ShortcutSettings()
        settings[.glance] = glance
        check(settings.conflict(glance, for: .session) == .glance, "The same keys cannot do both")
        check(settings.conflict(glance, for: .glance) == nil, "Recording the same keys again for the same action is fine")
        check(settings.conflict(shortcut(45, [.control, .option, .shift]), for: .session) == nil,
              "Another modifier makes another combination")
        check(settings.conflict(GlobalShortcut(keyCode: 45, modifiers: [.control, .option], key: "Ñ"), for: .session) == .glance,
              "Combinations compare by key code and modifiers, not by label")

        // MARK: Hot key identifiers
        check(Set(ShortcutAction.allCases.map(\.hotKeyID)).count == ShortcutAction.allCases.count, "Each action has its own identifier")
        check(ShortcutAction.allCases.allSatisfy { ShortcutAction(hotKeyID: $0.hotKeyID) == $0 }, "An identifier maps back to its action")
        check(ShortcutAction(hotKeyID: 0) == nil && ShortcutAction(hotKeyID: 99) == nil, "An unknown identifier is no action")

        // MARK: Registering with macOS
        // An unlikely combination, registered only for this test process.
        let rare = shortcut(80, [.control, .option, .shift, .command], "F19")
        let first = HotKeyService(defaults: defaults)
        check(first.settings == ShortcutSettings() && first.refused.isEmpty, "Nothing is registered with no shortcut set")
        first.set(rare, for: .glance)
        check(first.refused.isEmpty, "macOS accepts a free combination")
        check(GlobalShortcut.load(.glance, from: defaults) == rare, "Setting a shortcut saves it")
        let second = HotKeyService(defaults: defaults)
        check(second.settings[.glance] == rare, "A new service starts from the saved shortcut")
        check(second.refused == [.glance], "A combination already registered is reported, not silently lost")
        first.suspend(true)
        second.set(rare, for: .glance)
        check(second.refused.isEmpty, "Suspending lets the combination go while recording")
        first.suspend(false)
        check(first.refused == [.glance], "Resuming reports that the combination has been taken meanwhile")
        second.set(nil, for: .glance)
        first.suspend(true)
        first.suspend(false)
        check(first.refused.isEmpty, "Once it is free again it registers")
        first.set(nil, for: .glance)
        check(first.refused.isEmpty && defaults.object(forKey: "shortcuts.glance") == nil, "Clearing unregisters and forgets it")

        print("\(checks) shortcut checks passed (isolated defaults; registered only in this process)")
    }
}
