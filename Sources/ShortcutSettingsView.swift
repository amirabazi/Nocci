import AppKit
import SwiftUI

/// Records one shortcut at a time from Settings. The monitor is local, so it
/// sees only keys typed while a Nocci window is key, and only while recording.
final class ShortcutRecorder: ObservableObject {
    @Published private(set) var recording: ShortcutAction?
    /// The modifiers held so far, drawn while recording.
    @Published private(set) var held: GlobalShortcut.Modifiers = []
    @Published private(set) var notice: String? {
        didSet {
            // The notice only changes a label under the rows; VoiceOver stays
            // on the recording button, so a refusal is spoken as well.
            guard let notice, notice != oldValue else { return }
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                 userInfo: [.announcement: notice, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
    }
    private let hotKeys: HotKeyService
    private var monitor: Any?
    private var resignObserver: NSObjectProtocol?

    init(hotKeys: HotKeyService) {
        self.hotKeys = hotKeys
    }

    func toggle(_ action: ShortcutAction) {
        precondition(Thread.isMainThread)
        if recording == action { return stop() }
        stop()
        recording = action
        notice = nil
        hotKeys.suspend(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            self?.handle(event) ?? event
        }
        // Clicking another window ends recording, as a text field ends editing.
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: nil,
                                                                queue: .main) { [weak self] _ in self?.stop() }
    }

    func clear(_ action: ShortcutAction) {
        precondition(Thread.isMainThread)
        stop()
        notice = nil
        hotKeys.set(nil, for: action)
    }

    func stop() {
        precondition(Thread.isMainThread)
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        held = []
        guard recording != nil else { return }
        recording = nil
        // A refusal shown while recording is about a candidate nobody is typing any more.
        notice = nil
        hotKeys.suspend(false)
    }

    /// Every key is swallowed while recording, so Command-Q or Command-W
    /// typed as a candidate never reaches the menu.
    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let action = recording else { return event }
        let modifiers = Self.modifiers(event.modifierFlags)
        if event.type == .flagsChanged {
            held = modifiers
            return event
        }
        if modifiers.isEmpty && event.keyCode == 53 {
            stop()
            return nil
        }
        if modifiers.isEmpty && (event.keyCode == 51 || event.keyCode == 117) {
            clear(action)
            return nil
        }
        let code = UInt32(event.keyCode)
        let typed = event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers ?? ""
        let shortcut = GlobalShortcut(keyCode: code, modifiers: modifiers, key: GlobalShortcut.label(keyCode: code, typed: typed))
        if let problem = shortcut.problem {
            notice = problem.message
            return nil
        }
        if let other = hotKeys.settings.conflict(shortcut, for: action) {
            notice = "\(shortcut.display) is already the shortcut to \(other.title.lowercased())."
            return nil
        }
        notice = nil
        hotKeys.set(shortcut, for: action)
        stop()
        return nil
    }

    static func modifiers(_ flags: NSEvent.ModifierFlags) -> GlobalShortcut.Modifiers {
        var modifiers: GlobalShortcut.Modifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        return modifiers
    }
}

/// Settings › General's shortcut tile.
struct ShortcutSettingsTile: View {
    @ObservedObject var hotKeys: HotKeyService
    @ObservedObject var recorder: ShortcutRecorder

    var body: some View {
        SettingsTile("Keyboard Shortcuts", glyph: .symbol("keyboard"),
                     footer: "These work in any app. Open the notch keeps it open for a few seconds, or for as long as the pointer is on it; press it again to close. Go to the session brings forward the first session in the Sessions tab. While recording, Delete clears a shortcut and Escape cancels. Nocci sees only these key presses and needs no permission for them.") {
            ForEach(Array(ShortcutAction.allCases.enumerated()), id: \.element) { index, action in
                if index > 0 { Hairline() }
                row(action)
            }
            if let notice = recorder.notice {
                Label(notice, systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onDisappear { recorder.stop() }
    }

    private func row(_ action: ShortcutAction) -> some View {
        let shortcut = hotKeys.settings[action]
        let recording = recorder.recording == action
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(action.title).accessibilityHidden(true)
                Spacer(minLength: 12)
                Button {
                    recorder.toggle(action)
                } label: {
                    Text(recording ? recordingLabel : shortcut?.display ?? "Record Shortcut")
                        .monospacedDigit()
                        .frame(minWidth: 124)
                }
                .accessibilityLabel(action.title)
                .accessibilityValue(recording ? "Recording. Type the shortcut." : shortcut?.spoken ?? "None")
                .accessibilityHint(recording ? "Press Escape to cancel" : "Records a new shortcut")
                // Always laid out, so both rows' buttons line up.
                let clearable = shortcut != nil && !recording
                Button {
                    recorder.clear(action)
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .opacity(clearable ? 1 : 0)
                .disabled(!clearable)
                .accessibilityHidden(!clearable)
                .help("Remove this shortcut")
                .accessibilityLabel("Remove the shortcut to \(action.title.lowercased())")
            }
            if hotKeys.refused.contains(action), shortcut != nil, !recording {
                Label("macOS or another app is using this shortcut, so it does nothing. Choose another.",
                      systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var recordingLabel: String {
        let modifiers = GlobalShortcut(keyCode: 0, modifiers: recorder.held, key: "").display
        return modifiers.isEmpty ? "Type Shortcut" : modifiers + "…"
    }
}
