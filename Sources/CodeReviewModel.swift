import Foundation
import Combine
import Darwin

/// Reads the git config files Code Review matches remotes against. Runs off
/// the main thread and never runs `git`.
enum CodeReviewReader {
    static let configLimit = 65_536
    static let commondirLimit = 4096

    /// A project's remote URLs, or none when anything cannot be read.
    static func remotes(_ project: String) -> [String] {
        guard let directory = ProjectScanner.gitDirectory(project) else { return [] }
        let commondirPath = ProjectRules.join(directory, "commondir")
        var commondir: String?
        if FileManager.default.fileExists(atPath: commondirPath) {
            guard let text = read(commondirPath, limit: commondirLimit) else { return [] }
            commondir = text
        }
        guard let config = read(CodeReviewRules.configPath(gitDirectory: directory, commondir: commondir),
                                limit: configLimit) else { return [] }
        return CodeReviewRules.remoteURLs(config: config)
    }

    /// Nil for anything but a regular file at most `limit` bytes of UTF-8.
    /// Symlinks are resolved first, so a link to a small regular file still
    /// works; the resolved path is then opened non-blocking and refusing a
    /// symlink, so a FIFO can never block this call and a link swapped in
    /// after resolving is refused rather than followed.
    static func read(_ path: String, limit: Int) -> String? {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let descriptor = resolved.withCString { open($0, O_RDONLY | O_NONBLOCK | O_NOFOLLOW) }
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= limit,
              let data = try? handle.read(upToCount: limit + 1), data.count <= limit else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// The Code Review button: its settings, whether it can run, and starting one
/// review at a time in a Nocci terminal tab. It follows `UsageModel`'s demo
/// state and expansion and `PullRequestModel`'s tab and switch, like the other
/// models. Main thread only.
final class CodeReviewModel: ObservableObject {
    typealias Executor = (@escaping () -> Void) -> Void
    typealias Scan = ([String]) -> DiscoveryResult

    static let folderFailure = "Nocci couldn’t prepare the review folder."
    /// A second click on the same
    /// pull request within this long of that pull request's review starting
    /// is ignored. A different row starts at once.
    static let repeatGap: TimeInterval = 1

    @Published var settings: ReviewSettings {
        didSet {
            precondition(Thread.isMainThread)
            guard settings != oldValue else { return }
            if saves { settings.save(to: defaults) }
            guard settings.agent != oldValue.agent else { return }
            generation = UUID()
            checkProgram()
        }
    }
    @Published private(set) var programFound = false
    @Published private(set) var resolving = false
    @Published private(set) var demo = false
    /// Set once Nocci's terminal can host a review; while nil nothing starts.
    var onStart: ((TerminalStart) -> Void)?
    /// Why a click started nothing, in the Projects wording.
    var onProblem: ((String) -> Void)?

    let reviewFolder: URL
    var canReview: Bool { !demo && !resolving && programFound && onStart != nil }
    var help: String {
        if demo { return "Sample data" }
        return programFound ? "Code review with \(settings.agent.title) (experimental)" : ProjectRules.missingProgram(settings.agent)
    }

    private let defaults: UserDefaults
    /// False for the appearance preview, which must never change saved choices.
    private let saves: Bool
    private let projectSettings: () -> ProjectSettings
    private let scanner: Scan
    private let remotes: (String) -> [String]
    private let findProgram: (ProjectAgent) -> String?
    private let folderExists: (String) -> Bool
    private let prepare: (URL) -> Bool
    private let now: () -> Date
    private let io: Executor
    private let main: Executor
    private var generation = UUID()
    private var pullRequestsOn = false
    private var tabShown = false
    private var observations = Set<AnyCancellable>()
    /// When each pull request's review last actually started, by its id
    /// (`PullRequest.id`). A dropped or refused start never lands here.
    private var lastStart: [String: Date] = [:]

    init(usage: UsageModel, pullRequests: PullRequestModel, defaults: UserDefaults = .standard, saves: Bool = true,
         projects: @escaping () -> ProjectSettings = { ProjectSettings() },
         scanner: @escaping Scan = ProjectScanner.scan,
         remotes: @escaping (String) -> [String] = CodeReviewReader.remotes,
         program: ((ProjectAgent) -> String?)? = nil,
         folderExists: @escaping (String) -> Bool = ProjectModel.liveFolderExists,
         reviewFolder: URL = Storage.directory.appendingPathComponent("Reviews"),
         prepare: @escaping (URL) -> Bool = CodeReviewModel.prepareFolder,
         now: @escaping () -> Date = Date.init,
         io: @escaping Executor = { DispatchQueue.global(qos: .userInitiated).async(execute: $0) },
         main: @escaping Executor = { DispatchQueue.main.async(execute: $0) }) {
        self.defaults = defaults
        self.saves = saves
        self.projectSettings = projects
        self.scanner = scanner
        self.remotes = remotes
        self.findProgram = program ?? { ProjectModel.liveProgram($0, defaults: defaults) }
        self.folderExists = folderExists
        self.reviewFolder = reviewFolder
        self.prepare = prepare
        self.now = now
        self.io = io
        self.main = main
        settings = ReviewSettings.load(from: defaults)
        // @Published sends before the property changes, so each sink uses the
        // value it is handed rather than reading the other model back.
        usage.$demo.removeDuplicates().sink { [weak self] demo in self?.setDemo(demo) }.store(in: &observations)
        pullRequests.$settings.map(\.enabled).removeDuplicates().sink { [weak self] enabled in
            guard let self else { return }
            self.pullRequestsOn = enabled
            if !enabled { self.generation = UUID() }
        }.store(in: &observations)
        pullRequests.$tab.removeDuplicates().sink { [weak self] tab in
            guard let self else { return }
            self.tabShown = tab == .pullRequests
            if self.tabShown { self.checkProgram() }
        }.store(in: &observations)
        usage.$expanded.removeDuplicates().sink { [weak self] expanded in
            guard let self, expanded, self.tabShown else { return }
            self.checkProgram()
        }.store(in: &observations)
    }

    /// File checks only: when the tab shows, the panel opens on it, the agent
    /// changes, and at each click.
    func checkProgram() {
        precondition(Thread.isMainThread)
        let found = findProgram(settings.agent) != nil
        if found != programFound { programFound = found }
    }

    /// The folder is found off the main thread; a start whose
    /// generation moved meanwhile is dropped. A second click on the same pull
    /// request within `repeatGap` of its review starting is ignored before
    /// anything else runs; other rows are unaffected.
    func review(_ item: PullRequest) {
        precondition(Thread.isMainThread)
        if let started = lastStart[item.id], now().timeIntervalSince(started) < Self.repeatGap { return }
        guard !demo, pullRequestsOn, !resolving, onStart != nil else { return }
        let agent = settings.agent
        guard let program = findProgram(agent) else {
            checkProgram()
            onProblem?(ProjectRules.missingProgram(agent))
            return
        }
        let prompt = CodeReviewRules.fill(settings.template, with: item)
        if let refusal = ProjectRules.refusal(for: prompt, agent: agent, target: .nocci) {
            onProblem?(refusal.message(for: agent))
            return
        }
        let projects = projectSettings()
        let roots = projects.enabled ? projects.folders : []
        let folder = reviewFolder.appendingPathComponent(CodeReviewRules.reviewPath(for: item))
        let start = TerminalStart(folder: folder.path, label: CodeReviewRules.label(for: item),
                                  agent: agent, program: program, prompt: prompt)
        let request = generation, scanner = scanner, remotes = remotes, prepare = prepare, main = main
        let id = item.id
        resolving = true
        io { [weak self] in
            let repos = roots.isEmpty ? [] : ProjectRules.ordered(scanner(roots).projects).filter(\.isRepo).map(\.path)
            let clone = CodeReviewRules.clone(for: item, in: repos, remotes: remotes)
            let ready = prepare(folder)
            main { self?.finish(request, id: id, start: start, clone: clone, ready: ready) }
        }
    }

    /// Nocci's own folders are readable only by the user.
    static func prepareFolder(_ folder: URL) -> Bool {
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            return true
        } catch {
            return false
        }
    }

    private func finish(_ request: UUID, id: String, start: TerminalStart, clone: String?, ready: Bool) {
        precondition(Thread.isMainThread)
        resolving = false
        guard request == generation, !demo, pullRequestsOn, let onStart else { return }
        var start = start
        if let clone, folderExists(clone) {
            start.folder = clone
        } else if !ready {
            onProblem?(Self.folderFailure)
            return
        }
        lastStart[id] = now()
        onStart(start)
    }

    private func setDemo(_ value: Bool) {
        precondition(Thread.isMainThread)
        guard value != demo else { return }
        demo = value
        generation = UUID()
    }
}
