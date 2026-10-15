import Foundation

/// What a global shortcut does. Both are off until the user records one.
enum ShortcutAction: String, CaseIterable {
    /// Opens the notch and holds it for a moment, or closes it.
    case glance
    /// Goes to the session at the top of the Sessions list.
    case session

    var title: String {
        switch self {
        case .glance: return "Open the notch"
        case .session: return "Go to the session that needs you"
        }
    }

    /// The identifier macOS hands back with a press.
    var hotKeyID: UInt32 {
        switch self {
        case .glance: return 1
        case .session: return 2
        }
    }

    init?(hotKeyID: UInt32) {
        guard let action = Self.allCases.first(where: { $0.hotKeyID == hotKeyID }) else { return nil }
        self = action
    }

    var defaultsKey: String { "shortcuts.\(rawValue)" }
}

/// A key and the modifiers held with it, as macOS's hot key API takes them:
/// a virtual key code and Carbon's modifier bits. `key` is the label shown
/// for the key, taken from the keyboard layout when it was recorded, so a
/// non-US layout reads as the user typed it.
struct GlobalShortcut: Equatable {
    struct Modifiers: OptionSet, Hashable {
        let rawValue: UInt32
        // Carbon's cmdKey, shiftKey, optionKey and controlKey.
        static let command = Modifiers(rawValue: 1 << 8)
        static let shift = Modifiers(rawValue: 1 << 9)
        static let option = Modifiers(rawValue: 1 << 11)
        static let control = Modifiers(rawValue: 1 << 12)
    }

    enum Problem: Equatable {
        /// Too few modifiers: the shortcut would take a key another app needs.
        case needsModifiers
        /// macOS already uses it.
        case reserved

        var message: String {
            switch self {
            case .needsModifiers:
                return "Use at least two modifier keys, such as Control-Option, so the shortcut can’t take a key another app needs."
            case .reserved:
                return "macOS already uses that shortcut. Choose another."
            }
        }
    }

    var keyCode: UInt32
    var modifiers: Modifiers
    var key: String

    /// Virtual key codes of the keys named rather than typed. Function keys
    /// may stand alone, since no app types them.
    static let namedKeys: [UInt32: String] = [
        36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Escape", 117: "Forward Delete",
        115: "Home", 119: "End", 116: "Page Up", 121: "Page Down",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
        106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20"
    ]
    static let functionKeys: Set<UInt32> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111,
                                            105, 107, 113, 106, 64, 79, 80, 90]

    /// Shortcuts macOS keeps for itself. Registering one would either fail
    /// quietly or take it away from the system.
    private static let reservedShortcuts: [(UInt32, Modifiers)] = [
        (20, [.command, .shift]), (21, [.command, .shift]), (23, [.command, .shift]), (22, [.command, .shift]), // screenshots
        (53, [.command, .option]),                // Force Quit
        (12, [.command, .shift]),                 // Log Out
        (12, [.command, .control]),               // Lock Screen
        (49, [.command, .control]),               // Emoji & Symbols
        (49, [.command, .option]),                // Finder search
        (3, [.command, .control]),                // full screen
        (4, [.command, .option]),                 // hide others
        (2, [.command, .option]),                 // Dock hiding
        (46, [.command, .option]),                // minimise all
        (44, [.command, .shift])                  // Help search
    ]

    /// The label for the key with this code, falling back to what the
    /// layout typed for it, and to the code when it typed nothing visible.
    static func label(keyCode: UInt32, typed: String) -> String {
        if let name = namedKeys[keyCode] { return name }
        let visible = typed.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        return visible.isEmpty ? "Key \(keyCode)" : String(visible.uppercased().prefix(4))
    }

    var problem: Problem? {
        if Self.reservedShortcuts.contains(where: { $0.0 == keyCode && $0.1 == modifiers }) { return .reserved }
        if Self.functionKeys.contains(keyCode) { return nil }
        let held = [Modifiers.command, .option, .control, .shift].filter { modifiers.contains($0) }
        guard held.count >= 2, held.contains(where: { $0 != .shift }) else { return .needsModifiers }
        return nil
    }

    /// Apple's order: Control, Option, Shift, Command, then the key.
    var display: String {
        symbols.map(\.symbol).joined() + key
    }

    /// Read aloud by VoiceOver: "Control-Option-N".
    var spoken: String {
        (symbols.map(\.name) + [key]).joined(separator: "-")
    }

    private var symbols: [(symbol: String, name: String)] {
        [(Modifiers.control, "⌃", "Control"), (.option, "⌥", "Option"), (.shift, "⇧", "Shift"), (.command, "⌘", "Command")]
            .filter { modifiers.contains($0.0) }
            .map { ($0.1, $0.2) }
    }

    /// Anything unreadable, or out of range, reads as no shortcut.
    static func load(_ action: ShortcutAction, from defaults: UserDefaults = .standard) -> GlobalShortcut? {
        guard let stored = defaults.dictionary(forKey: action.defaultsKey),
              let code = stored["keyCode"] as? Int, (0...127).contains(code),
              let raw = stored["modifiers"] as? Int, raw >= 0, raw <= Int(UInt32.max),
              let key = stored["key"] as? String, !key.isEmpty, key.count <= 16 else { return nil }
        let modifiers = Modifiers(rawValue: UInt32(raw)).intersection([.command, .shift, .option, .control])
        let shortcut = GlobalShortcut(keyCode: UInt32(code), modifiers: modifiers, key: key)
        return shortcut.problem == nil ? shortcut : nil
    }

    static func save(_ shortcut: GlobalShortcut?, for action: ShortcutAction, to defaults: UserDefaults = .standard) {
        guard let shortcut else { return defaults.removeObject(forKey: action.defaultsKey) }
        defaults.set(["keyCode": Int(shortcut.keyCode), "modifiers": Int(shortcut.modifiers.rawValue), "key": shortcut.key],
                     forKey: action.defaultsKey)
    }
}

/// Both actions' shortcuts. One key combination does one thing.
struct ShortcutSettings: Equatable {
    private var values: [ShortcutAction: GlobalShortcut] = [:]

    subscript(action: ShortcutAction) -> GlobalShortcut? {
        get { values[action] }
        set { values[action] = newValue }
    }

    /// The other action already using this combination, if any.
    func conflict(_ shortcut: GlobalShortcut, for action: ShortcutAction) -> ShortcutAction? {
        ShortcutAction.allCases.first {
            $0 != action && values[$0].map { $0.keyCode == shortcut.keyCode && $0.modifiers == shortcut.modifiers } == true
        }
    }

    static func load(from defaults: UserDefaults = .standard) -> ShortcutSettings {
        var settings = ShortcutSettings()
        for action in ShortcutAction.allCases { settings[action] = GlobalShortcut.load(action, from: defaults) }
        return settings
    }
}
