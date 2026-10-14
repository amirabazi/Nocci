import Foundation

/// Native Claude Code status-line setup. Foundation only, so the installer can be
/// unit-tested against temporary directories without AppKit or a real account.
///
/// Reference: Claude Code reads `statusLine` from the user settings file
/// (`$CLAUDE_CONFIG_DIR/settings.json`, otherwise `~/.claude/settings.json`) and
/// runs the command with session JSON on stdin.

struct ClaudePaths {
    let configDirectory: URL
    let supportDirectory: URL

    var settingsFile: URL { configDirectory.appendingPathComponent("settings.json") }
    var wrapperFile: URL { configDirectory.appendingPathComponent(ClaudeBridge.wrapperName) }
    var recordFile: URL { supportDirectory.appendingPathComponent("claude-integration.json") }
    var backupDirectory: URL { supportDirectory.appendingPathComponent("backups") }

    static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment,
                        home: URL = FileManager.default.homeDirectoryForCurrentUser) -> ClaudePaths {
        func expand(_ path: String) -> URL {
            if path == "~" { return home }
            if path.hasPrefix("~/") { return home.appendingPathComponent(String(path.dropFirst(2))) }
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        let config = environment["CLAUDE_CONFIG_DIR"].map(expand) ?? home.appendingPathComponent(".claude")
        let support = environment["NOCCI_DATA_DIR"].map(expand)
            ?? home.appendingPathComponent("Library/Application Support/Nocci")
        return ClaudePaths(configDirectory: config, supportDirectory: support)
    }

    /// Nocci's own folders are readable only by the user. Setup in earlier
    /// versions created them with the default mode, so existing ones are
    /// tightened too; a missing folder is not created.
    func secureOwnFolders() throws {
        for folder in [supportDirectory, backupDirectory] where FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        }
    }

    /// Creates the folder a file is written to. Only Nocci's own folders are
    /// made private; Claude's configuration folder keeps whatever mode it has.
    func createFolder(for file: URL) throws {
        let folder = file.deletingLastPathComponent()
        let own = [supportDirectory.path, backupDirectory.path].contains(folder.path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: own ? [.posixPermissions: 0o700] : nil)
        if own { try secureOwnFolders() }
    }

    /// A copy macOS runs from a randomised read-only location (App
    /// Translocation, for an app opened where it was downloaded) or from a
    /// disk image. Either path goes away, so it must never reach Claude's
    /// settings: a later volume mounted at the same path would be run instead.
    static func isTemporaryAppLocation(_ path: String) -> Bool {
        if path.contains("/AppTranslocation/") { return true }
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeIsReadOnlyKey])
        return values?.volumeIsReadOnly == true
    }

    /// Deletes every copy of the settings file one integration made, older
    /// ones included. Only `<prefix><setup time>.json` matches, so the other
    /// integration's copies and anything else in the folder are kept.
    func removeBackups(prefix: String) {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: backupDirectory.path)) ?? []
        where name.hasPrefix(prefix) && name.hasSuffix(".json") {
            guard ClaudeCoder.stampFormatter.date(from: String(name.dropFirst(prefix.count).dropLast(5))) != nil else { continue }
            try? fm.removeItem(at: backupDirectory.appendingPathComponent(name))
        }
    }
}

struct ClaudeRecord: Codable, Equatable {
    var schema = 1
    var installedAt: Date
    var updatedAt: Date
    var appPath: String
    var settingsPath: String
    var wrapperPath: String
    var installedCommand: String
    var previousCommand: String?
    var backupPath: String?
    /// True when this app added `refreshInterval`, so disconnect removes only
    /// its own value. Optional, so records written before it still decode.
    var addedRefreshInterval: Bool?
}

enum ClaudePlanAction: Equatable {
    case install
    case repair
    case upToDate
}

enum ClaudeWarning: Equatable {
    case existingStatusLine(command: String)
    case projectOverride
    case hooksDisabled(path: String)
    case managedHooksOnly(path: String)

    var message: String {
        switch self {
        case .existingStatusLine(let command):
            return "Your current status line is kept and keeps producing its own output: \(command)"
        case .projectOverride:
            return "A statusLine in a project’s .claude/settings.json or .claude/settings.local.json overrides your user settings. In those projects Claude Code runs that status line instead, and usage won’t update until you add this bridge there too."
        case .hooksDisabled(let path):
            return "disableAllHooks is on in \(path). Claude Code won’t run this status line until that setting is removed."
        case .managedHooksOnly(let path):
            return "Managed settings in \(path) allow only managed hooks and status lines. Ask your administrator before relying on this integration."
        }
    }
}

/// What the app knows about the locally stored usage snapshot. Passing this in
/// keeps the installer independent of the snapshot's storage format.
struct ClaudeSnapshotInfo: Equatable {
    /// When the stored windows were read from Claude Code.
    var updated: Date?
    var hasWindows: Bool
    /// When Claude Code last ran the bridge, with or without rate limits.
    var lastEvent: Date?

    func isStale(at date: Date) -> Bool {
        guard hasWindows, let updated else { return false }
        return Freshness.isStale(updated, at: date)
    }
}

enum ClaudeConnection: Equatable {
    case notConfigured
    case waiting
    case connectedWithoutLimits
    case receiving
    case stale
    /// `current` is nil when the status line was removed.
    case conflict(current: String?)
    /// The status line runs another copy of Nocci, usually one since moved.
    case moved(from: String)
    case unavailable(detail: String)

    var isConfigured: Bool {
        switch self {
        case .notConfigured, .unavailable: return false
        default: return true
        }
    }
    var title: String {
        switch self {
        case .notConfigured: return "Not connected"
        case .waiting: return "Configured, waiting for Claude Code"
        case .connectedWithoutLimits: return "Connected, no usage limits reported yet"
        case .receiving: return "Receiving usage"
        case .stale: return "Usage reading is out of date"
        case .conflict: return "Status line changed outside Nocci"
        case .moved: return "Nocci has moved"
        case .unavailable: return "Setup needs attention"
        }
    }
    /// A few words for the provider card's header line.
    var shortStatus: String {
        switch self {
        case .notConfigured: return "Not connected"
        case .waiting: return "Waiting for activity"
        case .connectedWithoutLimits: return "No limits reported"
        case .receiving: return "Connected"
        case .stale: return "Waiting for fresh usage"
        case .conflict: return "Setup changed"
        case .moved: return "Setup needs updating"
        case .unavailable: return "Setup needs attention"
        }
    }
    /// Short enough for the notch's provider card.
    var summary: String {
        switch self {
        case .notConfigured: return "Enable usage tracking to see your session and weekly limits."
        case .waiting: return "Set up. Usage arrives from Claude Code in a terminal, not the VS Code extension."
        case .connectedWithoutLimits: return "Connected. No subscription limits reported yet."
        case .receiving: return "Receiving usage from Claude Code."
        case .stale: return "No fresh reading. The notch shows the last known percentage."
        case .conflict: return "Your status line changed outside Nocci."
        case .moved: return "Nocci has moved. Update the setup in Settings › Providers."
        case .unavailable: return "Setup needs attention. Open Settings › Providers."
        }
    }
    var detail: String {
        switch self {
        case .notConfigured:
            return "Enable usage tracking to read your session and weekly limits from Claude Code."
        case .waiting:
            return "Your status line is set up. Usage appears after Claude Code answers in a terminal session; the VS Code extension never runs status lines, so it sends nothing. Claude Code reports limits only for Pro and Max subscriptions, and only after the first response. In a project whose .claude/settings.json sets its own status line, Claude Code runs that one instead."
        case .connectedWithoutLimits:
            return "Claude Code ran the bridge but sent no rate limits. Usage requires Claude Code 2.1.251 or later, a supported subscription, and a completed response in the session."
        case .receiving:
            return "Claude Code is sending usage to this app."
        case .stale:
            return "No fresh quota reading has arrived for at least five minutes. The notch keeps the last known percentage in orange until its quota window expires. A new Claude Code status-line reading is needed; Refresh only rereads the saved file. Check that your active Claude Code is version 2.1.251 or later."
        case .conflict(let current):
            let now = current.map { "It now runs \($0)." } ?? "It has been removed."
            return "Claude Code’s status line is no longer the one Nocci configured. \(now) Nothing has been changed; disconnect to choose which one to keep."
        case .moved(let from):
            return "Claude Code’s status line still runs Nocci at \(from). Choose Review Setup… and Update Setup so it runs this copy."
        case .unavailable(let detail):
            return detail
        }
    }
}

struct ClaudePlan {
    var action: ClaudePlanAction
    var settingsPath: String
    var settingsExists: Bool
    var wrapperPath: String
    var settingsFragment: String
    var wrapperScript: String
    var backupPath: String?
    var preservedCommand: String?
    var addsRefreshInterval = false
    var warnings: [ClaudeWarning] = []
}

enum ClaudeDisconnectMode {
    /// Restore only when the configured status line is still the one we installed.
    case restore
    /// Restore even though the status line changed after installation.
    case restoreOverridingConflict
    /// Leave the changed status line in place and end the integration.
    case keepCurrentCommand
}

struct ClaudeDisconnectPreview {
    var settingsPath: String
    var restoresCommand: String?
    var conflictingCommand: String?
}

struct ClaudeDisconnectOutcome: Equatable {
    var restoredCommand: String?
    var removedStatusLine = false
    var keptCurrentCommand = false
    var remainingWrapperPath: String?
}

enum ClaudeIntegrationError: LocalizedError, Equatable {
    case notInstalled
    case conflictingStatusLine(current: String?, installed: String)
    case malformedSettings(path: String)
    case unsupportedStatusLine(path: String, detail: String)
    case unsupportedHooks(path: String, detail: String)
    case unreadableSettings(path: String, reason: String)
    case writeFailed(path: String, reason: String)
    case appUnavailable(path: String)
    case temporaryLocation(path: String)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "Usage tracking isn’t set up, so there is nothing to remove."
        case .conflictingStatusLine(let current, _):
            let now = current.map { "changed since setup and now runs \($0)" } ?? "was removed after setup"
            return "Your status line \(now). Nocci won’t replace it without your choice."
        case .malformedSettings(let path):
            return "\(path) isn’t valid JSON. Fix or move that file, then try again. Nothing was changed."
        case .unsupportedStatusLine(let path, let detail):
            return "The status line already configured in \(path) isn’t one this app can extend: \(detail). Nothing was changed."
        case .unsupportedHooks(let path, let detail):
            return "The hooks already configured in \(path) aren’t in a shape Nocci can extend: \(detail). Nothing was changed."
        case .unreadableSettings(let path, let reason):
            return "Couldn’t read \(path). \(reason) Nothing was changed."
        case .writeFailed(let path, let reason):
            return "Couldn’t write \(path). \(reason)"
        case .appUnavailable(let path):
            return "Couldn’t find this app’s executable at \(path). Move Nocci to a stable location and try again."
        case .temporaryLocation:
            return "Nocci is running from a temporary copy that macOS removes later. Quit Nocci, move it to your Applications folder, open it from there and try again. Nothing was changed."
        }
    }
}

enum ShellCommand {
    /// Single-quote a path for a `/bin/bash -c` command line, including paths
    /// that contain spaces, quotes, or other shell metacharacters.
    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The first word of a command line, with quoting and backslash escapes
    /// resolved, so `'/Users/a b/it'\''s.sh' --flag` yields `/Users/a b/it's.sh`.
    static func firstToken(_ command: String) -> String? {
        let characters = Array(command)
        var token = "", quote: Character?, started = false, index = 0
        while index < characters.count {
            let character = characters[index]
            if let open = quote {
                if character == open { quote = nil } else { token.append(character) }
            } else if character == "'" || character == "\"" {
                quote = character; started = true
            } else if character == "\\", index + 1 < characters.count {
                token.append(characters[index + 1]); started = true; index += 1
            } else if character == " " || character == "\t" || character == "\n" {
                if started { break }
            } else {
                token.append(character); started = true
            }
            index += 1
        }
        return token.isEmpty ? nil : token
    }

    /// True when the command joins, redirects, or substitutes anything outside
    /// quotes. Such a command is never assumed to be only ours.
    static func hasChaining(_ command: String) -> Bool {
        let characters = Array(command)
        var quote: Character?, index = 0
        while index < characters.count {
            let character = characters[index]
            if let open = quote {
                if character == open { quote = nil }
            } else if character == "'" || character == "\"" {
                quote = character
            } else if "&|;<>\n`".contains(character) {
                return true
            } else if character == "$", index + 1 < characters.count, characters[index + 1] == "(" {
                return true
            }
            index += 1
        }
        return false
    }
}

enum StrictJSON {
    /// Foundation accepts a trailing comma; Claude Code does not, and reports the
    /// file as a settings error. Treat such a file as malformed rather than
    /// rewriting a file whose owner has not noticed it is broken.
    static func hasTrailingComma(_ text: String) -> Bool {
        var inString = false, escaped = false, pendingComma = false
        for character in text {
            if inString {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
                continue
            }
            switch character {
            case "\"": inString = true; pendingComma = false
            case ",": pendingComma = true
            case " ", "\t", "\n", "\r": continue
            case "}", "]": if pendingComma { return true }; pendingComma = false
            default: pendingComma = false
            }
        }
        return false
    }
}

enum ClaudeStatusLineState: Equatable {
    case absent
    case ours(command: String)
    case foreign(command: String)
    case unsupported(detail: String)
}

struct ClaudeInstaller {
    let paths: ClaudePaths
    let appPath: String
    var managedSettingsPath: String = "/Library/Application Support/ClaudeCode/managed-settings.json"
    var now: () -> Date = Date.init
    private var fm: FileManager { .default }

    // MARK: Reading state

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

    func record() -> ClaudeRecord? {
        guard let data = try? Data(contentsOf: paths.recordFile) else { return nil }
        return try? ClaudeCoder.decoder.decode(ClaudeRecord.self, from: data)
    }

    var installedCommand: String { ShellCommand.quote(paths.wrapperFile.path) }

    /// Some Claude Code clients send status-line events ten minutes or more
    /// apart. A timer keeps the reading current between them; the user's own
    /// value, if they set one, is never overwritten.
    static let refreshIntervalSeconds = 60
    static let backupPrefix = "claude-settings-"
    /// The bridge carries the user's previous status line verbatim, and only
    /// Claude Code, running as the same user, needs to run it.
    static let wrapperMode = 0o700

    /// The `statusLine` entry this app would write, merged over what is there.
    func plannedStatusLine(existing: [String: Any]?, stored: ClaudeRecord?) -> (entry: [String: Any], added: Bool) {
        var entry = existing?["statusLine"] as? [String: Any] ?? [:]
        entry["type"] = "command"
        entry["command"] = installedCommand
        let present = entry["refreshInterval"] != nil
        let added = stored?.addedRefreshInterval == true || !present
        if !present { entry["refreshInterval"] = Self.refreshIntervalSeconds }
        return (entry, added)
    }

    // MARK: Recognizing an existing status line

    /// Classifies the configured status line. Anything we cannot positively
    /// identify as ours counts as the user's and is preserved, never replaced.
    func classify(_ settings: [String: Any]?) -> ClaudeStatusLineState {
        guard let entry = settings?["statusLine"] else { return .absent }
        guard let entry = entry as? [String: Any] else { return .unsupported(detail: "statusLine is not an object") }
        if let type = entry["type"] as? String, type != "command" {
            return .unsupported(detail: "statusLine type “\(type)” isn’t a command")
        }
        guard let command = entry["command"] as? String else {
            return entry.isEmpty ? .absent : .unsupported(detail: "statusLine has no command string")
        }
        if command.trimmingCharacters(in: .whitespaces).isEmpty { return .absent }
        return isOurs(command) ? .ours(command: command) : .foreign(command: command)
    }

    private func isOurs(_ command: String) -> Bool {
        if command == installedCommand { return true }
        guard let token = ShellCommand.firstToken(command) else { return false }
        if token == paths.wrapperFile.path { return true }
        if (token as NSString).lastPathComponent == ClaudeBridge.wrapperName { return true }
        // Only a small regular file can be a bridge; the first word may name
        // a large binary such as node, or a FIFO that would block this read.
        let target = URL(fileURLWithPath: token).resolvingSymlinksInPath().path
        if let attributes = try? fm.attributesOfItem(atPath: target), attributes[.type] as? FileAttributeType == .typeRegular,
           ((attributes[.size] as? NSNumber)?.intValue ?? .max) <= 65_536,
           let text = try? String(contentsOfFile: target, encoding: .utf8), text.contains(ClaudeBridge.marker) { return true }
        // The status line documented before this release invoked the app directly.
        return command.contains("--claude-statusline") && !ShellCommand.hasChaining(command)
    }

    // MARK: Reporting

    /// Reasons Claude Code might not run this status line even once it is configured.
    func warnings(settings: [String: Any]?, preserved: String?) -> [ClaudeWarning] {
        var warnings: [ClaudeWarning] = []
        if let preserved { warnings.append(.existingStatusLine(command: preserved)) }
        warnings.append(.projectOverride)
        if settings?["disableAllHooks"] as? Bool == true {
            warnings.append(.hooksDisabled(path: paths.settingsFile.path))
        }
        if let data = try? Data(contentsOf: URL(fileURLWithPath: managedSettingsPath)),
           let managed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if managed["allowManagedHooksOnly"] as? Bool == true {
                warnings.append(.managedHooksOnly(path: managedSettingsPath))
            }
            if managed["disableAllHooks"] as? Bool == true {
                warnings.append(.hooksDisabled(path: managedSettingsPath))
            }
        }
        return warnings
    }

    /// Configuration alone never counts as a live connection: usage must have
    /// arrived after this integration was installed.
    func connection(snapshot: ClaudeSnapshotInfo) -> ClaudeConnection {
        let settings: [String: Any]?
        do { settings = try settingsObject() }
        catch { return .unavailable(detail: (error as? ClaudeIntegrationError)?.errorDescription ?? error.localizedDescription) }
        let state = classify(settings)
        let stored = record()
        if case .unsupported(let detail) = state, stored == nil { return .unavailable(detail: detail) }
        if let stored, case .ours(let command) = state, command != stored.installedCommand {
            return .conflict(current: command)
        }
        if let stored, case .ours = state, stored.appPath != appPath { return .moved(from: stored.appPath) }
        switch state {
        case .ours: break
        case .absent, .foreign, .unsupported:
            guard stored != nil else { return .notConfigured }
            let current = (settings?["statusLine"] as? [String: Any])?["command"] as? String
            return .conflict(current: current)
        }
        let since = stored?.installedAt ?? .distantPast
        // Any event at or after installation proves the bridge runs. Only a
        // reading captured since then proves usage is actually arriving.
        let ran = [snapshot.updated, snapshot.lastEvent].compactMap { $0 }.contains { $0 >= since }
        guard ran else { return .waiting }
        if snapshot.hasWindows, let updated = snapshot.updated, updated >= since {
            return snapshot.isStale(at: now()) ? .stale : .receiving
        }
        return .connectedWithoutLimits
    }

    // MARK: Planning

    func plan() throws -> ClaudePlan {
        guard !ClaudePaths.isTemporaryAppLocation(appPath) else { throw ClaudeIntegrationError.temporaryLocation(path: appPath) }
        let settings = try settingsObject()
        let state = classify(settings)
        if case .unsupported(let detail) = state {
            throw ClaudeIntegrationError.unsupportedStatusLine(path: paths.settingsFile.path, detail: detail)
        }
        let stored = record()
        // A status line we cannot claim is always the thing to preserve. Our own
        // command is never chained into itself, so repeated setup cannot nest.
        let preserved: String?
        switch state {
        case .foreign(let command): preserved = command
        // Without its record (a failed write, or Nocci's folder removed by a
        // cleaner), the bridge itself still holds the command it chains.
        case .ours: preserved = stored.map(\.previousCommand) ?? chainedCommand()
        case .absent, .unsupported: preserved = nil
        }
        let script = wrapperScript(chaining: preserved)
        let planned = plannedStatusLine(existing: settings, stored: stored)
        let action: ClaudePlanAction
        let installed = state == .ours(command: installedCommand)
        let entryMatches = (settings?["statusLine"] as? [String: Any]).map { ($0 as NSDictionary) == (planned.entry as NSDictionary) } ?? false
        let wrapperMode = (try? fm.attributesOfItem(atPath: paths.wrapperFile.path))?[.posixPermissions] as? NSNumber
        if installed, entryMatches, stored?.appPath == appPath, stored?.previousCommand == preserved,
           (try? String(contentsOf: paths.wrapperFile, encoding: .utf8)) == script, wrapperMode?.intValue == Self.wrapperMode {
            action = .upToDate
        } else if case .ours = state {
            action = .repair
        } else {
            action = stored == nil ? .install : .repair
        }
        return ClaudePlan(action: action,
                          settingsPath: paths.settingsFile.path,
                          settingsExists: settings != nil,
                          wrapperPath: paths.wrapperFile.path,
                          settingsFragment: fragment(planned.entry),
                          wrapperScript: script,
                          backupPath: settings == nil ? nil : plannedBackupPath(existing: stored),
                          preservedCommand: preserved,
                          addsRefreshInterval: planned.added,
                          warnings: warnings(settings: settings, preserved: preserved))
    }

    private func plannedBackupPath(existing: ClaudeRecord?) -> String? {
        if let path = existing?.backupPath, fm.fileExists(atPath: path) { return nil }
        let stamp = ClaudeCoder.stampFormatter.string(from: now())
        return paths.backupDirectory.appendingPathComponent("\(Self.backupPrefix)\(stamp).json").path
    }

    private func fragment(_ entry: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: ["statusLine": entry], options: ClaudeCoder.jsonWriting)
        return String(data: data, encoding: .utf8)!
    }

    /// The command a bridge written by Nocci chains, read back from the script.
    func chainedCommand() -> String? {
        guard let text = try? String(contentsOf: paths.wrapperFile, encoding: .utf8), text.contains(ClaudeBridge.marker) else { return nil }
        let lines = text.components(separatedBy: "\n")
        guard let open = lines.firstIndex(of: "notch_usage_previous_status_line() {"),
              let call = lines.lastIndex(of: "printf '%s' \"$payload\" | notch_usage_previous_status_line"),
              call - 1 > open + 1, lines[call - 1] == "}" else { return nil }
        let command = lines[(open + 1)..<(call - 1)].joined(separator: "\n")
        return command.isEmpty ? nil : command
    }

    func wrapperScript(chaining previous: String?) -> String {
        let app = ShellCommand.quote(appPath)
        var lines = [
            "#!/bin/bash",
            "# Nocci status-line bridge.",
            "# \(ClaudeBridge.marker)",
            "# Generated by Nocci. Disconnect in Settings › Providers to restore",
            "# the previous status line. Manual edits are replaced when you reconnect.",
            "# A chained command that runs this bridge again ends here instead of looping.",
            "[ -n \"${NOCCI_STATUS_LINE_BRIDGE:-}\" ] && exit 0",
            "export NOCCI_STATUS_LINE_BRIDGE=1",
            "payload=$(cat)"
        ]
        if let previous, !previous.isEmpty {
            lines.append("printf '%s' \"$payload\" | \(app) --claude-statusline >/dev/null 2>&1 || true")
            lines.append("notch_usage_previous_status_line() {")
            lines.append(previous)
            lines.append("}")
            lines.append("printf '%s' \"$payload\" | notch_usage_previous_status_line")
        } else {
            lines.append("printf '%s' \"$payload\" | \(app) --claude-statusline || true")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Installing

    @discardableResult
    func install() throws -> ClaudeRecord {
        guard fm.isExecutableFile(atPath: appPath) else { throw ClaudeIntegrationError.appUnavailable(path: appPath) }
        guard !ClaudePaths.isTemporaryAppLocation(appPath) else { throw ClaudeIntegrationError.temporaryLocation(path: appPath) }
        let plan = try plan()
        var settings = try settingsObject() ?? [:]
        let stored = record()

        // The wrapper lives beside the settings file, so writing it first turns a
        // permissions problem into a failure before anything else is touched.
        var addedInterval = false
        let hadWrapper = fm.fileExists(atPath: paths.wrapperFile.path)
        try write(Data(plan.wrapperScript.utf8), to: paths.wrapperFile, permissions: Self.wrapperMode)
        do {
            if let backup = plan.backupPath, let data = try? Data(contentsOf: paths.settingsFile) {
                try write(data, to: URL(fileURLWithPath: backup), permissions: 0o600)
            }
            let planned = plannedStatusLine(existing: settings, stored: stored)
            addedInterval = planned.added
            settings["statusLine"] = planned.entry
            try write(try settingsData(settings), to: paths.settingsFile.resolvingSymlinksInPath(), permissions: nil)
        } catch {
            if !hadWrapper { try? fm.removeItem(at: paths.wrapperFile) }
            if let backup = plan.backupPath { try? fm.removeItem(atPath: backup) }
            throw error
        }

        // Whole seconds, so the record in memory matches the record on disk.
        let time = ClaudeCoder.wholeSeconds(now())
        let updated = ClaudeRecord(installedAt: stored?.installedAt ?? time,
                                   updatedAt: time,
                                   appPath: appPath,
                                   settingsPath: paths.settingsFile.path,
                                   wrapperPath: paths.wrapperFile.path,
                                   installedCommand: installedCommand,
                                   previousCommand: plan.preservedCommand,
                                   backupPath: plan.backupPath ?? stored?.backupPath,
                                   addedRefreshInterval: addedInterval)
        try write(try ClaudeCoder.encoder.encode(updated), to: paths.recordFile, permissions: 0o600)
        return updated
    }

    // MARK: Disconnecting

    func disconnectPlan() throws -> ClaudeDisconnectPreview {
        guard let stored = record() else { throw ClaudeIntegrationError.notInstalled }
        let settings = try settingsObject()
        let current = (settings?["statusLine"] as? [String: Any])?["command"] as? String
        let conflict = current == stored.installedCommand ? nil : (current ?? "no status line")
        return ClaudeDisconnectPreview(settingsPath: paths.settingsFile.path,
                                       restoresCommand: stored.previousCommand,
                                       conflictingCommand: conflict)
    }

    @discardableResult
    func disconnect(_ mode: ClaudeDisconnectMode = .restore) throws -> ClaudeDisconnectOutcome {
        guard let stored = record() else { throw ClaudeIntegrationError.notInstalled }
        var settings = try settingsObject() ?? [:]
        let current = (settings["statusLine"] as? [String: Any])?["command"] as? String
        let conflicts = current != stored.installedCommand

        if mode == .restore, conflicts {
            throw ClaudeIntegrationError.conflictingStatusLine(current: current,
                                                               installed: stored.installedCommand)
        }
        var outcome = ClaudeDisconnectOutcome()
        if mode == .keepCurrentCommand {
            // Unrelated changes stay exactly as the user left them. The wrapper
            // may still be referenced by whatever they configured, so keep it.
            outcome.keptCurrentCommand = true
            outcome.remainingWrapperPath = fm.fileExists(atPath: stored.wrapperPath) ? stored.wrapperPath : nil
        } else {
            if let previous = stored.previousCommand {
                var statusLine = settings["statusLine"] as? [String: Any] ?? [:]
                statusLine["type"] = "command"
                statusLine["command"] = previous
                // Remove the refresh interval only if we added it and nobody
                // changed the value since.
                if stored.addedRefreshInterval == true,
                   statusLine["refreshInterval"] as? Int == Self.refreshIntervalSeconds {
                    statusLine["refreshInterval"] = nil
                }
                settings["statusLine"] = statusLine
                outcome.restoredCommand = previous
            } else {
                settings["statusLine"] = nil
                outcome.removedStatusLine = true
            }
            if fm.fileExists(atPath: paths.settingsFile.path) || !settings.isEmpty {
                try write(try settingsData(settings), to: paths.settingsFile.resolvingSymlinksInPath(), permissions: nil)
            }
            try? fm.removeItem(atPath: stored.wrapperPath)
        }
        // The copy may hold secrets from the settings file, so it goes with
        // the integration rather than outliving it.
        paths.removeBackups(prefix: Self.backupPrefix)
        try? fm.removeItem(at: paths.recordFile)
        return outcome
    }

    /// Settings files are edited by people; keep them newline-terminated.
    private func settingsData(_ settings: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: settings, options: ClaudeCoder.jsonWriting)
        data.append(10)
        return data
    }

    /// The settings file is written through a symbolic link (dotfile managers
    /// link it), so callers pass its resolved path; an atomic write to the
    /// link itself would replace it with a plain file.
    private func write(_ data: Data, to url: URL, permissions: Int?) throws {
        do {
            try paths.createFolder(for: url)
            if let permissions, !fm.fileExists(atPath: url.path) {
                // Created private, so the bridge never exists readable by others.
                fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: permissions])
            }
            try data.write(to: url, options: .atomic)
            if let permissions { try fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path) }
        } catch {
            throw ClaudeIntegrationError.writeFailed(path: url.path, reason: error.localizedDescription)
        }
    }
}

enum ClaudeBridge {
    static let marker = "nocci-status-line-bridge schema 1"
    static let wrapperName = "nocci-statusline.sh"
}

enum ClaudeCoder {
    /// Paths read as they look in Finder, not as "\/Users\/…".
    static let jsonWriting: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
    /// The record is stored as ISO 8601 without fractional seconds.
    static func wholeSeconds(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }
    static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()
}
