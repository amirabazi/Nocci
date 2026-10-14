import Foundation

// Every pure Code Review rule, with made-up pull requests, configs and remotes.
@main
struct CodeReviewTests {
    static func main() {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            guard condition() else { fatalError("FAIL: \(label)") }
            checks += 1
        }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let github = PullRequest(target: .github, repo: "owner/repo", number: 42, title: "Fix the hover",
                                 url: URL(string: "https://github.com/owner/repo/pull/42")!, updated: now,
                                 roles: [.reviewRequested])
        let gitlab = PullRequest(target: PullRequestTarget(forge: .gitlab, host: "gitlab.example.com:8443"),
                                 repo: "group/sub/app", number: 317, title: "Paginate",
                                 url: URL(string: "https://gitlab.example.com:8443/group/sub/app/-/merge_requests/317")!,
                                 updated: now, roles: [.authored])

        // MARK: Placeholders
        let every = "{url}|{reference}|{number}|{repo}|{title}|{host}|{kind}"
        check(CodeReviewRules.fill(every, with: github)
              == "https://github.com/owner/repo/pull/42|#42|42|owner/repo|Fix the hover|github.com|pull request",
              "Every placeholder is filled for a pull request")
        check(CodeReviewRules.fill(every, with: gitlab)
              == "https://gitlab.example.com:8443/group/sub/app/-/merge_requests/317|!317|317|group/sub/app|Paginate|gitlab.example.com:8443|merge request",
              "Every placeholder is filled for a merge request, the host keeping its port")
        check(Set(CodeReviewRules.values(for: github).keys) == Set(CodeReviewRules.placeholders),
              "The Settings caption lists exactly the placeholders that are filled")
        check(CodeReviewRules.fill("{unknown} {URL} {} { url } {url", with: github) == "{unknown} {URL} {} { url } {url",
              "Unknown, differently cased, empty, spaced and unclosed braces stay as typed")
        check(CodeReviewRules.fill("}{{url}}{", with: github) == "}{https://github.com/owner/repo/pull/42}{",
              "Stray braces around a placeholder stay")
        check(CodeReviewRules.fill("Review\n\n  {reference}\t!", with: github) == "Review\n\n  #42\t!",
              "Line breaks and spacing are kept exactly")
        var hostile = github
        hostile.title = "{url} $(rm -rf ~) `id` \"q\" 'q'\nnext 🚀"
        check(CodeReviewRules.fill("T: {title} U: {url}", with: hostile)
              == "T: {url} $(rm -rf ~) `id` \"q\" 'q' next 🚀 U: https://github.com/owner/repo/pull/42",
              "A title is inserted as written, on one line, and never scanned again")
        hostile.title = "Fix\u{1b}[2J\u{7}\rit\u{0}"
        check(CodeReviewRules.fill("{title}", with: hostile) == "Fix [2J  it ",
              "Control characters in a title, which anyone opening a pull request writes, become spaces")
        hostile.title = "Ship 👩\u{200D}💻 \u{202E}txt.exe"
        check(CodeReviewRules.fill("{title}", with: hostile) == "Ship 👩\u{200D}💻  txt.exe",
              "An emoji keeps its joiner, and a bidirectional override becomes a space")

        // MARK: Where a review without a clone runs
        check(CodeReviewRules.reviewPath(for: github) == "github.com/owner/repo/42",
              "A pull request's review runs in a folder of its own")
        check(CodeReviewRules.reviewPath(for: gitlab) == "gitlab.example.com-8443/group/sub/app/317",
              "A merge request's nested groups become folders and the port stays in a safe name")
        var escaping = github
        escaping.repo = "../../etc/x y"
        check(CodeReviewRules.reviewPath(for: escaping) == "github.com/-/-/etc/x-y/42",
              "No part of a forge's reply can climb out of the review folder")
        check(CodeReviewRules.label(for: github) == "Review owner/repo #42"
              && CodeReviewRules.label(for: gitlab) == "Review group/sub/app !317",
              "The tab label names the repository and the reference")

        // MARK: Settings
        let suite = "nocci-code-review-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        check(ReviewSettings.load(from: defaults) == ReviewSettings() && ReviewSettings().agent == .claude
              && ReviewSettings().prompt == ReviewSettings.defaultPrompt,
              "Nothing saved loads Claude Code and the default prompt")
        check(ReviewSettings.defaultPrompt.hasPrefix("Do a code review of {kind} {reference} in {repo}: {url}\n")
              && ReviewSettings.defaultPrompt.contains("check the code itself"),
              "The default prompt names the pull request, its link, and asks for the code to be checked")
        check(ReviewSettings.defaultPrompt.contains("untrusted") && ReviewSettings.defaultPrompt.contains("don't check out")
              && !ReviewSettings.defaultPrompt.contains("{title}"),
              "The default prompt treats the pull request's own text as untrusted, reads it without checking it out, and leaves the title out")
        var custom = ReviewSettings(agent: .codex, prompt: "Review {url}\nCarefully.")
        custom.save(to: defaults)
        check(ReviewSettings.load(from: defaults) == custom, "Agent and prompt round-trip")
        check(defaults.string(forKey: "pullRequests.review.agent") == "codex"
              && defaults.string(forKey: "pullRequests.review.prompt") == "Review {url}\nCarefully.",
              "Both are stored under the documented keys")
        defaults.set("gemini", forKey: "pullRequests.review.agent")
        check(ReviewSettings.load(from: defaults).agent == .claude, "An unknown stored agent loads as Claude Code")
        check(ReviewSettings(prompt: "").template == ReviewSettings.defaultPrompt
              && ReviewSettings(prompt: " \n\t ").template == ReviewSettings.defaultPrompt
              && ReviewSettings(prompt: " x ").template == " x ",
              "An empty or blank prompt runs the default; any other runs exactly as typed")
        custom.prompt = ""
        custom.save(to: defaults)
        check(ReviewSettings.load(from: defaults).prompt == "", "An empty prompt is kept as typed")

        // MARK: Git config
        let config = """
            [core]
            \tbare = false
            \turl = https://example.com/not/a/remote.git
            [remote "origin"]
            \turl = git@github.com:me/repo.git
            \tpushurl = https://github.com/me/push.git
            \tfetch = +refs/heads/*:refs/remotes/origin/*
            [Remote "Upstream"] # the original
            \tURL = "https://github.com/owner/repo.git" ; quoted
            [remote]
            \turl = https://github.com/bare/section.git
            [remote.old]
            \turl=ssh://git@gitlab.example.com:2222/group/sub/app.git
            [branch "main"]
            \tremote = origin
            \turl = https://github.com/branch/section.git
            # [remote "commented"]
            ;\turl = https://github.com/commented/out.git
            """
        check(CodeReviewRules.remoteURLs(config: config)
              == ["git@github.com:me/repo.git", "https://github.com/owner/repo.git",
                  "ssh://git@gitlab.example.com:2222/group/sub/app.git"],
              "Only the url of each named remote section is read")
        check(CodeReviewRules.remoteURLs(config: "[remote \"o\"]\r\n\turl = https://h.com/a/b\r\n") == ["https://h.com/a/b"],
              "CRLF line ends are accepted")
        check(CodeReviewRules.remoteURLs(config: "[remote \"o\"]\n\turl = \"https://h.com/a#b\" # c\n\turl = x\\\"y\n")
              == ["https://h.com/a#b", "x\"y"],
              "A # inside quotes is kept, one outside starts a comment, and a backslash escapes")
        check(CodeReviewRules.remoteURLs(config: "").isEmpty && CodeReviewRules.remoteURLs(config: "\u{0}\u{1}garbage").isEmpty,
              "An empty or garbage config has no remotes")

        // MARK: Remote URLs
        func at(_ host: String, _ path: String) -> RemoteLocation { RemoteLocation(host: host, path: path) }
        check(CodeReviewRules.location(ofRemote: "https://github.com/owner/repo.git") == at("github.com", "owner/repo"),
              "https with .git")
        check(CodeReviewRules.location(ofRemote: "https://me:ghp_secret@GitHub.com/owner/repo/") == at("github.com", "owner/repo"),
              "An embedded user and token are dropped, the host lowercased and a trailing slash removed")
        check(CodeReviewRules.location(ofRemote: "http://gitlab.example.com/group/app") == at("gitlab.example.com", "group/app"),
              "http")
        check(CodeReviewRules.location(ofRemote: "ssh://git@gitlab.example.com:2222/group/sub/app.git")
              == at("gitlab.example.com", "group/sub/app"), "ssh with a port")
        check(CodeReviewRules.location(ofRemote: "git+ssh://git@github.com/owner/repo.git") == at("github.com", "owner/repo")
              && CodeReviewRules.location(ofRemote: "git://github.com/owner/repo.git") == at("github.com", "owner/repo"),
              "git+ssh and git")
        check(CodeReviewRules.location(ofRemote: "git@github.com:owner/repo.git") == at("github.com", "owner/repo")
              && CodeReviewRules.location(ofRemote: "github.com:owner/repo") == at("github.com", "owner/repo")
              && CodeReviewRules.location(ofRemote: "git@gitlab.example.com:/group/app.git/") == at("gitlab.example.com", "group/app"),
              "The scp form, with and without a user")
        check(["/srv/git/repo.git", "../repo", "file:///srv/repo.git", "ftp://h.com/a/b", "https://", "git@github.com:", "", "garbage"]
                .allSatisfy { CodeReviewRules.location(ofRemote: $0) == nil },
              "Local paths, other schemes and garbage give nothing")

        // MARK: Matching
        check(CodeReviewRules.location(of: github) == at("github.com", "owner/repo")
              && CodeReviewRules.location(of: gitlab) == at("gitlab.example.com", "group/sub/app"),
              "A pull request's host is compared without its port")
        check(CodeReviewRules.matches("git@github.com:Owner/Repo.git", github)
              && CodeReviewRules.matches("https://GITHUB.com/owner/repo", github),
              "Host and path compare without case")
        check(!CodeReviewRules.matches("git@github.com:owner/repo-fork.git", github)
              && !CodeReviewRules.matches("git@gitlab.com:owner/repo.git", github)
              && !CodeReviewRules.matches("git@github.com:owner/repo/extra.git", github)
              && !CodeReviewRules.matches("/local/owner/repo", github),
              "Another path, another host, a deeper path or a local path never match")
        check(CodeReviewRules.matches("ssh://git@gitlab.example.com:2222/group/sub/app.git", gitlab)
              && CodeReviewRules.matches("https://gitlab.example.com:8443/group/sub/app.git", gitlab),
              "A GitLab host with a port matches its SSH and https remotes, nested groups included")
        let remotes: [String: [String]] = ["/code/fork": ["git@github.com:me/repo.git", "git@github.com:owner/repo.git"],
                                           "/code/newer": ["https://github.com/owner/repo.git"],
                                           "/code/other": ["git@github.com:owner/other.git"]]
        var asked: [String] = []
        let lookup: (String) -> [String] = { asked.append($0); return remotes[$0] ?? [] }
        check(CodeReviewRules.clone(for: github, in: ["/code/other", "/code/fork", "/code/newer"], remotes: lookup) == "/code/fork"
              && asked == ["/code/other", "/code/fork"],
              "The first repo in order with a matching remote wins, an upstream remote counting, and later repos are not read")
        check(CodeReviewRules.clone(for: github, in: ["/code/other"], remotes: lookup) == nil
              && CodeReviewRules.clone(for: github, in: [], remotes: lookup) == nil,
              "No match, or no repos, gives no clone")

        // MARK: Config location
        check(CodeReviewRules.configPath(gitDirectory: "/r/.git", commondir: nil) == "/r/.git/config"
              && CodeReviewRules.configPath(gitDirectory: "/r/.git", commondir: " \n") == "/r/.git/config",
              "A plain repo's config")
        check(CodeReviewRules.configPath(gitDirectory: "/r/.git/worktrees/wt", commondir: "../..\n") == "/r/.git/config"
              && CodeReviewRules.configPath(gitDirectory: "/w/.git/worktrees/wt", commondir: "/r/.git") == "/r/.git/config",
              "A linked worktree reads the shared config, relative or absolute")

        print("\(checks) code review checks passed")
    }
}
