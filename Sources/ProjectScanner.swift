import Foundation

/// Reads the file system for the Projects list: folder listings and when a
/// repo's git activity last happened. Runs off the main thread and never
/// runs `git`.
enum ProjectScanner {
    static func scan(_ folders: [String]) -> DiscoveryResult {
        ProjectRules.discover(roots: folders, list: { list($0) }, activity: { activity($0) },
                              home: FileManager.default.homeDirectoryForCurrentUser.path)
    }

    /// Nil when the folder is missing, not a folder, or unreadable. Hidden
    /// entries are left out before the cap, so only visible ones count.
    static func list(_ path: String, limit: Int = ProjectRules.entryLimit) -> FolderListing? {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: path, isDirectory: true), includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]) else { return nil }
        let sorted = children.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
        let entries = sorted.prefix(limit).map { child -> FolderEntry in
            let values = try? child.resourceValues(forKeys: keys)
            let isFolder = values?.isDirectory == true && values?.isSymbolicLink != true && values?.isPackage != true
            let hasGit = isFolder && FileManager.default.fileExists(atPath: child.appendingPathComponent(".git").path)
            return FolderEntry(name: child.lastPathComponent, isFolder: isFolder, hasGit: hasGit)
        }
        return FolderListing(entries: entries, truncated: sorted.count > limit)
    }

    /// When `logs/HEAD` last changed. Git writes it on commit, checkout,
    /// merge, rebase, reset and clone; `.git/index` is not used because
    /// editors rewrite it whenever a repo is merely open.
    static func activity(_ project: String) -> Date? {
        guard let directory = gitDirectory(project) else { return nil }
        let log = ProjectRules.join(directory, "logs/HEAD")
        // A time in the future (an extracted archive, a wrong clock) would put
        // that folder first for good, and first is what Code Review picks.
        return ((try? FileManager.default.attributesOfItem(atPath: log))?[.modificationDate] as? Date).map { min($0, Date()) }
    }

    /// The project's git directory, following a worktree's or submodule's
    /// `.git` file. Such a file is a single short line, so a large one is not read.
    static func gitDirectory(_ project: String) -> String? {
        let dotGit = ProjectRules.join(project, ".git")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue { return dotGit }
        guard let size = (try? FileManager.default.attributesOfItem(atPath: dotGit))?[.size] as? NSNumber,
              size.intValue <= 4096,
              let data = FileManager.default.contents(atPath: dotGit),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return ProjectRules.gitDirectory(dotGitFile: text, project: project)
    }
}
