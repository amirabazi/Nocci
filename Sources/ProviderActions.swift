import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum ActionProvider: String, CaseIterable {
    case claude, codex

    var name: String { self == .claude ? "Claude" : "Codex" }
    var bundleIdentifier: String {
        self == .claude ? "com.anthropic.claudefordesktop" : "com.openai.codex"
    }
    var preferenceKey: String { "quickActions.\(rawValue).applicationPath" }
    // Official help-center destinations verified 20 September 2026.
    var usageURL: URL {
        URL(string: self == .claude ? "https://claude.ai/settings/usage" : "https://chatgpt.com/codex/settings/usage")!
    }
}

enum ProviderActionError: LocalizedError {
    case missingApplication(String), browserUnavailable
    var errorDescription: String? {
        switch self {
        case .missingApplication(let name): return "Choose the \(name) desktop app to open it from Nocci."
        case .browserUnavailable: return "macOS could not open your browser. Check that a default browser is available and try again."
        }
    }
}

/// This service opens apps and public account pages only. It never runs a CLI or changes provider configuration.
final class ProviderActionService {
    private let defaults: UserDefaults
    private let lookup: (String) -> URL?
    private let isApplication: (URL) -> Bool
    private let launch: (URL, @escaping (Error?) -> Void) -> Void
    private let browse: (URL) -> Bool

    init(defaults: UserDefaults = .standard,
         lookup: @escaping (String) -> URL? = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) },
         isApplication: @escaping (URL) -> Bool = ProviderActionService.isApplicationBundle,
         launch: @escaping (URL, @escaping (Error?) -> Void) -> Void = { url, completion in
             NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                 DispatchQueue.main.async { completion(error) }
             }
         },
         browse: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        self.defaults = defaults; self.lookup = lookup; self.isApplication = isApplication
        self.launch = launch; self.browse = browse
    }

    static func isApplicationBundle(_ url: URL) -> Bool {
        guard url.isFileURL, url.pathExtension.lowercased() == "app",
              let bundle = Bundle(url: url),
              bundle.object(forInfoDictionaryKey: "CFBundlePackageType") as? String == "APPL",
              let executable = bundle.executableURL else { return false }
        return FileManager.default.isExecutableFile(atPath: executable.path)
    }

    func application(for provider: ActionProvider) -> URL? {
        if let path = defaults.string(forKey: provider.preferenceKey) {
            let url = URL(fileURLWithPath: path)
            if isApplication(url) { return url }
        }
        // Launch Services follows renamed/moved applications; never infer an app from the configured CLI path.
        guard let url = lookup(provider.bundleIdentifier), isApplication(url) else { return nil }
        return url
    }

    @discardableResult
    func selectApplication(_ url: URL, for provider: ActionProvider) -> Bool {
        guard isApplication(url) else { return false }
        defaults.set(url.path, forKey: provider.preferenceKey)
        return true
    }

    func openApplication(_ provider: ActionProvider, completion: @escaping (Error?) -> Void) {
        guard let url = application(for: provider) else {
            completion(ProviderActionError.missingApplication(provider.name)); return
        }
        launch(url, completion)
    }

    func openUsage(_ provider: ActionProvider) -> Error? {
        browse(provider.usageURL) ? nil : ProviderActionError.browserUnavailable
    }
}

final class ProviderActions: NSObject {
    static let shared = ProviderActions()
    private let service = ProviderActionService()

    func open(_ provider: ActionProvider) {
        service.openApplication(provider) { [weak self] error in
            guard let self, let error else { return }
            if case ProviderActionError.missingApplication = error {
                let alert = NSAlert()
                alert.messageText = "\(provider.name) desktop app not found"
                alert.informativeText = "Choose an installed desktop app, or open your account usage in your browser. This does not change usage tracking."
                alert.addButton(withTitle: "Choose App…")
                alert.addButton(withTitle: "Account Usage…")
                alert.addButton(withTitle: "Cancel")
                NSApp.activate(ignoringOtherApps: true)
                switch alert.runModal() {
                case .alertFirstButtonReturn: self.choose(provider)
                case .alertSecondButtonReturn: self.usage(provider)
                default: break
                }
            } else { self.show(error, title: "Couldn’t open \(provider.name)") }
        }
    }

    func usage(_ provider: ActionProvider) {
        if let error = service.openUsage(provider) { show(error, title: "Couldn’t open account usage") }
    }

    func choose(_ provider: ActionProvider) {
        let picker = NSOpenPanel()
        picker.title = "Choose an app for \(provider.name)"
        picker.message = "Select the desktop app to open. This is separate from the executable used for usage tracking."
        picker.prompt = "Choose"
        picker.allowedContentTypes = [.application]
        picker.canChooseFiles = true; picker.canChooseDirectories = false
        picker.allowsMultipleSelection = false
        picker.directoryURL = URL(fileURLWithPath: "/Applications")
        NSApp.activate(ignoringOtherApps: true)
        guard picker.runModal() == .OK, let url = picker.url else { return }
        guard service.selectApplication(url, for: provider) else {
            show(ProviderActionError.missingApplication(provider.name), title: "Choose a runnable macOS app")
            return
        }
        open(provider)
    }

    private func show(_ error: Error, title: String) {
        let alert = NSAlert()
        alert.messageText = title; alert.informativeText = error.localizedDescription
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    func menuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Quick Actions", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: item.title)
        for provider in ActionProvider.allCases {
            let parent = NSMenuItem(title: provider.name, action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: provider.name)
            for (title, selector) in [("Open \(provider.name)", #selector(openItem(_:))),
                                      ("Account Usage…", #selector(usageItem(_:))),
                                      ("Choose App…", #selector(chooseItem(_:)))] {
                let action = NSMenuItem(title: title, action: selector, keyEquivalent: "")
                action.target = self; action.representedObject = provider.rawValue
                submenu.addItem(action)
            }
            parent.submenu = submenu; menu.addItem(parent)
        }
        item.submenu = menu
        return item
    }

    @objc private func openItem(_ item: NSMenuItem) { if let provider = provider(item) { open(provider) } }
    @objc private func usageItem(_ item: NSMenuItem) { if let provider = provider(item) { usage(provider) } }
    @objc private func chooseItem(_ item: NSMenuItem) { if let provider = provider(item) { choose(provider) } }
    private func provider(_ item: NSMenuItem) -> ActionProvider? {
        (item.representedObject as? String).flatMap(ActionProvider.init(rawValue:))
    }
}

struct ProviderQuickActions: View {
    var body: some View {
        ForEach(ActionProvider.allCases, id: \.rawValue) { provider in
            Menu(provider.name) {
                Button("Open \(provider.name)") { ProviderActions.shared.open(provider) }
                Button("Account Usage…") { ProviderActions.shared.usage(provider) }
                Divider()
                Button("Choose App…") { ProviderActions.shared.choose(provider) }
            }
        }
    }
}
