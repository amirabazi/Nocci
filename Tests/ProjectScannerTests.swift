import Foundation

// Real temporary folders. Nothing outside the temporary directory is read.
@main
struct ProjectScannerTests {
    static func main() throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            guard condition() else { fatalError("FAIL: \(label)") }
            checks += 1
        }
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("nocci-scanner-" + UUID().uuidString).path
        defer { try? manager.removeItem(atPath: root) }
        func folder(_ path: String) throws {
            try manager.createDirectory(atPath: root + "/" + path, withIntermediateDirectories: true)
        }
        func file(_ path: String, _ text: String = "") throws {
            try folder((path as NSString).deletingLastPathComponent)
            try Data(text.utf8).write(to: URL(fileURLWithPath: root + "/" + path))
        }
        func touch(_ path: String, _ date: Date) throws {
            try manager.setAttributes([.modificationDate: date], ofItemAtPath: root + "/" + path)
        }
        let when = Date(timeIntervalSince1970: 1_700_000_000)

        try file("code/alpha/.git/logs/HEAD", "log")
        try touch("code/alpha/.git/logs/HEAD", when)
        try file("code/beta/readme.md")
        try folder("code/group/one/.git")
        try file("code/group/two/.git", "gitdir: ../../../gitdirs/two\n")
        try file("gitdirs/two/logs/HEAD")
        try touch("gitdirs/two/logs/HEAD", when.addingTimeInterval(60))
        try file("code/group/three/.git", "gitdir: \(root)/gitdirs/three\n")
        try file("gitdirs/three/logs/HEAD")
        try touch("gitdirs/three/logs/HEAD", when.addingTimeInterval(120))
        try file("code/group/broken/.git", "not a pointer\n")
        try folder("code/group/plain")
        try folder("code/.hidden/.git")
        try folder("code/Tool.app/Contents")
        try manager.createSymbolicLink(atPath: root + "/code/link", withDestinationPath: root + "/code/alpha")
        try file("code/notes.txt")

        // MARK: Listings
        let listing = ProjectScanner.list(root + "/code")
        check(listing?.entries.map(\.name) == ["alpha", "beta", "group", "link", "notes.txt", "Tool.app"],
              "Hidden entries are left out and the rest are sorted like Finder")
        let entries = Dictionary(uniqueKeysWithValues: (listing?.entries ?? []).map { ($0.name, $0) })
        check(entries["alpha"] == FolderEntry(name: "alpha", isFolder: true, hasGit: true), "A folder with .git is a repo")
        check(entries["beta"] == FolderEntry(name: "beta", isFolder: true, hasGit: false), "A folder without .git is plain")
        check(entries["link"]?.isFolder == false && entries["link"]?.hasGit == false, "A symbolic link is never followed")
        check(entries["Tool.app"]?.isFolder == false, "A package is not a project folder")
        check(entries["notes.txt"]?.isFolder == false, "A file is not a project folder")
        check(listing?.truncated == false, "A small folder is not cut short")
        check(ProjectScanner.list(root + "/code/group")?.entries.filter(\.hasGit).map(\.name) == ["broken", "one", "three", "two"],
              "A .git file counts as a repo")
        let capped = ProjectScanner.list(root + "/code", limit: 2)
        check(capped?.entries.map(\.name) == ["alpha", "beta"] && capped?.truncated == true,
              "Only entries up to the limit are examined, and the listing says it was cut short")
        check(ProjectScanner.list(root + "/missing") == nil, "A missing folder cannot be listed")
        check(ProjectScanner.list(root + "/code/notes.txt") == nil, "A file cannot be listed")
        try folder("locked")
        try manager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: root + "/locked")
        check(ProjectScanner.list(root + "/locked") == nil, "An unreadable folder cannot be listed")
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root + "/locked")

        for index in 0..<600 { try folder("big/f\(index)") }
        let started = Date()
        let big = ProjectScanner.list(root + "/big")
        check(big?.entries.count == 500 && big?.truncated == true, "A huge folder is examined only up to the limit and says so")
        check(Date().timeIntervalSince(started) < 5, "Listing a huge folder stays quick")

        // MARK: Activity
        check(ProjectScanner.activity(root + "/code/alpha") == when, "Activity is when logs/HEAD last changed")
        check(ProjectScanner.activity(root + "/code/group/two") == when.addingTimeInterval(60), "A relative gitdir is followed")
        check(ProjectScanner.activity(root + "/code/group/three") == when.addingTimeInterval(120), "An absolute gitdir is followed")
        check(ProjectScanner.activity(root + "/code/group/one") == nil, "A repo without logs/HEAD has no activity time")
        check(ProjectScanner.activity(root + "/code/group/broken") == nil, "A malformed .git file points nowhere")
        check(ProjectScanner.activity(root + "/code/beta") == nil, "A plain folder has no activity time")
        try file("elsewhere/future/.git/logs/HEAD", "log")
        try touch("elsewhere/future/.git/logs/HEAD", Date().addingTimeInterval(86_400 * 365))
        check((ProjectScanner.activity(root + "/elsewhere/future") ?? .distantFuture) <= Date(),
              "A time in the future counts as now, so that folder cannot stay first for good")
        try file("code/group/huge/.git", String(repeating: "x", count: 5000))
        check(ProjectScanner.gitDirectory(root + "/code/group/huge") == nil, "An oversized .git file is not read")

        // MARK: A whole scan
        let result = ProjectScanner.scan([root + "/code", root + "/missing"])
        check(result.projects.map(\.name) == ["alpha", "beta", "group / broken", "group / huge", "group / one",
                                              "group / three", "group / two"], "A real tree gives the expected projects")
        check(result.projects.first?.activity == when, "A whole scan reads activity")
        check(result.folders == [root + "/code": .available, root + "/missing": .notAvailable], "Folder states are reported")

        print("\(checks) project scanner checks passed")
    }
}
