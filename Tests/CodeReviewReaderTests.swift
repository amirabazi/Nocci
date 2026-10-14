import Foundation
import Darwin

// Real temporary folders. No git is run and nothing outside them is read.
@main
struct CodeReviewReaderTests {
    static func main() throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            guard condition() else { fatalError("FAIL: \(label)") }
            checks += 1
        }
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("nocci-review-reader-" + UUID().uuidString).path
        defer { try? manager.removeItem(atPath: root) }
        func file(_ path: String, _ text: String) throws {
            try manager.createDirectory(atPath: ((root + "/" + path) as NSString).deletingLastPathComponent,
                                        withIntermediateDirectories: true)
            try Data(text.utf8).write(to: URL(fileURLWithPath: root + "/" + path))
        }
        let origin = "[remote \"origin\"]\n\turl = git@github.com:owner/repo.git\n"
        let expected = ["git@github.com:owner/repo.git"]

        try file("plain/.git/config", origin)
        check(CodeReviewReader.remotes(root + "/plain") == expected, "A plain repo's remotes")

        try file("main/.git/config", origin)
        try file("main/.git/worktrees/wt/commondir", "../..\n")
        try file("wt/.git", "gitdir: \(root)/main/.git/worktrees/wt\n")
        check(CodeReviewReader.remotes(root + "/wt") == expected, "A linked worktree reads the shared config through a relative commondir")

        try file("gitdirs/abs/commondir", "\(root)/main/.git")
        try file("abs/.git", "gitdir: ../gitdirs/abs\n")
        check(CodeReviewReader.remotes(root + "/abs") == expected, "and through an absolute one")

        try file("super/.git/modules/sub/config", "[remote \"origin\"]\n\turl = https://gitlab.example.com/group/sub.git\n")
        try file("super/sub/.git", "gitdir: ../.git/modules/sub\n")
        check(CodeReviewReader.remotes(root + "/super/sub") == ["https://gitlab.example.com/group/sub.git"],
              "A submodule reads its own config")

        try manager.createDirectory(atPath: root + "/noconfig/.git", withIntermediateDirectories: true)
        try manager.createDirectory(atPath: root + "/folder", withIntermediateDirectories: true)
        check(CodeReviewReader.remotes(root + "/noconfig").isEmpty && CodeReviewReader.remotes(root + "/folder").isEmpty
              && CodeReviewReader.remotes(root + "/missing").isEmpty,
              "A repo without a config, a plain folder and a missing folder have no remotes")

        try file("big/.git/config", origin + String(repeating: "#", count: CodeReviewReader.configLimit))
        check(CodeReviewReader.remotes(root + "/big").isEmpty, "An oversized config is not read")
        try file("edge/.git/config", origin + String(repeating: "#", count: CodeReviewReader.configLimit - origin.utf8.count))
        check(CodeReviewReader.remotes(root + "/edge") == expected, "A config of exactly the limit is read")

        try file("gitdirs/bigcommon/commondir", String(repeating: "a", count: CodeReviewReader.commondirLimit + 1))
        try file("gitdirs/bigcommon/config", origin)
        try file("bigcommon/.git", "gitdir: ../gitdirs/bigcommon\n")
        check(CodeReviewReader.remotes(root + "/bigcommon").isEmpty,
              "An oversized commondir means no remotes, not the worktree's own config")

        try manager.createDirectory(atPath: root + "/binary/.git", withIntermediateDirectories: true)
        try Data([0xff, 0xfe, 0x00, 0x80]).write(to: URL(fileURLWithPath: root + "/binary/.git/config"))
        check(CodeReviewReader.remotes(root + "/binary").isEmpty, "A config that is not UTF-8 has no remotes")

        try file("elsewhere/config", origin)
        try manager.createDirectory(atPath: root + "/symlinked/.git", withIntermediateDirectories: true)
        try manager.createSymbolicLink(atPath: root + "/symlinked/.git/config",
                                       withDestinationPath: root + "/elsewhere/config")
        check(CodeReviewReader.remotes(root + "/symlinked") == expected,
              "A config that is a symlink to a small valid config elsewhere is read")

        try file("elsewhere-big/config", origin + String(repeating: "#", count: CodeReviewReader.configLimit))
        try manager.createDirectory(atPath: root + "/symlinked-big/.git", withIntermediateDirectories: true)
        try manager.createSymbolicLink(atPath: root + "/symlinked-big/.git/config",
                                       withDestinationPath: root + "/elsewhere-big/config")
        check(CodeReviewReader.remotes(root + "/symlinked-big").isEmpty,
              "A config that is a symlink to a file larger than the limit is not read")

        try file("commondir-target/oversized", String(repeating: "a", count: CodeReviewReader.commondirLimit + 1))
        try manager.createDirectory(atPath: root + "/wtbig/.git/worktrees/wt", withIntermediateDirectories: true)
        try file("wtbig/.git/config", origin)
        try manager.createSymbolicLink(atPath: root + "/wtbig/.git/worktrees/wt/commondir",
                                       withDestinationPath: root + "/commondir-target/oversized")
        try file("wtbiglink/.git", "gitdir: \(root)/wtbig/.git/worktrees/wt\n")
        check(CodeReviewReader.remotes(root + "/wtbiglink").isEmpty,
              "A worktree whose commondir is a symlink to a file larger than the limit has no remotes")

        try manager.createDirectory(atPath: root + "/fifo/.git", withIntermediateDirectories: true)
        let fifoPath = root + "/fifo/.git/config"
        guard mkfifo(fifoPath, 0o600) == 0 else { fatalError("FAIL: could not create a FIFO for the test") }
        let semaphore = DispatchSemaphore(value: 0)
        var fifoRemotes: [String] = ["unset"]
        DispatchQueue.global().async {
            fifoRemotes = CodeReviewReader.remotes(root + "/fifo")
            semaphore.signal()
        }
        let timedOut = semaphore.wait(timeout: .now() + 2) == .timedOut
        check(!timedOut, "Reading a config that is a FIFO returns instead of blocking forever")
        check(fifoRemotes.isEmpty, "A config that is a FIFO has no remotes")

        print("\(checks) code review reader checks passed")
    }
}
