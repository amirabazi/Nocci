import Foundation

// Installing and removing Nocci's Claude Code hooks, against temporary config
// and support directories. The real ~/.claude/settings.json is never touched.
@main
struct ClaudeHooksTests {
    static func main() throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            guard condition() else { fatalError("FAIL: \(label)") }
            checks += 1
        }
        func failure(_ body: () throws -> Any) -> ClaudeIntegrationError? {
            do { _ = try body(); return nil } catch { return error as? ClaudeIntegrationError }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nocci-hooks-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        func app(_ folder: String) throws -> String {
            let url = root.appendingPathComponent("\(folder)/Nocci.app/Contents/MacOS/Nocci")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\n".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            return url.path
        }
        func installer(_ name: String, appPath: String, managed: String = "/nonexistent/managed.json") -> ClaudeHooksInstaller {
            let paths = ClaudePaths(configDirectory: root.appendingPathComponent("\(name)/claude"),
                                    supportDirectory: root.appendingPathComponent("\(name)/support"))
            return ClaudeHooksInstaller(paths: paths, appPath: appPath, managedSettingsPath: managed,
                                        now: { Date(timeIntervalSince1970: 1_800_000_000) })
        }
        func settings(_ hooks: ClaudeHooksInstaller) -> [String: Any] {
            (try? JSONSerialization.jsonObject(with: Data(contentsOf: hooks.paths.settingsFile))) as? [String: Any] ?? [:]
        }
        func groups(_ object: [String: Any], _ event: String) -> [[String: Any]] {
            ((object["hooks"] as? [String: Any])?[event] as? [[String: Any]]) ?? []
        }
        func write(_ text: String, _ hooks: ClaudeHooksInstaller) throws {
            try FileManager.default.createDirectory(at: hooks.paths.configDirectory, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: hooks.paths.settingsFile)
        }
        let appPath = try app("Applications")

        // The command
        let empty = installer("empty", appPath: appPath)
        check(empty.command == "'\(appPath)' --claude-hook 2>/dev/null || true",
              "The command quotes the app and can never fail a session")
        check(ClaudeHooksInstaller.isNocciHook(empty.command) && ClaudeHooksInstaller.isNocciHook("'/Old Place/Nocci.app/Contents/MacOS/Nocci' --claude-hook 2>/dev/null || true"),
              "Nocci's hook is recognised at any path")
        for foreign in ["/usr/local/bin/notify-me", "'/x/Nocci' --claude-statusline", "echo Nocci --claude-hook",
                        "'/x/NotNocci' --claude-hook"] {
            check(!ClaudeHooksInstaller.isNocciHook(foreign), "Not Nocci's hook: \(foreign)")
        }

        // Installing into nothing
        check(empty.status() == .off, "Off before installing")
        let firstPlan = try empty.plan()
        check(firstPlan.settingsPath == empty.paths.settingsFile.path && firstPlan.backupPath == nil
              && firstPlan.fragment.contains("--claude-hook") && firstPlan.fragment.contains("PermissionRequest"),
              "The plan names the file and shows the hooks; a missing file needs no backup")
        _ = try empty.install()
        let installed = settings(empty)
        check(ClaudeHooksInstaller.events.allSatisfy { groups(installed, $0.name).count == 1 }, "One group per event")
        let preTool = groups(installed, "PreToolUse")[0]
        let entry = (preTool["hooks"] as? [[String: Any]])?.first ?? [:]
        check(preTool["matcher"] as? String == "AskUserQuestion" && entry["type"] as? String == "command"
              && entry["command"] as? String == empty.command && entry["async"] as? Bool == true && entry["timeout"] as? Int == 10,
              "Hooks run in the background with a short timeout; PreToolUse only for questions")
        check(groups(installed, "Stop")[0]["matcher"] == nil
              && groups(installed, "Notification")[0]["matcher"] as? String == "permission_prompt|elicitation_dialog|elicitation_url_dialog|agent_needs_input",
              "Matchers as designed")
        check(Set((installed["hooks"] as? [String: Any] ?? [:]).keys) == Set(ClaudeHooksInstaller.events.map(\.name)),
              "Only the long-standing events are registered")
        check(empty.status() == .on, "On after installing")
        let mode = (try FileManager.default.attributesOfItem(atPath: empty.recordFile.path))[.posixPermissions] as? NSNumber
        check(mode?.intValue == 0o600 && empty.record()?.command == empty.command, "The install record is private")

        // Installing beside the user's own hooks
        let original = """
        {
          "hooks": {
            "Stop": [ { "hooks": [ { "type": "command", "command": "/usr/local/bin/notify-me" } ] } ],
            "PreToolUse": [ { "matcher": "Bash", "hooks": [ { "type": "command", "command": "/usr/local/bin/guard" } ] } ]
          },
          "model": "opus",
          "statusLine": { "type": "command", "command": "'/Users/someone/.claude/nocci-statusline.sh'", "padding": 0 }
        }
        """
        let populated = installer("populated", appPath: appPath)
        try write(original, populated)
        let populatedPlan = try populated.plan()
        check(populatedPlan.backupPath?.contains("claude-settings-before-hooks-") == true, "A backup is planned before the first change")
        _ = try populated.install()
        let merged = settings(populated)
        let stops = groups(merged, "Stop")
        check(stops.count == 2 && (stops[0]["hooks"] as? [[String: Any]])?.first?["command"] as? String == "/usr/local/bin/notify-me",
              "The user's own Stop hook stays first and untouched")
        check(groups(merged, "PreToolUse").count == 2 && merged["model"] as? String == "opus"
              && (merged["statusLine"] as? [String: Any])?["padding"] as? Int == 0, "Every other setting is preserved")
        let backupText = try String(contentsOfFile: populatedPlan.backupPath!, encoding: .utf8)
        check(backupText == original, "The backup is the original file, verbatim")
        _ = try populated.install()
        check(groups(settings(populated), "Stop").count == 2 && groups(settings(populated), "SessionEnd").count == 1,
              "Reinstalling never duplicates Nocci's hooks")
        let secondPlan = try populated.plan()
        check(secondPlan.backupPath == nil, "The backup is taken once")
        func folderMode(_ url: URL) -> Int {
            ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber)?.intValue ?? -1
        }
        check(folderMode(populated.paths.supportDirectory) == 0o700 && folderMode(populated.paths.backupDirectory) == 0o700,
              "Turning on creates Nocci's folders for the user only")
        let backups = populated.paths.backupDirectory
        let orphan = "claude-settings-before-hooks-2026-01-02-030405.json"
        let statusLineBackup = "claude-settings-2026-01-02-030405.json"
        for name in [orphan, statusLineBackup] { try Data("{}".utf8).write(to: backups.appendingPathComponent(name)) }
        try populated.uninstall()
        let remaining = Set(try FileManager.default.contentsOfDirectory(atPath: backups.path))
        check(remaining == [statusLineBackup],
              "Turning off deletes every hooks backup, older ones included, and keeps the status line's")
        let restored = settings(populated)
        let originalObject = try JSONSerialization.jsonObject(with: Data(original.utf8)) as! NSDictionary
        check(NSDictionary(dictionary: restored).isEqual(originalObject), "Turning off leaves the user's settings as they were")
        check(populated.status() == .off && !FileManager.default.fileExists(atPath: populated.recordFile.path),
              "Off after uninstalling; the record is gone")

        // A moved app
        let moved = installer("moved", appPath: appPath)
        _ = try moved.install()
        let newPath = try app("Elsewhere")
        let relocated = installer("moved", appPath: newPath)
        check(relocated.status() == .moved(installedCommand: moved.command), "Settings can tell that Nocci moved")
        _ = try relocated.install()
        let reinstalled = settings(relocated)
        check(groups(reinstalled, "Stop").count == 1
              && ((groups(reinstalled, "Stop")[0]["hooks"] as? [[String: Any]])?.first?["command"] as? String) == relocated.command,
              "Reinstalling from the new place replaces the old path's hooks")
        check(relocated.status() == .on, "On again after reinstalling")
        try relocated.uninstall()
        check((settings(relocated)["hooks"]) == nil, "Removing the last hooks removes the empty hooks object")

        // Hooks removed outside Nocci
        let outside = installer("outside", appPath: appPath)
        _ = try outside.install()
        try write(#"{"model":"opus"}"#, outside)
        check(outside.status() == .removedOutside, "Hooks removed by hand are noticed")
        try outside.uninstall()
        check(outside.status() == .off && settings(outside)["model"] as? String == "opus",
              "Turning off then only ends the integration")

        // A failed turn off keeps the backup
        let broken = installer("broken", appPath: appPath)
        try write(#"{"model":"opus"}"#, broken)
        let brokenBackup = try broken.plan().backupPath!
        _ = try broken.install()
        try write("{ not json", broken)
        check(failure { try broken.uninstall() } == .malformedSettings(path: broken.paths.settingsFile.path)
              && FileManager.default.fileExists(atPath: brokenBackup),
              "A turn off that cannot rewrite the settings keeps the backup")

        // Refusals change nothing
        for (name, text) in [("malformed", "{ not json"), ("comma", #"{"model":"opus",}"#),
                             ("hooksArray", #"{"hooks":[]}"#), ("eventObject", #"{"hooks":{"Stop":{"command":"x"}}}"#)] {
            let refused = installer(name, appPath: appPath)
            try write(text, refused)
            check(failure { try refused.install() } != nil && (try? String(contentsOf: refused.paths.settingsFile, encoding: .utf8)) == text
                  && !FileManager.default.fileExists(atPath: refused.recordFile.path),
                  "Refused without changes: \(name)")
        }
        let missingApp = installer("missingApp", appPath: root.appendingPathComponent("gone/Nocci").path)
        check(failure { try missingApp.plan() } == .appUnavailable(path: root.appendingPathComponent("gone/Nocci").path),
              "A missing app executable is refused")

        // Warnings
        let disabled = installer("disabled", appPath: appPath)
        try write(#"{"disableAllHooks":true}"#, disabled)
        let disabledPlan = try disabled.plan()
        check(disabledPlan.warnings == [.hooksDisabled(path: disabled.paths.settingsFile.path)],
              "disableAllHooks is reported")
        let managedFile = root.appendingPathComponent("managed.json")
        try Data(#"{"allowManagedHooksOnly":true}"#.utf8).write(to: managedFile)
        let managed = installer("managed", appPath: appPath, managed: managedFile.path)
        let managedPlan = try managed.plan()
        check(managedPlan.warnings == [.managedHooksOnly(path: managedFile.path)], "Managed-only hooks are reported")
        check(ClaudeHooksWarning.hooksDisabled(path: "/x").message.contains("won’t run")
              && !ClaudeHooksWarning.hooksDisabled(path: "/x").message.contains("status line"),
              "Warnings speak about session hooks, not the status line")

        // A linked settings file (dotfile managers) is written through, both ways.
        let linkedHooks = installer("linked", appPath: try app("linked"))
        let dotfile = root.appendingPathComponent("linked/dotfiles/settings.json")
        try FileManager.default.createDirectory(at: dotfile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"model\": \"opus\"}".utf8).write(to: dotfile)
        try FileManager.default.createDirectory(at: linkedHooks.paths.configDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linkedHooks.paths.settingsFile, withDestinationURL: dotfile)
        _ = try linkedHooks.install()
        let linkedObject = (try? JSONSerialization.jsonObject(with: Data(contentsOf: dotfile))) as? [String: Any] ?? [:]
        check((try? FileManager.default.destinationOfSymbolicLink(atPath: linkedHooks.paths.settingsFile.path)) == dotfile.path
              && !groups(linkedObject, "Stop").isEmpty, "Installing hooks writes through a linked settings file")
        try linkedHooks.uninstall()
        let unlinkedObject = (try? JSONSerialization.jsonObject(with: Data(contentsOf: dotfile))) as? [String: Any] ?? [:]
        check((try? FileManager.default.destinationOfSymbolicLink(atPath: linkedHooks.paths.settingsFile.path)) == dotfile.path
              && unlinkedObject["hooks"] == nil && unlinkedObject["model"] as? String == "opus",
              "Turning off writes through the link too")

        // A copy macOS runs from a temporary location is never written into settings.
        let translocated = installer("translocated", appPath: "/private/var/folders/x/T/AppTranslocation/A1/d/Nocci.app/Contents/MacOS/Nocci")
        check(failure { try translocated.plan() } == .temporaryLocation(path: translocated.appPath),
              "A translocated copy cannot install hooks")

        print("\(checks) claude-hook installer checks passed")
    }
}
