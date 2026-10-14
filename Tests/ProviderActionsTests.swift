import AppKit

@main
struct ProviderActionsTests {
    static func main() throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            guard condition() else { fatalError("FAIL: \(label)") }
            checks += 1
        }
        let suite = "Nocci.QuickActionsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let installed = URL(fileURLWithPath: "/Applications/Renamed Codex.app")
        let custom = URL(fileURLWithPath: "/Volumes/Work/My Claude.app")
        let cli = URL(fileURLWithPath: "/tmp/codex")
        var registered: [String: URL] = [ActionProvider.codex.bundleIdentifier: installed]
        var valid = Set([installed, custom])
        var launched: [URL] = []
        var browsed: [URL] = []
        var failure: Error?
        var browserAvailable = true
        let service = ProviderActionService(defaults: defaults, lookup: { registered[$0] },
            isApplication: { valid.contains($0) }, launch: { url, completion in
                launched.append(url); completion(failure)
            }, browse: { url in browsed.append(url); return browserAvailable })
        check(launched.isEmpty && browsed.isEmpty && defaults.dictionaryRepresentation()[ActionProvider.codex.preferenceKey] == nil,
              "Construction has no launch or preference side effects")
        check(service.application(for: .codex) == installed, "Resolves renamed installed app by bundle identifier")
        check(service.application(for: .claude) == nil, "Missing desktop app remains unavailable")
        var result: Error?
        service.openApplication(.claude) { result = $0 }
        check(result is ProviderActionError && launched.isEmpty, "Missing app reports recovery without launching anything")
        defaults.set(cli.path, forKey: "codexPath")
        registered = [:]
        check(service.application(for: .codex) == nil, "Configured CLI is never a desktop launch target")
        check(!service.selectApplication(cli, for: .claude), "Invalid custom selection is rejected")
        check(defaults.string(forKey: ActionProvider.claude.preferenceKey) == nil, "Invalid selection is not persisted")
        check(service.selectApplication(custom, for: .claude), "Custom app can be selected")
        check(service.application(for: .claude) == custom, "Custom app outside Applications resolves")
        let reloaded = ProviderActionService(defaults: defaults, lookup: { _ in installed }, isApplication: { valid.contains($0) })
        check(reloaded.application(for: .claude) == custom, "Saved selection survives service reconstruction and overrides discovery")
        service.openApplication(.claude) { result = $0 }
        check(result == nil && launched == [custom], "Valid target is opened once")
        failure = NSError(domain: "Fixture", code: 7, userInfo: [NSLocalizedDescriptionKey: "Launch denied"])
        service.openApplication(.claude) { result = $0 }
        check(result?.localizedDescription == "Launch denied", "Launch failure reaches UI callback")
        valid.remove(custom)
        registered[ActionProvider.claude.bundleIdentifier] = installed
        check(service.application(for: .claude) == installed, "Moved/deleted saved target falls back to installed app")
        check(defaults.string(forKey: ActionProvider.claude.preferenceKey) == custom.path, "Temporary missing volume does not erase preference")
        valid.remove(installed)
        check(service.application(for: .claude) == nil, "Stale Launch Services entry is not launched")
        for provider in ActionProvider.allCases {
            check(service.openUsage(provider) == nil, "Browser success reported for \(provider.name)")
            check(browsed.last == provider.usageURL, "Correct account destination for \(provider.name)")
            check(provider.usageURL.scheme == "https" && provider.usageURL.query == nil && provider.usageURL.user == nil,
                  "Account link contains no credentials or usage payload")
        }
        check(ActionProvider.claude.usageURL.absoluteString == "https://claude.ai/settings/usage", "Claude uses official usage destination")
        check(ActionProvider.codex.usageURL.absoluteString == "https://chatgpt.com/codex/settings/usage", "Codex uses official usage destination")
        browserAvailable = false
        check(service.openUsage(.claude)?.localizedDescription.contains("default browser") == true, "Browser failure has recovery guidance")

        // Validate real bundle inspection against temporary fixtures, not installed provider apps.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Fixture.app")
        let executable = app.appendingPathComponent("Contents/MacOS/Fixture")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundlePackageType": "APPL", "CFBundleExecutable": "Fixture", "CFBundleIdentifier": suite]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        try Data("fixture, never executed".utf8).write(to: executable)
        check(!ProviderActionService.isApplicationBundle(app), "Non-executable bundle is rejected")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        check(ProviderActionService.isApplicationBundle(app), "Runnable application bundle is accepted")
        check(!ProviderActionService.isApplicationBundle(executable), "Executable alone is rejected")
        check(!ProviderActionService.isApplicationBundle(URL(string: "https://example.com/Fake.app")!), "Remote app URL is rejected")
        print("\(checks) quick-action checks passed (isolated defaults; no apps or browsers launched)")
    }
}
