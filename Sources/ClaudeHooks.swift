import Foundation

/// Adds and removes Nocci's Claude Code hooks in the user settings file, with
/// the same rules as the status-line setup: nothing is written until the user
/// reviews the plan, other settings and the user's own hooks are preserved,
/// the file is backed up once, and anything unexpected aborts unchanged.
/// Foundation only, so it is tested against temporary directories.
struct ClaudeHooksRecord: Codable, Equatable {
    var schema = 1
    var installedAt: Date
    var command: String
    var settingsPath: String
    var backupPath: String?
}

enum ClaudeHooksStatus: Equatable {
    case off
    case on
    /// Installed from another place; the hooks still point there.
    case moved(installedCommand: String)
    /// The record exists but the settings file no longer holds Nocci's hooks.
    case removedOutside
}

enum ClaudeHooksWarning: Equatable {
    case hooksDisabled(path: String)
    case managedHooksOnly(path: String)

    var message: String {
        switch self {
        case .hooksDisabled(let path):
            return "disableAllHooks is on in \(path). Claude Code won’t run these hooks until that setting is removed."
        case .managedHooksOnly(let path):
            return "Managed settings in \(path) allow only managed hooks. Ask your administrator before relying on session status."
        }
    }
}

struct ClaudeHooksPlan: Equatable {
    var settingsPath: String
    var fragment: String
    var backupPath: String?
    var warnings: [ClaudeHooksWarning]
}

struct ClaudeHooksInstaller {
    /// Events every recent Claude Code knows. A newer event name makes an
    /// older Claude Code show a settings warning, so the list stays short.
    static let events: [(name: String, matcher: String?)] = [
        ("SessionStart", nil), ("UserPromptSubmit", nil), ("PreToolUse", "AskUserQuestion"),
        ("PostToolUse", nil), ("PermissionRequest", nil),
        ("Notification", "permission_prompt|elicitation_dialog|elicitation_url_dialog|agent_needs_input"),
        ("Stop", nil), ("SessionEnd", nil)]

    static let backupPrefix = "claude-settings-before-hooks-"

    let paths: ClaudePaths
    let appPath: String
    var managedSettingsPath: String = "/Library/Application Support/ClaudeCode/managed-settings.json"
    var now: () -> Date = Date.init
    private var fm: FileManager { .default }

    var recordFile: URL { paths.supportDirectory.appendingPathComponent("claude-hooks.json") }

    /// A moved or deleted app fails quietly instead of showing a hook error
    /// in every session.
    var command: String { ShellCommand.quote(appPath) + " --claude-hook 2>/dev/null || true" }

    /// Nocci's hook wherever the app lived when it was installed: the first
    /// word is an executable named Nocci and the command asks for the hook mode.
    static func isNocciHook(_ command: String) -> Bool {
        guard command.contains(" --claude-hook"), let first = ShellCommand.firstToken(command) else { return false }
        return URL(fileURLWithPath: first).lastPathComponent == "Nocci"
    }

    func record() -> ClaudeHooksRecord? {
        guard let data = try? Data(contentsOf: recordFile) else { return nil }
        return try? ClaudeCoder.decoder.decode(ClaudeHooksRecord.self, from: data)
    }

    func status() -> ClaudeHooksStatus {
        guard let record = record() else { return .off }
        guard let settings = (try? settingsObject()) ?? nil, nocciHookCount(settings) > 0 else { return .removedOutside }
        return record.command == command ? .on : .moved(installedCommand: record.command)
    }

    func plan() throws -> ClaudeHooksPlan {
        guard !ClaudePaths.isTemporaryAppLocation(appPath) else { throw ClaudeIntegrationError.temporaryLocation(path: appPath) }
        guard fm.isExecutableFile(atPath: appPath) else { throw ClaudeIntegrationError.appUnavailable(path: appPath) }
        let settings = try settingsObject()
        _ = try merged(settings ?? [:])
        return ClaudeHooksPlan(settingsPath: paths.settingsFile.path, fragment: fragment(),
                               backupPath: settings == nil ? nil : plannedBackupPath(), warnings: warnings(settings))
    }

    @discardableResult
    func install() throws -> ClaudeHooksRecord {
        let plan = try plan()
        let updated = try merged(try settingsObject() ?? [:])
        var backup = record()?.backupPath
        if let path = plan.backupPath, let data = try? Data(contentsOf: paths.settingsFile) {
            try write(data, to: URL(fileURLWithPath: path), permissions: 0o600)
            backup = path
        }
        do {
            try write(try settingsData(updated), to: paths.settingsFile.resolvingSymlinksInPath(), permissions: nil)
        } catch {
            if let path = plan.backupPath { try? fm.removeItem(atPath: path) }
            throw error
        }
        let record = ClaudeHooksRecord(installedAt: ClaudeCoder.wholeSeconds(now()), command: command,
                                       settingsPath: paths.settingsFile.path, backupPath: backup)
        try write(try ClaudeCoder.encoder.encode(record), to: recordFile, permissions: 0o600)
        return record
    }

    /// Removes only Nocci's hooks. An event array, or the hooks object, is
    /// removed only when nothing else is left in it.
    func uninstall() throws {
        if let settings = try settingsObject(), nocciHookCount(settings) > 0,
           var hooks = settings["hooks"] as? [String: Any] {
            for (event, value) in hooks {
                guard let groups = value as? [Any] else { continue }
                let kept = removingNocci(groups)
                if kept.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = kept }
            }
            var updated = settings
            if hooks.isEmpty { updated.removeValue(forKey: "hooks") } else { updated["hooks"] = hooks }
            try write(try settingsData(updated), to: paths.settingsFile.resolvingSymlinksInPath(), permissions: nil)
        }
        // The copy may hold secrets from the settings file, so it goes with
        // the integration rather than outliving it.
        paths.removeBackups(prefix: Self.backupPrefix)
        if fm.fileExists(atPath: recordFile.path) { try fm.removeItem(at: recordFile) }
    }

    // MARK: Merging

    private func merged(_ settings: [String: Any]) throws -> [String: Any] {
        var settings = settings
        var hooks: [String: Any] = [:]
        if let value = settings["hooks"] {
            guard let object = value as? [String: Any] else {
                throw ClaudeIntegrationError.unsupportedHooks(path: paths.settingsFile.path, detail: "hooks is not an object")
            }
            hooks = object
        }
        for (event, matcher) in Self.events {
            var groups: [Any] = []
            if let value = hooks[event] {
                guard let array = value as? [Any] else {
                    throw ClaudeIntegrationError.unsupportedHooks(path: paths.settingsFile.path, detail: "\(event) is not a list")
                }
                groups = removingNocci(array)
            }
            groups.append(group(matcher: matcher))
            hooks[event] = groups
        }
        settings["hooks"] = hooks
        return settings
    }

    private func group(matcher: String?) -> [String: Any] {
        var group: [String: Any] = ["hooks": [["type": "command", "command": command, "async": true, "timeout": 10]]]
        if let matcher { group["matcher"] = matcher }
        return group
    }

    /// Drops Nocci's hooks from each group, and a group left empty by that.
    /// Groups of any other shape are kept exactly as they are.
    private func removingNocci(_ groups: [Any]) -> [Any] {
        groups.compactMap { value in
            guard var group = value as? [String: Any], let entries = group["hooks"] as? [Any] else { return value }
            let kept = entries.filter { entry in
                guard let command = (entry as? [String: Any])?["command"] as? String else { return true }
                return !Self.isNocciHook(command)
            }
            if kept.count == entries.count { return value }
            if kept.isEmpty { return nil }
            group["hooks"] = kept
            return group
        }
    }

    private func nocciHookCount(_ settings: [String: Any]) -> Int {
        guard let hooks = settings["hooks"] as? [String: Any] else { return 0 }
        return hooks.values.compactMap { $0 as? [Any] }.joined()
            .compactMap { ($0 as? [String: Any])?["hooks"] as? [Any] }.joined()
            .filter { (($0 as? [String: Any])?["command"] as? String).map(Self.isNocciHook) ?? false }.count
    }

    // MARK: Reporting

    private func fragment() -> String {
        let hooks = Dictionary(uniqueKeysWithValues: Self.events.map { ($0.name, [group(matcher: $0.matcher)]) })
        let data = try! JSONSerialization.data(withJSONObject: ["hooks": hooks], options: ClaudeCoder.jsonWriting)
        return String(decoding: data, as: UTF8.self)
    }

    private func plannedBackupPath() -> String? {
        if let path = record()?.backupPath, fm.fileExists(atPath: path) { return nil }
        let stamp = ClaudeCoder.stampFormatter.string(from: now())
        return paths.backupDirectory.appendingPathComponent("\(Self.backupPrefix)\(stamp).json").path
    }

    private func warnings(_ settings: [String: Any]?) -> [ClaudeHooksWarning] {
        var warnings: [ClaudeHooksWarning] = []
        if settings?["disableAllHooks"] as? Bool == true { warnings.append(.hooksDisabled(path: paths.settingsFile.path)) }
        if let data = try? Data(contentsOf: URL(fileURLWithPath: managedSettingsPath)),
           let managed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if managed["allowManagedHooksOnly"] as? Bool == true { warnings.append(.managedHooksOnly(path: managedSettingsPath)) }
            if managed["disableAllHooks"] as? Bool == true { warnings.append(.hooksDisabled(path: managedSettingsPath)) }
        }
        return warnings
    }

    // MARK: Files

    private func settingsObject() throws -> [String: Any]? {
        guard fm.fileExists(atPath: paths.settingsFile.path) else { return nil }
        let data: Data
        do { data = try Data(contentsOf: paths.settingsFile) }
        catch { throw ClaudeIntegrationError.unreadableSettings(path: paths.settingsFile.path, reason: error.localizedDescription) }
        if data.isEmpty { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              !StrictJSON.hasTrailingComma(String(decoding: data, as: UTF8.self)) else {
            throw ClaudeIntegrationError.malformedSettings(path: paths.settingsFile.path)
        }
        return object
    }

    private func settingsData(_ settings: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: settings, options: ClaudeCoder.jsonWriting)
        data.append(10)
        return data
    }

    /// Callers pass the settings file's resolved path, so a linked file is
    /// written through rather than replaced by a plain one.
    private func write(_ data: Data, to url: URL, permissions: Int?) throws {
        do {
            try paths.createFolder(for: url)
            if let permissions, !fm.fileExists(atPath: url.path) {
                fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: permissions])
            }
            try data.write(to: url, options: .atomic)
            if let permissions { try fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path) }
        } catch {
            throw ClaudeIntegrationError.writeFailed(path: url.path, reason: error.localizedDescription)
        }
    }
}
