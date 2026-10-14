import Foundation

// Every case runs against a temporary configuration directory. No test reads or
// writes the developer's real ~/.claude settings, snapshot, or login registration.
@main
struct ClaudeIntegrationTests {
    static func main() {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            guard condition() else { fatalError("FAIL: \(label)") }
            checks += 1
        }
        let fm = FileManager.default
        let sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("notch-claude-tests-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: sandbox) }
        func makeCase(_ name: String) -> URL {
            let url = sandbox.appendingPathComponent(name)
            try! fm.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        func script(_ url: URL, _ body: String) -> String {
            try! fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try! body.write(to: url, atomically: true, encoding: .utf8)
            try! fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            return url.path
        }
        func read(_ url: URL) -> [String: Any] {
            let data = try! Data(contentsOf: url)
            return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        }
        func installer(_ root: URL, app: String, environment: [String: String] = [:]) -> ClaudeInstaller {
            var env = environment
            env["CLAUDE_CONFIG_DIR"] = env["CLAUDE_CONFIG_DIR"] ?? root.appendingPathComponent("config").path
            env["NOCCI_DATA_DIR"] = root.appendingPathComponent("support").path
            let paths = ClaudePaths.resolve(environment: env, home: root.appendingPathComponent("home"))
            return ClaudeInstaller(paths: paths, appPath: app, managedSettingsPath: root.appendingPathComponent("managed.json").path)
        }

        // MARK: Configuration locations

        let pathCase = makeCase("paths")
        let home = pathCase.appendingPathComponent("home")
        let defaults = ClaudePaths.resolve(environment: [:], home: home)
        check(defaults.settingsFile.path == home.appendingPathComponent(".claude/settings.json").path,
              "Default settings location is ~/.claude/settings.json")
        check(defaults.supportDirectory.path == home.appendingPathComponent("Library/Application Support/Nocci").path,
              "Default support directory")
        let custom = ClaudePaths.resolve(environment: ["CLAUDE_CONFIG_DIR": "~/somewhere else"], home: home)
        check(custom.settingsFile.path == home.appendingPathComponent("somewhere else/settings.json").path,
              "CLAUDE_CONFIG_DIR is honored and tilde-expanded")
        let absolute = ClaudePaths.resolve(environment: ["CLAUDE_CONFIG_DIR": "/opt/claude config"], home: home)
        check(absolute.wrapperFile.path == "/opt/claude config/nocci-statusline.sh",
              "Absolute CLAUDE_CONFIG_DIR is used verbatim")

        // MARK: Plan preview before any change

        let cleanCase = makeCase("clean")
        let appPath = script(cleanCase.appendingPathComponent("Nocci.app/Contents/MacOS/Nocci"), "#!/bin/bash\ncat >/dev/null\n")
        let clean = installer(cleanCase, app: appPath)
        let plan = try! clean.plan()
        check(plan.action == .install, "Clean configuration plans a fresh install")
        check(plan.preservedCommand == nil, "Nothing to preserve on a clean configuration")
        check(plan.backupPath == nil, "No backup is planned when no settings file exists")
        check(plan.settingsPath == clean.paths.settingsFile.path, "Plan names the settings file it will change")
        check(plan.settingsFragment.contains("\"statusLine\"") && plan.settingsFragment.contains("nocci-statusline.sh"),
              "Plan shows the exact statusLine entry")
        check(plan.wrapperScript.contains(appPath), "Planned wrapper references this app")
        check(!fm.fileExists(atPath: clean.paths.settingsFile.path), "Planning changes nothing on disk")

        // MARK: Installing into a clean configuration

        let record = try! clean.install()
        let settings = read(clean.paths.settingsFile)
        let statusLine = settings["statusLine"] as! [String: Any]
        check(statusLine["type"] as? String == "command", "Installs a command status line")
        check(statusLine["command"] as? String == "'\(clean.paths.wrapperFile.path)'",
              "Status line runs the quoted wrapper")
        check(fm.isExecutableFile(atPath: clean.paths.wrapperFile.path), "Wrapper is executable")
        check(record.previousCommand == nil, "No previous command recorded")
        check(record.appPath == appPath && record.wrapperPath == clean.paths.wrapperFile.path, "Record describes the install")
        check(fm.fileExists(atPath: clean.paths.recordFile.path), "Install record is written")

        // MARK: Unrelated settings survive the merge

        let mergeCase = makeCase("merge")
        let mergeApp = script(mergeCase.appendingPathComponent("app.sh"), "#!/bin/bash\ncat >/dev/null\n")
        let merge = installer(mergeCase, app: mergeApp)
        try! fm.createDirectory(at: merge.paths.configDirectory, withIntermediateDirectories: true)
        let original = """
        {
          "model": "opus",
          "permissions": { "allow": ["Bash(ls:*)"], "deny": [] },
          "env": { "FOO": "bar" },
          "statusLine": { "type": "command", "command": "jq -r .model.display_name", "padding": 2, "refreshInterval": 5 }
        }
        """
        try! original.write(to: merge.paths.settingsFile, atomically: true, encoding: .utf8)
        _ = try! merge.install()
        let merged = read(merge.paths.settingsFile)
        check(merged["model"] as? String == "opus", "Unrelated top-level settings are preserved")
        check(((merged["permissions"] as? [String: Any])?["allow"] as? [String])?.first == "Bash(ls:*)",
              "Nested settings are preserved")
        check((merged["env"] as? [String: String])?["FOO"] == "bar", "Environment settings are preserved")
        let mergedStatus = merged["statusLine"] as! [String: Any]
        check(mergedStatus["padding"] as? Int == 2 && mergedStatus["refreshInterval"] as? Int == 5,
              "Existing statusLine options are preserved")
        check(merge.record()?.addedRefreshInterval == false,
              "A refresh interval the user already set is not claimed by this app")
        check(mergedStatus["command"] as? String == "'\(merge.paths.wrapperFile.path)'", "Only the command changes")

        // MARK: Chaining an existing status line

        func run(_ path: String, input: String) -> (output: String, status: Int32) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [path]
            let stdin = Pipe(), stdout = Pipe()
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = FileHandle.nullDevice
            try! process.run()
            stdin.fileHandleForWriting.write(Data(input.utf8))
            try! stdin.fileHandleForWriting.close()
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (String(data: data, encoding: .utf8) ?? "", process.terminationStatus)
        }

        let chainCase = makeCase("chain")
        let received = chainCase.appendingPathComponent("received.json")
        let ranDuringInstall = chainCase.appendingPathComponent("previous-ran-during-install")
        // Both fixture paths contain a space and an apostrophe on purpose.
        let chainApp = script(chainCase.appendingPathComponent("Someone's Nocci.app/Contents/MacOS/Nocci"),
                              "#!/bin/bash\ncat > \(ShellCommand.quote(received.path))\necho 'notch summary'\n")
        let previousScript = script(chainCase.appendingPathComponent("my status'line.sh"),
                                    "#!/bin/bash\ntouch \(ShellCommand.quote(ranDuringInstall.path))\necho \"PREV:$(cat)\"\n")
        let previousCommand = ShellCommand.quote(previousScript) + " --flag"
        let chain = installer(chainCase, app: chainApp)
        try! fm.createDirectory(at: chain.paths.configDirectory, withIntermediateDirectories: true)
        let chainSettingsText = "{\"statusLine\": {\"type\": \"command\", \"command\": \(JSONEncodedString(previousCommand))}}"
        try! chainSettingsText.write(to: chain.paths.settingsFile, atomically: true, encoding: .utf8)
        let chainPlan = try! chain.plan()
        check(chainPlan.preservedCommand == previousCommand, "Plan shows the command it will preserve")
        let chainRecord = try! chain.install()
        check(chainRecord.previousCommand == previousCommand, "The previous command is recorded verbatim")
        check(!fm.fileExists(atPath: ranDuringInstall.path), "Installation never executes the existing command")

        let payload = "{\"rate_limits\":{\"five_hour\":{\"used_percentage\":12.5}}}"
        let result = run(chain.paths.wrapperFile.path, input: payload)
        check(result.output == "PREV:\(payload)\n", "The preserved status line still produces the visible output")
        check(!result.output.contains("notch summary"), "Our own output does not replace the preserved status line")
        check((try? String(contentsOf: received, encoding: .utf8)) == payload,
              "The bridge receives the unmodified payload through a path containing a space and a quote")
        check(result.status == 0, "Wrapper exits cleanly")

        // MARK: A wrapper without a previous command prints our own summary

        let soloResult = run(clean.paths.wrapperFile.path, input: payload)
        check(soloResult.status == 0, "Solo wrapper exits cleanly")

        // MARK: Our own commands are never chained into themselves

        func preserved(_ existing: String, name: String, environment: [String: String] = [:]) -> String? {
            let root = makeCase(name)
            let app = script(root.appendingPathComponent("app.sh"), "#!/bin/bash\ncat >/dev/null\n")
            let target = installer(root, app: app, environment: environment)
            try! fm.createDirectory(at: target.paths.configDirectory, withIntermediateDirectories: true)
            try! "{\"statusLine\": {\"type\": \"command\", \"command\": \(JSONEncodedString(existing))}}"
                .write(to: target.paths.settingsFile, atomically: true, encoding: .utf8)
            return try! target.plan().preservedCommand
        }
        check(preserved("'/Applications/Nocci.app/Contents/MacOS/Nocci' --claude-statusline",
                        name: "legacy") == nil,
              "A legacy direct install is recognized as ours, not chained")
        check(preserved("'/Users/someone/.claude/nocci-statusline.sh'", name: "old-wrapper") == nil,
              "A Nocci wrapper at another path is recognized as ours")
        let compound = "'/Applications/Nocci.app/Contents/MacOS/Nocci' --claude-statusline; /usr/local/bin/mine"
        check(preserved(compound, name: "compound") == compound,
              "A compound command mentioning our flag is preserved rather than assumed to be ours")

        // MARK: A user's own wrapper script is preserved

        let userWrapperCase = makeCase("user-wrapper")
        let userWrapper = script(userWrapperCase.appendingPathComponent("their wrapper.sh"),
                                 "#!/bin/bash\npayload=$(cat)\nprintf '%s' \"$payload\" | /some/app --claude-statusline\n")
        let userApp = script(userWrapperCase.appendingPathComponent("app.sh"), "#!/bin/bash\ncat >/dev/null\n")
        let userCase = installer(userWrapperCase, app: userApp)
        try! fm.createDirectory(at: userCase.paths.configDirectory, withIntermediateDirectories: true)
        try! "{\"statusLine\": {\"type\": \"command\", \"command\": \(JSONEncodedString(ShellCommand.quote(userWrapper)))}}"
            .write(to: userCase.paths.settingsFile, atomically: true, encoding: .utf8)
        check(try! userCase.plan().preservedCommand == ShellCommand.quote(userWrapper),
              "A user's own wrapper script is preserved even though it calls our bridge flag")

        // MARK: Repeated setup is idempotent

        let repeatPlan = try! chain.plan()
        check(repeatPlan.action == .upToDate, "A complete install needs no further change")
        check(repeatPlan.backupPath == nil, "A second setup plans no new backup")
        let firstScript = try! String(contentsOf: chain.paths.wrapperFile, encoding: .utf8)
        let firstBackup = chainRecord.backupPath!
        let backupContents = try! String(contentsOf: URL(fileURLWithPath: firstBackup), encoding: .utf8)
        check(backupContents == chainSettingsText, "The backup holds the exact settings from before the first install")
        let secondRecord = try! chain.install()
        check(try! String(contentsOf: chain.paths.wrapperFile, encoding: .utf8) == firstScript,
              "Repeated setup rewrites the same wrapper")
        check(secondRecord.previousCommand == previousCommand, "Repeated setup keeps the original preserved command")
        check(secondRecord.backupPath == firstBackup, "Repeated setup keeps the original backup")
        check(secondRecord.installedAt == chainRecord.installedAt, "The original install date is kept")
        check(try! String(contentsOf: URL(fileURLWithPath: firstBackup), encoding: .utf8) == backupContents,
              "The original backup is never overwritten")
        check(try! fm.contentsOfDirectory(atPath: chain.paths.backupDirectory.path).count == 1,
              "Only one backup is kept for one integration")
        let repeated = run(chain.paths.wrapperFile.path, input: payload)
        check(repeated.output == "PREV:\(payload)\n", "Repeated setup does not nest the preserved status line")

        // MARK: Repairing after the app moves

        let movedApp = script(chainCase.appendingPathComponent("Moved Usage.app/Contents/MacOS/Nocci"),
                              "#!/bin/bash\ncat > \(ShellCommand.quote(received.path))\n")
        let moved = ClaudeInstaller(paths: chain.paths, appPath: movedApp)
        check(try! moved.plan().action == .repair, "A moved app is a repair, not a fresh install")
        check(try! moved.plan().preservedCommand == previousCommand, "Repair still preserves the original command")
        let movedRecord = try! moved.install()
        check(try! String(contentsOf: chain.paths.wrapperFile, encoding: .utf8).contains(movedApp),
              "Repair points the wrapper at the moved app")
        check(movedRecord.backupPath == firstBackup && movedRecord.previousCommand == previousCommand,
              "Repair keeps the original backup and preserved command")
        check(run(chain.paths.wrapperFile.path, input: payload).output == "PREV:\(payload)\n",
              "The preserved status line still works after a repair")

        // MARK: Repairing a deleted wrapper

        try! fm.removeItem(at: chain.paths.wrapperFile)
        check(try! moved.plan().action == .repair, "A missing wrapper needs repair")
        _ = try! moved.install()
        check(fm.isExecutableFile(atPath: chain.paths.wrapperFile.path), "Repair restores the wrapper")

        // MARK: Disconnect restores the previous status line

        func prepared(_ name: String, existing: String?, extra: String = "") -> ClaudeInstaller {
            let root = makeCase(name)
            let app = script(root.appendingPathComponent("app.sh"), "#!/bin/bash\ncat >/dev/null\n")
            let target = installer(root, app: app)
            try! fm.createDirectory(at: target.paths.configDirectory, withIntermediateDirectories: true)
            var object = "{\"model\": \"opus\"\(extra)"
            if let existing {
                object += ", \"statusLine\": {\"type\": \"command\", \"command\": \(JSONEncodedString(existing)), \"padding\": 3}"
            }
            object += "}"
            try! object.write(to: target.paths.settingsFile, atomically: true, encoding: .utf8)
            _ = try! target.install()
            return target
        }

        let restoreCase = prepared("restore", existing: "/usr/local/bin/mine --flag")
        let restorePreview = try! restoreCase.disconnectPlan()
        check(restorePreview.restoresCommand == "/usr/local/bin/mine --flag", "Disconnect preview names the command it restores")
        check(restorePreview.conflictingCommand == nil, "An untouched install has no conflict")
        let restoreOutcome = try! restoreCase.disconnect(.restore)
        let restored = read(restoreCase.paths.settingsFile)
        check((restored["statusLine"] as? [String: Any])?["command"] as? String == "/usr/local/bin/mine --flag",
              "Disconnect restores the previous command")
        check((restored["statusLine"] as? [String: Any])?["padding"] as? Int == 3, "Disconnect keeps other status-line options")
        check(restored["model"] as? String == "opus", "Disconnect preserves unrelated settings")
        check(!fm.fileExists(atPath: restoreCase.paths.wrapperFile.path), "Disconnect removes the wrapper")
        check(restoreCase.record() == nil, "Disconnect clears the install record")
        check(restoreOutcome.restoredCommand == "/usr/local/bin/mine --flag" && !restoreOutcome.removedStatusLine,
              "Outcome reports the restored command")

        // MARK: Disconnect removes a status line it introduced

        let removeCase = prepared("remove", existing: nil)
        let removeOutcome = try! removeCase.disconnect(.restore)
        let removedSettings = read(removeCase.paths.settingsFile)
        check(removedSettings["statusLine"] == nil, "Disconnect removes a status line we introduced")
        check(removedSettings["model"] as? String == "opus", "Removal preserves unrelated settings")
        check(removeOutcome.removedStatusLine && removeOutcome.restoredCommand == nil, "Outcome reports the removal")

        // MARK: Settings changed after installation are preserved

        let laterCase = prepared("later", existing: "mine")
        var laterSettings = read(laterCase.paths.settingsFile)
        laterSettings["cleanupPeriodDays"] = 90
        try! JSONSerialization.data(withJSONObject: laterSettings, options: [.prettyPrinted])
            .write(to: laterCase.paths.settingsFile, options: .atomic)
        _ = try! laterCase.disconnect(.restore)
        check(read(laterCase.paths.settingsFile)["cleanupPeriodDays"] as? Int == 90,
              "Settings added after installation survive disconnect")

        // MARK: A status line replaced after installation is a conflict

        func replaceStatusLine(_ target: ClaudeInstaller, with command: String) {
            var object = read(target.paths.settingsFile)
            object["statusLine"] = ["type": "command", "command": command]
            try! JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted])
                .write(to: target.paths.settingsFile, options: .atomic)
        }
        let conflictCase = prepared("conflict", existing: "mine")
        replaceStatusLine(conflictCase, with: "/opt/other-statusline.sh")
        let conflictPreview = try! conflictCase.disconnectPlan()
        check(conflictPreview.conflictingCommand == "/opt/other-statusline.sh", "A replaced status line is reported as a conflict")
        var threw: ClaudeIntegrationError?
        do { _ = try conflictCase.disconnect(.restore) } catch let error as ClaudeIntegrationError { threw = error } catch {}
        check(threw == .conflictingStatusLine(current: "/opt/other-statusline.sh", installed: conflictCase.installedCommand),
              "Disconnect refuses to overwrite a status line changed since installation")
        check((read(conflictCase.paths.settingsFile)["statusLine"] as? [String: Any])?["command"] as? String == "/opt/other-statusline.sh",
              "The conflicting status line is left untouched")
        check(conflictCase.record() != nil && fm.fileExists(atPath: conflictCase.paths.wrapperFile.path),
              "A refused disconnect changes nothing")

        let keepOutcome = try! conflictCase.disconnect(.keepCurrentCommand)
        check((read(conflictCase.paths.settingsFile)["statusLine"] as? [String: Any])?["command"] as? String == "/opt/other-statusline.sh",
              "Keeping the current status line leaves the settings file alone")
        check(conflictCase.record() == nil, "Keeping the current status line still ends the integration")
        check(keepOutcome.keptCurrentCommand && keepOutcome.remainingWrapperPath == conflictCase.paths.wrapperFile.path,
              "The unreferenced wrapper is reported rather than deleted")
        var secondThrew: ClaudeIntegrationError?
        do { _ = try conflictCase.disconnect(.restore) } catch let error as ClaudeIntegrationError { secondThrew = error } catch {}
        check(secondThrew == .notInstalled, "Disconnecting twice reports that nothing is installed")

        let overrideCase = prepared("override", existing: "mine")
        replaceStatusLine(overrideCase, with: "/opt/other-statusline.sh")
        _ = try! overrideCase.disconnect(.restoreOverridingConflict)
        check((read(overrideCase.paths.settingsFile)["statusLine"] as? [String: Any])?["command"] as? String == "mine",
              "An explicit override restores the backed-up command")
        check(!fm.fileExists(atPath: overrideCase.paths.wrapperFile.path), "The override removes the wrapper")

        // MARK: Failing safely

        func failing(_ name: String, settings: String, app: String? = nil) -> (ClaudeInstaller, ClaudeIntegrationError?) {
            let root = makeCase(name)
            let appPath = app ?? script(root.appendingPathComponent("app.sh"), "#!/bin/bash\ncat >/dev/null\n")
            let target = installer(root, app: appPath)
            try! fm.createDirectory(at: target.paths.configDirectory, withIntermediateDirectories: true)
            try! settings.write(to: target.paths.settingsFile, atomically: true, encoding: .utf8)
            do { _ = try target.install(); return (target, nil) }
            catch let error as ClaudeIntegrationError { return (target, error) }
            catch { return (target, nil) }
        }

        let (malformed, malformedError) = failing("malformed", settings: "{\n  \"model\": \"opus\",\n}")
        check(malformedError == .malformedSettings(path: malformed.paths.settingsFile.path),
              "A settings file that isn’t valid JSON fails before any change")
        check(!fm.fileExists(atPath: malformed.paths.wrapperFile.path) && malformed.record() == nil,
              "A malformed settings file leaves nothing behind")
        check(try! String(contentsOf: malformed.paths.settingsFile, encoding: .utf8).contains("\"model\": \"opus\","),
              "A malformed settings file is left exactly as it was")

        let (unsupported, unsupportedError) = failing("unsupported",
                                                      settings: "{\"statusLine\": {\"type\": \"static\", \"value\": \"hi\"}}")
        check(unsupportedError == .unsupportedStatusLine(path: unsupported.paths.settingsFile.path,
                                                         detail: "statusLine type “static” isn’t a command"),
              "An unsupported status-line type is refused")
        check(!fm.fileExists(atPath: unsupported.paths.wrapperFile.path), "An unsupported status line leaves nothing behind")

        let (plainString, plainStringError) = failing("plain-string", settings: "{\"statusLine\": \"my-script.sh\"}")
        check(plainStringError == .unsupportedStatusLine(path: plainString.paths.settingsFile.path,
                                                         detail: "statusLine is not an object"),
              "A status line that is not an object is refused")

        let missingCase = makeCase("missing-app")
        let missingApp = missingCase.appendingPathComponent("Gone.app/Contents/MacOS/Nocci").path
        let missing = installer(missingCase, app: missingApp)
        var missingError: ClaudeIntegrationError?
        do { _ = try missing.install() } catch let error as ClaudeIntegrationError { missingError = error } catch {}
        check(missingError == .appUnavailable(path: missingApp), "A missing app executable is refused")
        check(!fm.fileExists(atPath: missing.paths.settingsFile.path), "A missing app executable writes nothing")

        let readOnlyCase = makeCase("read-only")
        let readOnlyApp = script(readOnlyCase.appendingPathComponent("app.sh"), "#!/bin/bash\ncat >/dev/null\n")
        let readOnly = installer(readOnlyCase, app: readOnlyApp)
        try! fm.createDirectory(at: readOnly.paths.configDirectory, withIntermediateDirectories: true)
        try! "{\"model\": \"opus\"}".write(to: readOnly.paths.settingsFile, atomically: true, encoding: .utf8)
        try! fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: readOnly.paths.configDirectory.path)
        var readOnlyError: ClaudeIntegrationError?
        do { _ = try readOnly.install() } catch let error as ClaudeIntegrationError { readOnlyError = error } catch {}
        if case .writeFailed = readOnlyError { checks += 1 } else { fatalError("FAIL: A read-only configuration directory reports a write failure") }
        check(readOnly.record() == nil, "A failed write leaves no install record")
        check(try! String(contentsOf: readOnly.paths.settingsFile, encoding: .utf8) == "{\"model\": \"opus\"}",
              "A failed write leaves the settings file untouched")
        check((try? fm.contentsOfDirectory(atPath: readOnly.paths.backupDirectory.path))?.isEmpty ?? true,
              "A failed write leaves no stray backup")
        try! fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: readOnly.paths.configDirectory.path)

        let (empty, emptyError) = failing("empty-settings", settings: "")
        check(emptyError == nil && fm.fileExists(atPath: empty.paths.wrapperFile.path),
              "An empty settings file is treated as empty settings")

        // MARK: Connection state is separate from configuration

        let stateCase = prepared("state", existing: nil)
        let installedAt = stateCase.record()!.installedAt
        check(stateCase.connection(snapshot: ClaudeSnapshotInfo(updated: nil, hasWindows: false)) == .waiting,
              "Installing configuration alone is not a live connection")
        check(stateCase.connection(snapshot: ClaudeSnapshotInfo(updated: installedAt.addingTimeInterval(-3600), hasWindows: true)) == .waiting,
              "A snapshot from before setup does not prove the connection works")
        check(stateCase.connection(snapshot: ClaudeSnapshotInfo(updated: installedAt.addingTimeInterval(30), hasWindows: false)) == .connectedWithoutLimits,
              "An event without rate limits proves the bridge, not the allowance")
        check(stateCase.connection(snapshot: ClaudeSnapshotInfo(updated: installedAt.addingTimeInterval(30), hasWindows: true)) == .receiving,
              "Usage arriving after setup is a live connection")

        var agedCase = stateCase
        let reading = ClaudeSnapshotInfo(updated: installedAt, hasWindows: true)
        agedCase.now = { installedAt.addingTimeInterval(299) }
        check(agedCase.connection(snapshot: reading) == .receiving, "Recent reading remains live before the cutoff")
        agedCase.now = { installedAt.addingTimeInterval(300) }
        check(agedCase.connection(snapshot: reading) == .stale, "Five-minute-old reading must not claim receiving usage")
        agedCase.now = { installedAt.addingTimeInterval(7200) }
        check(agedCase.connection(snapshot: ClaudeSnapshotInfo(updated: installedAt, hasWindows: true,
                                                              lastEvent: installedAt.addingTimeInterval(7200))) == .stale,
              "Fresh bridge event cannot freshen an old quota reading")
        check(agedCase.connection(snapshot: ClaudeSnapshotInfo(updated: installedAt.addingTimeInterval(7200), hasWindows: true)) == .receiving,
              "New quota reading restores live connection")

        // A bridge run proves the integration works even when the reading it
        // carried forward predates setup.
        check(stateCase.connection(snapshot: ClaudeSnapshotInfo(updated: installedAt.addingTimeInterval(-3600),
                                                                hasWindows: true,
                                                                lastEvent: installedAt.addingTimeInterval(30))) == .connectedWithoutLimits,
              "An event after setup carrying an older reading proves the bridge, not fresh usage")
        check(stateCase.connection(snapshot: ClaudeSnapshotInfo(updated: installedAt.addingTimeInterval(-3600),
                                                                hasWindows: true,
                                                                lastEvent: installedAt.addingTimeInterval(-60))) == .waiting,
              "An event from before setup still counts as waiting")

        let freshCase = makeCase("not-configured")
        let freshApp = script(freshCase.appendingPathComponent("app.sh"), "#!/bin/bash\ncat >/dev/null\n")
        let fresh = installer(freshCase, app: freshApp)
        check(fresh.connection(snapshot: ClaudeSnapshotInfo(updated: Date(), hasWindows: true)) == .notConfigured,
              "An old snapshot without configuration is not a connection")

        let conflictStateCase = prepared("conflict-state", existing: "mine")
        replaceStatusLine(conflictStateCase, with: "/opt/other.sh")
        check(conflictStateCase.connection(snapshot: ClaudeSnapshotInfo(updated: Date(), hasWindows: true)) == .conflict(current: "/opt/other.sh"),
              "A replaced status line is reported as a conflict, not a connection")

        let brokenStateCase = prepared("broken-state", existing: nil)
        try! "{oops".write(to: brokenStateCase.paths.settingsFile, atomically: true, encoding: .utf8)
        if case .unavailable = brokenStateCase.connection(snapshot: ClaudeSnapshotInfo(updated: nil, hasWindows: false)) { checks += 1 }
        else { fatalError("FAIL: A malformed settings file is reported instead of a connection") }

        // MARK: Warnings the user needs before enabling

        let chainWarnings = try! chain.plan().warnings
        check(chainWarnings.contains(.projectOverride),
              "Every plan explains that project settings take precedence over user settings")
        let warnCase = makeCase("warnings")
        let warnApp = script(warnCase.appendingPathComponent("app.sh"), "#!/bin/bash\ncat >/dev/null\n")
        let warn = installer(warnCase, app: warnApp)
        try! fm.createDirectory(at: warn.paths.configDirectory, withIntermediateDirectories: true)
        try! "{\"disableAllHooks\": true}".write(to: warn.paths.settingsFile, atomically: true, encoding: .utf8)
        let managed = warnCase.appendingPathComponent("managed.json")
        try! "{\"allowManagedHooksOnly\": true}".write(to: managed, atomically: true, encoding: .utf8)
        let warnings = try! warn.plan().warnings
        check(warnings.contains(.hooksDisabled(path: warn.paths.settingsFile.path)),
              "disableAllHooks is reported, because it stops the status line running")
        check(warnings.contains(.managedHooksOnly(path: managed.path)),
              "Managed settings that allow only managed hooks are reported")
        check(try! chain.plan().warnings.contains(.existingStatusLine(command: previousCommand)),
              "The plan warns that an existing status line will be wrapped")
        check(warnings.allSatisfy { !$0.message.isEmpty }, "Every warning has a message for the user")

        // MARK: Strict JSON matches Claude Code's own rules

        check(StrictJSON.hasTrailingComma("{\"a\": 1,}"), "A trailing comma in an object is rejected")
        check(StrictJSON.hasTrailingComma("{\"a\": [1, 2, ]}"), "A trailing comma in an array is rejected")
        check(!StrictJSON.hasTrailingComma("{\"a\": 1, \"b\": 2}"), "Ordinary commas are accepted")
        check(!StrictJSON.hasTrailingComma("{\"a\": \"value,}\"}"), "A comma inside a string is not a trailing comma")
        check(!StrictJSON.hasTrailingComma("{\"a\": \"he said \\\"hi\\\",}\"}"), "An escaped quote does not confuse the scanner")

        // MARK: End to end through the real application binary
        //
        // This is the closest automated substitute for a live Claude Code
        // session: the generated wrapper feeds a real status-line payload to the
        // built app and still prints the preserved status line.

        let binary = URL(fileURLWithPath: fm.currentDirectoryPath)
            .deletingLastPathComponent().appendingPathComponent("Nocci.app/Contents/MacOS/Nocci").path
        if fm.isExecutableFile(atPath: binary) {
            let liveCase = makeCase("end-to-end")
            let dataDirectory = liveCase.appendingPathComponent("data")
            let previous = script(liveCase.appendingPathComponent("their status'line.sh"), "#!/bin/bash\ncat >/dev/null\necho 'main ~/work'\n")
            let live = installer(liveCase, app: binary)
            try! fm.createDirectory(at: live.paths.configDirectory, withIntermediateDirectories: true)
            try! "{\"statusLine\": {\"type\": \"command\", \"command\": \(JSONEncodedString(ShellCommand.quote(previous)))}}"
                .write(to: live.paths.settingsFile, atomically: true, encoding: .utf8)
            _ = try! live.install()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [live.paths.wrapperFile.path]
            process.environment = ["NOCCI_DATA_DIR": dataDirectory.path, "PATH": "/usr/bin:/bin"]
            let stdin = Pipe(), stdout = Pipe()
            process.standardInput = stdin
            process.standardOutput = stdout
            try! process.run()
            let sessionPayload = """
            {"session_id":"PRIVATE","transcript_path":"PRIVATE","cwd":"PRIVATE",\
            "rate_limits":{"five_hour":{"used_percentage":23.5,"resets_at":2000000000},\
            "seven_day":{"used_percentage":41.2,"resets_at":2000600000}}}
            """
            stdin.fileHandleForWriting.write(Data(sessionPayload.utf8))
            try! stdin.fileHandleForWriting.close()
            let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            process.waitUntilExit()
            check(output == "main ~/work\n", "The real bridge leaves the preserved status line as the visible output")
            let snapshotText = try! String(contentsOf: dataDirectory.appendingPathComponent("claude.json"), encoding: .utf8)
            check(snapshotText.contains("23.5") && snapshotText.contains("41.2"),
                  "The real bridge stores both usage windows")
            check(!snapshotText.contains("PRIVATE"), "The real bridge stores no session identifiers or paths")
            let stored = try! JSONSerialization.jsonObject(with: Data(snapshotText.utf8)) as! [String: Any]
            let windows = stored["windows"] as! [[String: Any]]
            let snapshotInfo = ClaudeSnapshotInfo(updated: Date(), hasWindows: !windows.isEmpty)
            check(live.connection(snapshot: snapshotInfo) == .receiving,
                  "Usage arriving through the real bridge reports a live connection")
            _ = try! live.disconnect(.restore)
            check((read(live.paths.settingsFile)["statusLine"] as? [String: Any])?["command"] as? String == ShellCommand.quote(previous),
                  "Disconnecting restores the real configuration")
        } else {
            print("note: end-to-end bridge check skipped; run ./build.sh first")
        }

        // MARK: Written JSON reads the way the user's file does

        check(!(try! String(contentsOf: clean.paths.settingsFile, encoding: .utf8)).contains("\\/"),
              "Paths are written without escaped slashes")
        check(!(try! clean.plan().settingsFragment).contains("\\/"),
              "The previewed configuration shows readable paths")

        check((try! String(contentsOf: clean.paths.settingsFile, encoding: .utf8)).hasSuffix("}\n"),
              "The settings file keeps a trailing newline")

        check(!(try! String(contentsOf: clean.paths.recordFile, encoding: .utf8)).contains("\\/"),
              "The install record shows readable paths")

        // MARK: Refresh interval
        //
        // Status-line events can be 10-15 minutes apart in some Claude Code
        // clients. refreshInterval re-runs the command on a timer as well.

        check((read(clean.paths.settingsFile)["statusLine"] as? [String: Any])?["refreshInterval"] as? Int == 60,
              "A fresh install asks Claude Code to re-run the bridge every 60 seconds")
        check(clean.record()?.addedRefreshInterval == true, "The record notes that we added the refresh interval")
        check(try! clean.plan().addsRefreshInterval, "The plan says the refresh interval is ours to add")
        check(try! clean.plan().settingsFragment.contains("refreshInterval"), "The preview shows the refresh interval")

        let intervalRepeat = try! clean.install()
        check(intervalRepeat.addedRefreshInterval == true, "Repeated setup keeps ownership of the refresh interval")
        check(try! clean.plan().action == .upToDate, "An install with the refresh interval is up to date")

        // An install made before this app wrote refresh intervals needs updating.
        let upgradeCase = prepared("upgrade", existing: "mine")
        var upgraded = read(upgradeCase.paths.settingsFile)
        var upgradedLine = upgraded["statusLine"] as! [String: Any]
        upgradedLine["refreshInterval"] = nil
        upgraded["statusLine"] = upgradedLine
        try! JSONSerialization.data(withJSONObject: upgraded, options: [.prettyPrinted])
            .write(to: upgradeCase.paths.settingsFile, options: .atomic)
        check(try! upgradeCase.plan().action == .repair, "An older install without a refresh interval offers an update")

        // MARK: Disconnect only removes a refresh interval it added

        let ownedCase = prepared("interval-owned", existing: "mine")
        _ = try! ownedCase.disconnect(.restore)
        let ownedSettings = read(ownedCase.paths.settingsFile)["statusLine"] as! [String: Any]
        check(ownedSettings["command"] as? String == "mine", "Disconnect restores the previous command")
        check(ownedSettings["refreshInterval"] == nil, "Disconnect removes the refresh interval it added")
        check(ownedSettings["padding"] as? Int == 3, "Disconnect keeps options it did not add")

        let theirsCase = prepared("interval-theirs", existing: "mine", extra: "")
        var theirs = read(theirsCase.paths.settingsFile)
        var theirsLine = theirs["statusLine"] as! [String: Any]
        theirsLine["refreshInterval"] = 30
        theirs["statusLine"] = theirsLine
        try! JSONSerialization.data(withJSONObject: theirs, options: [.prettyPrinted])
            .write(to: theirsCase.paths.settingsFile, options: .atomic)
        _ = try! theirsCase.disconnect(.restore)
        check((read(theirsCase.paths.settingsFile)["statusLine"] as? [String: Any])?["refreshInterval"] as? Int == 30,
              "A refresh interval changed after setup is left alone")

        // MARK: Disconnect deletes Nocci's copies of the settings file

        func backups(_ target: ClaudeInstaller) -> Set<String> {
            Set((try? fm.contentsOfDirectory(atPath: target.paths.backupDirectory.path)) ?? [])
        }
        let cleanupCase = prepared("backup-cleanup", existing: "mine")
        let recordedBackup = URL(fileURLWithPath: cleanupCase.record()!.backupPath!).lastPathComponent
        let orphan = "claude-settings-2026-01-02-030405.json"
        let hooksBackup = "claude-settings-before-hooks-2026-01-02-030405.json"
        for name in [orphan, hooksBackup, "notes.txt"] {
            try! Data("{}".utf8).write(to: cleanupCase.paths.backupDirectory.appendingPathComponent(name))
        }
        check(backups(cleanupCase) == [recordedBackup, orphan, hooksBackup, "notes.txt"], "The backup exists while installed")
        _ = try! cleanupCase.disconnect(.restore)
        check(backups(cleanupCase) == [hooksBackup, "notes.txt"],
              "Disconnect deletes every status-line backup, older ones included, and nothing else")

        let keptCase = prepared("backup-conflict", existing: "mine")
        replaceStatusLine(keptCase, with: "/opt/other-statusline.sh")
        _ = try? keptCase.disconnect(.restore)
        check(backups(keptCase).count == 1, "A refused disconnect keeps the backup")
        _ = try! keptCase.disconnect(.keepCurrentCommand)
        check(backups(keptCase).isEmpty, "Keeping the current status line still ends the integration and deletes the backup")

        // MARK: Nocci's own folders are readable only by the user

        func mode(_ url: URL) -> Int {
            ((try? fm.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber)?.intValue ?? -1
        }
        check(mode(clean.paths.supportDirectory) == 0o700, "Setup creates the support folder for the user only")
        check(mode(merge.paths.backupDirectory) == 0o700, "Setup creates the backups folder for the user only")
        let widenedCase = makeCase("widened")
        let widened = installer(widenedCase, app: script(widenedCase.appendingPathComponent("app.sh"), "#!/bin/bash\ncat >/dev/null\n"))
        for folder in [widened.paths.configDirectory, widened.paths.backupDirectory] {
            try! fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        for folder in [widened.paths.configDirectory, widened.paths.supportDirectory, widened.paths.backupDirectory] {
            try! fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        }
        try! "{}".write(to: widened.paths.settingsFile, atomically: true, encoding: .utf8)
        _ = try! widened.install()
        check(mode(widened.paths.supportDirectory) == 0o700 && mode(widened.paths.backupDirectory) == 0o700,
              "Setup tightens support and backups folders an earlier version left open")
        check(mode(widened.paths.configDirectory) == 0o755, "Claude's own configuration folder is left as it is")

        let earlier = ClaudePaths(configDirectory: widenedCase.appendingPathComponent("unused"),
                                  supportDirectory: widenedCase.appendingPathComponent("earlier"))
        try! fm.createDirectory(at: earlier.backupDirectory, withIntermediateDirectories: true)
        for folder in [earlier.supportDirectory, earlier.backupDirectory] {
            try! fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        }
        try! earlier.secureOwnFolders()
        check(mode(earlier.supportDirectory) == 0o700 && mode(earlier.backupDirectory) == 0o700,
              "Existing support and backups folders are tightened at launch")
        let absent = ClaudePaths(configDirectory: widenedCase.appendingPathComponent("unused"),
                                 supportDirectory: widenedCase.appendingPathComponent("absent"))
        try! absent.secureOwnFolders()
        check(!fm.fileExists(atPath: absent.supportDirectory.path), "Tightening never creates a folder")

        // MARK: The bridge script is for the user only

        check(mode(clean.paths.wrapperFile) == 0o700 && fm.isExecutableFile(atPath: clean.paths.wrapperFile.path),
              "The bridge script can be run and read by the user only")
        try! fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: chain.paths.wrapperFile.path)
        check(try! moved.plan().action == .repair, "A bridge script others can read needs repair")
        _ = try! moved.install()
        check(mode(chain.paths.wrapperFile) == 0o700 && (try! moved.plan().action) == .upToDate,
              "Repair makes the bridge script private again")

        // MARK: A settings file that is a symbolic link stays one

        let linkCase = makeCase("linked-settings")
        let linked = installer(linkCase, app: script(linkCase.appendingPathComponent("app.sh"), "#!/bin/bash\ncat >/dev/null\n"))
        let dotfiles = linkCase.appendingPathComponent("dotfiles/claude-settings.json")
        try! fm.createDirectory(at: dotfiles.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! "{\"model\": \"opus\"}".write(to: dotfiles, atomically: true, encoding: .utf8)
        try! fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dotfiles.path)
        try! fm.createDirectory(at: linked.paths.configDirectory, withIntermediateDirectories: true)
        try! fm.createSymbolicLink(at: linked.paths.settingsFile, withDestinationURL: dotfiles)
        _ = try! linked.install()
        check((try? fm.destinationOfSymbolicLink(atPath: linked.paths.settingsFile.path)) == dotfiles.path,
              "Setup writes through a linked settings file instead of replacing the link")
        check(read(dotfiles)["statusLine"] != nil && read(dotfiles)["model"] as? String == "opus",
              "The linked file itself receives the change")
        check(mode(dotfiles) == 0o600, "The linked file keeps its own permissions")
        _ = try! linked.disconnect(.restore)
        check((try? fm.destinationOfSymbolicLink(atPath: linked.paths.settingsFile.path)) == dotfiles.path
              && read(dotfiles)["statusLine"] == nil, "Disconnect writes through the link too")

        // MARK: A preserved command that runs the bridge again cannot loop

        let loopCase = makeCase("loop")
        let calls = loopCase.appendingPathComponent("calls")
        let loopApp = script(loopCase.appendingPathComponent("app.sh"),
                             "#!/bin/bash\ncat >/dev/null\necho x >> \(ShellCommand.quote(calls.path))\n")
        let looping = installer(loopCase, app: loopApp)
        try! fm.createDirectory(at: looping.paths.configDirectory, withIntermediateDirectories: true)
        // Bounded at five levels by the fixture itself, so a regression fails
        // this check instead of filling the process table.
        let selfCall = "test \"${LOOP_DEPTH:-0}\" -lt 5 && LOOP_DEPTH=$((${LOOP_DEPTH:-0} + 1)) bash "
            + ShellCommand.quote(looping.paths.wrapperFile.path)
        try! "{\"statusLine\": {\"type\": \"command\", \"command\": \(JSONEncodedString(selfCall))}}"
            .write(to: looping.paths.settingsFile, atomically: true, encoding: .utf8)
        _ = try! looping.install()
        let loopRun = Process()
        loopRun.executableURL = URL(fileURLWithPath: "/bin/bash")
        loopRun.arguments = [looping.paths.wrapperFile.path]
        let loopInput = Pipe()
        loopRun.standardInput = loopInput
        loopRun.standardOutput = FileHandle.nullDevice
        loopRun.standardError = FileHandle.nullDevice
        try! loopRun.run()
        loopInput.fileHandleForWriting.write(Data(payload.utf8))
        try! loopInput.fileHandleForWriting.close()
        let loopDeadline = Date().addingTimeInterval(5)
        while loopRun.isRunning, Date() < loopDeadline { usleep(20_000) }
        let looped = loopRun.isRunning
        if looped { loopRun.terminate() }
        check(!looped, "A preserved command that runs the bridge again ends")
        check((try? String(contentsOf: calls, encoding: .utf8))?.split(separator: "\n").count == 1,
              "Nocci receives the payload once")

        // MARK: A lost record never loses the preserved command

        let lostCase = prepared("lost-record", existing: "mine --flag")
        try! fm.removeItem(at: lostCase.paths.recordFile)
        check(try! lostCase.plan().preservedCommand == "mine --flag",
              "Without its record, setup reads the preserved command back from the bridge")

        // MARK: A temporary copy of the app is never written into settings

        check(ClaudePaths.isTemporaryAppLocation("/private/var/folders/x/T/AppTranslocation/A1B2/d/Nocci.app/Contents/MacOS/Nocci"),
              "A translocated copy is temporary")
        check(!ClaudePaths.isTemporaryAppLocation("/Applications/Nocci.app/Contents/MacOS/Nocci"),
              "A copy in Applications is not temporary")
        let translocated = ClaudeInstaller(paths: linked.paths,
                                           appPath: "/private/var/folders/x/T/AppTranslocation/A1B2/d/Nocci.app/Contents/MacOS/Nocci")
        do {
            _ = try translocated.plan()
            check(false, "A translocated copy cannot plan setup")
        } catch {
            check(error as? ClaudeIntegrationError == .temporaryLocation(path: translocated.appPath),
                  "A translocated copy is refused with its own reason")
        }

        // MARK: A moved app is reported, not left waiting

        let movedCase = prepared("moved-report", existing: nil)
        let elsewhere = script(sandbox.appendingPathComponent("moved-report/Elsewhere/Nocci"), "#!/bin/bash\ncat >/dev/null\n")
        let movedRecordApp = movedCase.record()!.appPath
        check(ClaudeInstaller(paths: movedCase.paths, appPath: elsewhere).connection(snapshot: ClaudeSnapshotInfo(updated: nil, hasWindows: false, lastEvent: nil))
                == .moved(from: movedRecordApp), "A status line that runs another copy of Nocci says so")

        print("\(checks) Claude integration checks passed (temporary directories only)")
    }
}

func JSONEncodedString(_ value: String) -> String {
    let data = try! JSONSerialization.data(withJSONObject: [value], options: [])
    let text = String(data: data, encoding: .utf8)!
    return String(text.dropFirst().dropLast())
}
