import Carbon
import Combine

/// Registers the chosen shortcuts with macOS's hot key API, which needs no
/// Accessibility or Input Monitoring permission and sees only the presses of
/// the combinations registered, never other typing. The rules are in
/// `Shortcuts.swift`; this is the only Carbon code.
final class HotKeyService: ObservableObject {
    @Published private(set) var settings: ShortcutSettings
    /// Actions whose shortcut macOS refused to register.
    @Published private(set) var refused: Set<ShortcutAction> = []
    /// Called on the main thread with the action whose shortcut was pressed.
    var onPress: ((ShortcutAction) -> Void)?
    private var references: [ShortcutAction: EventHotKeyRef] = [:]
    /// Actions whose key is held down. macOS repeats the pressed event while
    /// a hot key is held, so an action runs once per press, on the first.
    private var pressed: Set<ShortcutAction> = []
    private var handler: EventHandlerRef?
    private var suspended = false
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        settings = ShortcutSettings.load(from: defaults)
        var types = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr, id.signature == HotKeyService.signature,
                  let action = ShortcutAction(hotKeyID: id.id) else { return OSStatus(eventNotHandledErr) }
            let service = Unmanaged<HotKeyService>.fromOpaque(context).takeUnretainedValue()
            if GetEventKind(event) == UInt32(kEventHotKeyReleased) {
                service.pressed.remove(action)
            } else if service.pressed.insert(action).inserted {
                service.onPress?(action)
            }
            return noErr
        }, 2, &types, Unmanaged.passUnretained(self).toOpaque(), &handler)
        register()
    }

    deinit {
        unregister()
        if let handler { RemoveEventHandler(handler) }
    }

    /// 'NOCC'.
    static let signature: OSType = 0x4E4F_4343

    func set(_ shortcut: GlobalShortcut?, for action: ShortcutAction) {
        precondition(Thread.isMainThread)
        settings[action] = shortcut
        GlobalShortcut.save(shortcut, for: action, to: defaults)
        register()
    }

    /// While Settings records a shortcut the current ones stay quiet, or
    /// pressing one to replace it would run it.
    func suspend(_ value: Bool) {
        precondition(Thread.isMainThread)
        guard value != suspended else { return }
        suspended = value
        register()
    }

    private func register() {
        unregister()
        guard !suspended else { return }
        var refused: Set<ShortcutAction> = []
        for action in ShortcutAction.allCases {
            guard let shortcut = settings[action] else { continue }
            var reference: EventHotKeyRef?
            let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers.rawValue,
                                             EventHotKeyID(signature: Self.signature, id: action.hotKeyID),
                                             GetApplicationEventTarget(), 0, &reference)
            if status == noErr, let reference { references[action] = reference } else { refused.insert(action) }
        }
        if refused != self.refused { self.refused = refused }
    }

    private func unregister() {
        for reference in references.values { UnregisterEventHotKey(reference) }
        references = [:]
        // A key held through re-registration sends no release for the old registration.
        pressed = []
    }
}
