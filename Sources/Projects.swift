import Foundation

/// One entry of a folder listing, as `ProjectScanner` saw it. `isFolder` is
/// true only for a real directory: not a symbolic link and not a package.
/// Hidden entries never reach a listing.
struct FolderEntry: Equatable {
    var name: String
    var isFolder: Bool
    var hasGit: Bool
}

struct FolderListing: Equatable {
    var entries: [FolderEntry]
    /// More entries were there than were examined.
    var truncated = false
}

enum FolderState: Equatable { case available, notAvailable, truncated }

/// A folder a session can start in, identified by its absolute path.
struct Project: Equatable, Identifiable {
    var path: String
    /// The folder's name, or `Group / repo` for a repo inside a plain folder.
    var name: String
    /// The chosen folder it was found in.
    var root: String
    var isRepo: Bool
    /// When `logs/HEAD` in its git directory last changed. Repos only.
    var activity: Date?
    var id: String { path }
}

struct DiscoveryResult: Equatable {
    var projects: [Project] = []
    var folders: [String: FolderState] = [:]
}

/// Every Projects rule that needs no file system, clock or app.
enum ProjectRules {
    /// Entries examined from any one folder listing.
    static let entryLimit = 500

    static func join(_ folder: String, _ name: String) -> String {
        folder.hasSuffix("/") ? folder + name : folder + "/" + name
    }

    /// The home folder's standard folders. Listing Desktop, Documents or
    /// Downloads makes macOS ask the user for access, just from hovering the
    /// notch, and none of them is a project.
    static let homeFolders: Set<String> = ["Applications", "Desktop", "Documents", "Downloads", "Library",
                                           "Movies", "Music", "Pictures", "Public"]

    /// `list` is nil for a folder that is missing or unreadable; `activity`
    /// is asked about repos only. Nothing below the second level is ever listed.
    static func discover(roots: [String], list: (String) -> FolderListing?,
                         activity: (String) -> Date?, home: String? = nil) -> DiscoveryResult {
        var result = DiscoveryResult()
        var seen = Set<String>()
        func add(_ path: String, name: String, root: String, repo: Bool) {
            guard seen.insert(path).inserted else { return }
            result.projects.append(Project(path: path, name: name, root: root, isRepo: repo,
                                           activity: repo ? activity(path) : nil))
        }
        for root in roots {
            guard let listing = list(root) else {
                result.folders[root] = .notAvailable
                continue
            }
            var truncated = listing.truncated
            for entry in listing.entries where entry.isFolder {
                if root == home, !entry.hasGit, homeFolders.contains(entry.name) { continue }
                let path = join(root, entry.name)
                if entry.hasGit {
                    add(path, name: entry.name, root: root, repo: true)
                    continue
                }
                let children = list(path)
                if children?.truncated == true { truncated = true }
                let repos = (children?.entries ?? []).filter { $0.isFolder && $0.hasGit }
                if repos.isEmpty {
                    add(path, name: entry.name, root: root, repo: false)
                    continue
                }
                for child in repos {
                    add(join(path, child.name), name: "\(entry.name) / \(child.name)", root: root, repo: true)
                }
            }
            result.folders[root] = truncated ? .truncated : .available
        }
        return result
    }

    /// Repos by activity, newest first; then repos without a
    /// time; then plain folders. Names in Finder order break ties, then paths.
    static func ordered(_ projects: [Project]) -> [Project] {
        func rank(_ project: Project) -> Int { !project.isRepo ? 2 : project.activity == nil ? 1 : 0 }
        return projects.sorted { a, b in
            if rank(a) != rank(b) { return rank(a) < rank(b) }
            if let x = a.activity, let y = b.activity, x != y { return x > y }
            switch a.name.localizedStandardCompare(b.name) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return a.path < b.path
            }
        }
    }

    /// A clashing name adds its chosen folder's name, or that folder's
    /// shortened path when the folder names clash too. Keyed by path.
    static func labels(for projects: [Project], home: String) -> [String: String] {
        var labels: [String: String] = [:]
        for group in Dictionary(grouping: projects, by: \.name).values {
            guard group.count > 1 else {
                labels[group[0].path] = group[0].name
                continue
            }
            let byFolderName = Dictionary(grouping: group) { lastComponent($0.root) }
            for project in group {
                let folderName = lastComponent(project.root)
                let detail = byFolderName[folderName, default: []].count > 1 ? abbreviate(project.root, home: home) : folderName
                labels[project.path] = "\(project.name) · \(detail)"
            }
        }
        return labels
    }

    static func lastComponent(_ path: String) -> String { (path as NSString).lastPathComponent }

    /// `~` for the home folder and paths inside it; anything else unchanged.
    static func abbreviate(_ path: String, home: String) -> String {
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + String(path.dropFirst(home.count)) }
        return path
    }

    /// Where a `.git` file points, for linked worktrees and submodules. Nil
    /// unless its first line is `gitdir: <path>`; a relative path is resolved
    /// against the project.
    static func gitDirectory(dotGitFile contents: String, project: String) -> String? {
        guard let line = contents.components(separatedBy: .newlines).first, line.hasPrefix("gitdir:") else { return nil }
        let target = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return nil }
        return URL(fileURLWithPath: target.hasPrefix("/") ? target : join(project, target)).standardizedFileURL.path
    }

    static func footer(count: Int, folders: [String], states: [String: FolderState], home: String) -> String {
        guard !folders.isEmpty else { return "No folders chosen" }
        let place = folders.count >= 3 ? "\(folders.count) folders"
            : folders.map { abbreviate($0, home: home) }.joined(separator: ", ")
        var parts = ["\(count) \(count == 1 ? "project" : "projects") in \(place)"]
        if folders.contains(where: { states[$0] == .truncated }) { parts.append("list cut short") }
        if let missing = folders.first(where: { states[$0] == .notAvailable }) {
            parts.append("\(abbreviate(missing, home: home)) not available")
        }
        return parts.joined(separator: " · ")
    }

    static func emptyText(folders: [String], states: [String: FolderState], scanned: Bool, home: String) -> String {
        if folders.isEmpty { return "Add a folder in Settings › Projects." }
        if !scanned { return "Reading folders…" }
        if folders.allSatisfy({ states[$0] == .notAvailable }) {
            return folders.count == 1 ? "\(abbreviate(folders[0], home: home)) isn’t available."
                                      : "None of your project folders are available."
        }
        return folders.count == 1 ? "No projects in \(abbreviate(folders[0], home: home))." : "No projects in your folders."
    }
}

/// Clearly fake projects for `--demo` and the appearance preview.
enum ProjectSamples {
    static let root = "/Users/someone/Code"

    static func projects(now: Date) -> [Project] {
        [Project(path: root + "/api-server", name: "api-server", root: root, isRepo: true,
                 activity: now.addingTimeInterval(-2 * 3600)),
         Project(path: root + "/website", name: "website", root: root, isRepo: true,
                 activity: now.addingTimeInterval(-26 * 3600)),
         Project(path: root + "/mobile/ios", name: "mobile / ios", root: root, isRepo: true,
                 activity: now.addingTimeInterval(-3 * 86400)),
         Project(path: root + "/notes", name: "notes", root: root, isRepo: false, activity: nil)]
    }
}

/// The coding agent a new session runs.
enum ProjectAgent: String, CaseIterable, Identifiable {
    case claude, codex

    var id: String { rawValue }
    var title: String { self == .claude ? "Claude Code" : "Codex" }
    /// Whether the CLI takes `--` before its prompt. Both do (checked with Claude
    /// Code 2.1.280 and codex-cli 0.155.0-alpha.9.2). Where one does not, a prompt
    /// starting with a hyphen is refused, because it would be read as an option.
    var acceptsOptionTerminator: Bool { true }
}

/// Where a new session opens, in preference order.
enum LaunchTarget: String, CaseIterable, Identifiable {
    case terminal, iterm, otherTerminal, vscode, codexApp, nocci

    var id: String { rawValue }
    var isTerminal: Bool { self == .terminal || self == .iterm || self == .otherTerminal }
    /// Terminals and Nocci's own window run the agent's program; the two apps take a link.
    var runsProgram: Bool { isTerminal || self == .nocci }
    var bundleIdentifier: String? {
        switch self {
        case .terminal: return "com.apple.Terminal"
        case .iterm: return "com.googlecode.iterm2"
        case .vscode: return "com.microsoft.VSCode"
        case .otherTerminal, .codexApp, .nocci: return nil
        }
    }

    func supports(_ agent: ProjectAgent) -> Bool {
        switch self {
        case .terminal, .iterm, .otherTerminal, .nocci: return true
        case .vscode: return agent == .claude
        case .codexApp: return agent == .codex
        }
    }
}

/// A notch session as the Projects tab sees it.
struct NotchSession: Equatable {
    let tab: UUID
    /// The terminal's title for the tab: the label, and the agent while it runs.
    var title: String
    var waiting: Bool
}

/// Everything Projects saves. Project names, paths and prompts never are.
struct ProjectSettings: Equatable {
    var enabled = false
    var folders: [String] = []
    var agent = ProjectAgent.claude
    var claudeTarget: LaunchTarget?
    var codexTarget: LaunchTarget?

    static func load(from defaults: UserDefaults) -> ProjectSettings {
        var settings = ProjectSettings()
        settings.enabled = defaults.bool(forKey: "projects.enabled")
        for folder in defaults.stringArray(forKey: "projects.folders") ?? [] { settings.addFolder(folder) }
        settings.agent = defaults.string(forKey: "projects.agent").flatMap(ProjectAgent.init(rawValue:)) ?? .claude
        settings.claudeTarget = defaults.string(forKey: "projects.app.claude").flatMap(LaunchTarget.init(rawValue:))
        settings.codexTarget = defaults.string(forKey: "projects.app.codex").flatMap(LaunchTarget.init(rawValue:))
        return settings
    }

    func save(to defaults: UserDefaults) {
        defaults.set(enabled, forKey: "projects.enabled")
        defaults.set(folders, forKey: "projects.folders")
        defaults.set(agent.rawValue, forKey: "projects.agent")
        defaults.set(claudeTarget?.rawValue, forKey: "projects.app.claude")
        defaults.set(codexTarget?.rawValue, forKey: "projects.app.codex")
    }

    func target(for agent: ProjectAgent) -> LaunchTarget? { agent == .claude ? claudeTarget : codexTarget }

    mutating func setTarget(_ target: LaunchTarget, for agent: ProjectAgent) {
        if agent == .claude { claudeTarget = target } else { codexTarget = target }
    }

    /// Adds a folder in its standard absolute form. False for a relative path
    /// or a folder already listed, however it was written.
    @discardableResult
    mutating func addFolder(_ path: String) -> Bool {
        guard path.hasPrefix("/") else { return false }
        let folder = URL(fileURLWithPath: path).standardizedFileURL.path
        guard !folders.contains(folder) else { return false }
        folders.append(folder)
        return true
    }
}

enum PromptRefusal: Equatable {
    case nul, tooLong(limit: Int), leadingHyphen

    func message(for agent: ProjectAgent) -> String {
        switch self {
        case .nul: return "This prompt contains a character that can’t be passed on."
        case .tooLong(let limit): return "This prompt is too long. The limit is \(limit / 1024) KB."
        case .leadingHyphen: return "A prompt for \(agent.title) can’t start with a hyphen."
        }
    }
}

extension ProjectRules {
    /// In UTF-8 bytes. Lowered for a link target only if probes 3 or 4 found
    /// that its app cannot take this much.
    static func promptLimit(for target: LaunchTarget) -> Int { 32_768 }

    static func resolvedTarget(stored: LaunchTarget?, agent: ProjectAgent, available: [LaunchTarget]) -> LaunchTarget? {
        if let stored, stored.supports(agent), available.contains(stored) { return stored }
        return LaunchTarget.allCases.first { $0.supports(agent) && available.contains($0) }
    }

    /// A prompt of only spaces and line breaks is no prompt; any other is kept exactly.
    static func effectivePrompt(_ prompt: String) -> String {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : prompt
    }

    static func refusal(for prompt: String, agent: ProjectAgent, target: LaunchTarget) -> PromptRefusal? {
        if prompt.unicodeScalars.contains(where: { $0.value == 0 }) { return .nul }
        let limit = promptLimit(for: target)
        if prompt.utf8.count > limit { return .tooLong(limit: limit) }
        if target.runsProgram, !agent.acceptsOptionTerminator, prompt.hasPrefix("-") { return .leadingHyphen }
        return nil
    }

    static func missingProgram(_ agent: ProjectAgent) -> String {
        "\(agent.title) wasn’t found. Choose it in Settings › \(agent == .claude ? "Projects" : "Providers")."
    }

    /// The script deletes itself first, so the prompt is on
    /// disk only until the terminal starts it.
    static func script(project: String, program: String, prompt: String, optionTerminator: Bool) -> String {
        var command = ShellCommand.quote(program)
        if !prompt.isEmpty { command += (optionTerminator ? " -- " : " ") + ShellCommand.quote(prompt) }
        return ["#!/bin/sh", "rm -f -- \"$0\"", "cd -- \(ShellCommand.quote(project)) || exit 1", command,
                "exec \"${SHELL:-/bin/zsh}\" -l", ""].joined(separator: "\n")
    }

    /// Both apps read their links with JavaScript's `URLSearchParams`, which
    /// turns `+` into a space, so only RFC 3986 unreserved characters stay as
    /// they are.
    static func queryValue(_ value: String) -> String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    static func vscodeLink(prompt: String) -> URL {
        URL(string: "vscode://anthropic.claude-code/open" + (prompt.isEmpty ? "" : "?prompt=" + queryValue(prompt)))!
    }

    static func codexLink(project: String, prompt: String) -> URL {
        URL(string: "codex://threads/new?path=" + queryValue(project) + (prompt.isEmpty ? "" : "&prompt=" + queryValue(prompt)))!
    }

    /// What Start does, where that is not obvious. Both links fill the prompt
    /// in without sending it (probes 3 and 4), and the Claude Code extension
    /// is switched off in a folder VS Code does not trust.
    static func note(for target: LaunchTarget) -> String? {
        switch target {
        case .vscode: return "Needs the Claude Code extension and a trusted folder. The prompt is filled in for you to send."
        case .codexApp: return "The prompt is filled in for you to send."
        case .terminal, .iterm, .otherTerminal, .nocci: return nil
        }
    }
}
