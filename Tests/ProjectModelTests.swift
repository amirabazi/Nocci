import Foundation
import Combine

// Drives the real Projects model through a real UsageModel, with an injected
// scanner, launcher, programs, apps and clock. No folder is read, nothing is
// opened, and no preference outside a temporary suite is written.
@main
struct ProjectModelTests {
    static func main() {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            guard condition() else { fatalError("FAIL: \(label)") }
            checks += 1
        }
        let suite = "nocci-project-model-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let home = "/Users/someone", code = home + "/Coding", work = home + "/Work"
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        func project(_ name: String, repo: Bool = true, minutes: Double? = nil, root: String = code) -> Project {
            Project(path: root + "/" + name, name: name, root: root, isRepo: repo,
                    activity: minutes.map { clock.addingTimeInterval(-$0 * 60) })
        }
        var results: [[String]: DiscoveryResult] = [
            [code]: DiscoveryResult(projects: [project("notes", repo: false), project("old", minutes: 600), project("new", minutes: 1)],
                                    folders: [code: .available]),
            [code, work]: DiscoveryResult(projects: [project("new", minutes: 1), project("api", minutes: 30, root: work)],
                                          folders: [code: .available, work: .available]),
        ]
        var queued: [() -> Void] = []
        func drain() { while !queued.isEmpty { queued.removeFirst()() } }
        var scans: [[String]] = []
        var launches: [LaunchRequest] = []
        var answer: Result<Void, LaunchFailure> = .success(())
        var holding = false
        var held: [(Result<Void, LaunchFailure>) -> Void] = []
        var programs: [ProjectAgent: String] = [.claude: "/bin/claude", .codex: "/bin/codex"]
        let iTerm = URL(fileURLWithPath: "/Apps/iTerm.app")
        var apps: [LaunchTarget: URL] = [.terminal: URL(fileURLWithPath: "/Apps/Terminal.app"), .iterm: iTerm,
                                         .vscode: URL(fileURLWithPath: "/Apps/Visual Studio Code.app")]
        var existing: Set<String> = []
        var revealed: [URL] = []
        var folderOpens: [([URL], URL)] = []
        let tab = CurrentValueSubject<PanelTab, Never>(.usage)
        let usage = UsageModel(fetchCodex: { _ in }, loadClaude: { $0(nil) },
                               inspectClaude: { _ in .notConfigured }, defaults: defaults)
        let model = ProjectModel(usage: usage, tab: tab.eraseToAnyPublisher(), defaults: defaults,
                                 scanner: { folders in scans.append(folders); return results[folders] ?? DiscoveryResult() },
                                 launch: { request, done in
                                     launches.append(request)
                                     if holding { held.append(done) } else { done(answer) }
                                 },
                                 program: { programs[$0] }, application: { apps[$0] },
                                 appName: { $0.deletingPathExtension().lastPathComponent },
                                 folderExists: { existing.contains($0) },
                                 reveal: { revealed.append($0) },
                                 openFolder: { items, application, done in folderOpens.append((items, application)); done(true) },
                                 home: home, now: { clock },
                                 io: { queued.append($0) }, main: { $0() })

        // MARK: Off
        tab.send(.projects)
        usage.expanded = true
        drain()
        check(scans.isEmpty && model.projects.isEmpty && !model.settings.enabled, "Nothing is read while the feature is off")
        check(defaults.object(forKey: "projects.enabled") == nil, "Nothing is saved until something changes")

        // MARK: On
        model.settings.enabled = true
        check(scans.isEmpty && queued.isEmpty && defaults.bool(forKey: "projects.enabled"),
              "Turning on with no folders saves the switch and scans nothing")
        check(model.emptyText == "Add a folder in Settings › Projects.", "With no folders the tile points to Settings")
        check(model.addFolder(code), "A folder is added")
        check(!model.addFolder(code + "/"), "The same folder is refused")
        check(queued.count == 1 && model.emptyText == "Reading folders…", "Adding a folder starts one scan")
        drain()
        check(scans == [[code]], "The chosen folder is scanned")
        check(model.projects.map(\.name) == ["new", "old", "notes"] && model.scanned && model.folderStates == [code: .available],
              "The list is shown in order")
        check(defaults.stringArray(forKey: "projects.folders") == [code], "The folder is saved")

        // MARK: When scans run
        tab.send(.usage); tab.send(.projects); drain()
        check(scans.count == 1, "Showing the tab again within 30 seconds does not scan")
        clock += 31
        tab.send(.usage); tab.send(.projects); drain()
        check(scans.count == 2, "Showing the tab after 30 seconds scans again")
        usage.expanded = false; clock += 31; usage.expanded = true; drain()
        check(scans.count == 3, "Expanding the panel while it shows Projects scans")
        tab.send(.usage); usage.expanded = false; clock += 31; usage.expanded = true; drain()
        check(scans.count == 3, "Expanding on another tab does not scan")

        // MARK: A folder change during a scan
        tab.send(.projects)
        check(queued.count == 1, "Showing the tab starts a scan")
        check(model.addFolder(work), "A second folder is added during the scan")
        check(queued.count == 1, "No second scan runs at the same time")
        drain()
        check(Array(scans.suffix(2)) == [[code], [code, work]], "The stale scan is dropped and one replacement runs")
        check(model.projects.map(\.name) == ["new", "api"] && model.folderStates == [code: .available, work: .available],
              "Only the replacement's answer is shown")
        model.removeFolder(work)
        drain()
        check(scans.last == [code] && defaults.stringArray(forKey: "projects.folders") == [code] && model.projects.count == 3,
              "Removing a folder saves and scans again")

        // MARK: Off during a scan
        clock += 31
        tab.send(.usage); tab.send(.projects)
        model.settings.enabled = false
        drain()
        check(model.projects.isEmpty && !model.scanned, "Turning off clears the list and drops a scan in flight")
        model.settings.enabled = true
        drain()
        check(model.projects.map(\.name) == ["new", "old", "notes"], "Turning on again scans")

        // MARK: Composing
        let new = model.projects[0], old = model.projects[1]
        model.open(new)
        check(model.selected == new && model.composing && model.prompt == "" && model.footerText == "Return starts · Escape goes back",
              "Clicking a project opens the compose view")
        model.prompt = "fix the tests"
        model.endCompose()
        check(model.selected == nil && model.prompt == "" && !model.composing, "Back returns to the list")
        model.open(new)
        check(model.prompt == "fix the tests", "The unsent prompt is still there")
        model.open(old)
        check(model.selected == old && model.prompt == "", "Another project starts with its own empty prompt")
        model.open(new)
        check(model.prompt == "fix the tests", "Switching projects keeps each draft")
        tab.send(.usage)
        check(model.selected == nil, "Switching tabs ends composing")
        tab.send(.projects)
        model.open(new)
        check(model.prompt == "fix the tests", "The draft survives a tab switch")

        // MARK: Ending compose from inside ending compose keeps the draft
        //
        // AppDelegate hands the keyboard back when `selected` clears, which
        // resigns key and calls endCompose again from inside the first call.
        var reentry = Set<AnyCancellable>()
        model.$selected.map { $0 != nil }.removeDuplicates().dropFirst()
            .sink { composing in if !composing { model.endCompose() } }
            .store(in: &reentry)
        model.prompt = "keep me"
        model.endCompose()
        model.open(new)
        check(model.prompt == "keep me", "Escape keeps the draft even when ending compose is re-entered")
        model.prompt = "and me"
        tab.send(.usage); tab.send(.projects)
        model.open(new)
        check(model.prompt == "and me", "A tab switch keeps the draft even when ending compose is re-entered")
        reentry.removeAll()
        model.prompt = "fix the tests"

        // MARK: Apps
        check(model.targets == [.terminal, .iterm, .vscode] && model.target == .terminal,
              "Claude Code offers installed terminals and VS Code, Terminal first")
        check(model.targetNames[.iterm] == "iTerm", "Apps are named as Finder names them")
        model.choose(target: .iterm)
        check(model.target == .iterm && defaults.string(forKey: "projects.app.claude") == "iterm", "The chosen app is remembered")
        model.choose(agent: .codex)
        check(model.targets == [.terminal, .iterm] && model.target == .terminal && defaults.string(forKey: "projects.agent") == "codex",
              "Codex never offers VS Code")
        apps[.codexApp] = URL(fileURLWithPath: "/Apps/Codex.app")
        model.refreshAvailability()
        check(model.targets == [.terminal, .iterm, .codexApp], "An installed Codex app is offered for Codex")
        model.choose(agent: .claude)
        check(model.target == .iterm, "Each agent keeps its own app")
        apps[.iterm] = nil
        model.refreshAvailability()
        check(model.target == .terminal, "A remembered app that is gone falls back to the first installed one")
        apps[.iterm] = iTerm
        model.refreshAvailability()
        check(model.target == .iterm, "It comes back when the app does")

        // MARK: Starting
        existing = [new.path]
        model.prompt = "  fix the tests  "
        model.start()
        check(launches == [LaunchRequest(project: new.path, agent: .claude, target: .iterm, program: "/bin/claude",
                                         application: iTerm, prompt: "  fix the tests  ")],
              "Start hands the launcher the project, agent, app, program and the prompt as typed")
        check(model.selected == nil && model.status == nil && !model.launching && model.endedByLaunch,
              "A successful start ends composing and says why")
        model.open(new)
        check(model.prompt == "" && !model.endedByLaunch, "A started prompt is not kept as a draft")
        model.prompt = " \n "
        model.start()
        check(launches.last?.prompt == "", "A blank prompt starts the session with no prompt")

        model.open(old)
        let scansBefore = scans.count
        model.start()
        drain()
        check(model.status == "This folder no longer exists." && model.selected == old && launches.count == 2,
              "A folder that has gone is reported and nothing starts")
        check(scans.count == scansBefore + 1, "A folder that has gone triggers a rescan")

        existing.insert(old.path)
        programs[.claude] = nil
        model.choose(target: .iterm)
        model.refreshAvailability()
        check(model.statusLine == ProjectModel.StatusLine(text: "Claude Code wasn’t found. Choose it in Settings › Projects.",
                                                          isProblem: true) && !model.canStart,
              "A missing program is explained before Start is pressed")
        model.start()
        check(launches.count == 2, "Nothing starts without the program a terminal needs")
        model.choose(target: .vscode)
        check(model.canStart && model.statusLine == ProjectModel.StatusLine(text: ProjectRules.note(for: .vscode)!, isProblem: false),
              "VS Code does not need the claude program")
        model.start()
        check(launches.count == 3 && launches.last?.target == .vscode && launches.last?.program == nil,
              "A VS Code start carries no program")
        programs[.claude] = "/bin/claude"
        model.open(old)
        model.choose(agent: .codex)
        programs[.codex] = nil
        model.refreshAvailability()
        check(model.statusLine?.text == "Codex wasn’t found. Choose it in Settings › Providers.",
              "A missing Codex points to where Codex is chosen")
        programs[.codex] = "/bin/codex"
        model.choose(agent: .claude)
        model.choose(target: .iterm)

        model.prompt = "a\u{0}b"
        model.start()
        check(model.status == PromptRefusal.nul.message(for: .claude) && launches.count == 3, "A NUL character is refused")
        model.prompt = String(repeating: "x", count: 40_000)
        model.start()
        check(model.status == PromptRefusal.tooLong(limit: 32_768).message(for: .claude) && launches.count == 3,
              "A pasted prompt over the limit is refused and nothing is opened")

        model.prompt = "x"
        answer = .failure(.notOpened)
        model.start()
        check(model.status == "iTerm couldn’t be opened." && model.selected == old && model.prompt == "x" && launches.count == 4,
              "A failed start keeps composing with the reason")
        answer = .failure(.notPrepared)
        model.start()
        check(model.status == "Nocci couldn’t prepare the session." && launches.count == 5, "A script that could not be written is reported")
        answer = .success(())

        holding = true
        model.prompt = "later"
        model.start()
        model.start()
        check(launches.count == 6 && model.launching && !model.canStart, "A second Return while starting starts nothing")
        model.endCompose()
        held.removeFirst()(.success(()))
        check(!model.launching, "The start finished")
        model.open(old)
        check(model.prompt == "", "A prompt that did start is not kept, even when composing ended first")
        holding = false

        // MARK: Demo
        model.open(new)
        usage.toggleDemo()
        check(model.selected == nil && model.demo && model.projects == ProjectSamples.projects(now: clock)
              && model.footerText == "Sample data", "Sample data ends composing and shows samples")
        let demoScans = scans.count
        tab.send(.usage); tab.send(.projects); clock += 31; usage.expanded = false; usage.expanded = true; drain()
        check(scans.count == demoScans, "Demo never reads folders")
        model.open(model.projects[0])
        check(model.selected == nil, "Samples cannot be started")
        usage.toggleDemo()
        drain()
        check(!model.demo && model.projects.map(\.name) == ["new", "old", "notes"] && scans.count == demoScans + 1,
              "Leaving demo scans the real folders again")

        // MARK: Turning off ends composing
        model.open(new)
        model.settings.enabled = false
        check(model.selected == nil && model.projects.isEmpty, "Turning the feature off ends composing")
        model.settings.enabled = true
        drain()

        // MARK: The row menu
        apps[.otherTerminal] = URL(fileURLWithPath: "/Apps/Ghostty.app")
        tab.send(.usage); tab.send(.projects)
        check(model.installed.contains(.otherTerminal), "Showing the tab looks up installed apps, so the menu can name them")
        apps[.otherTerminal] = nil
        model.refreshAvailability()
        let folder = URL(fileURLWithPath: new.path, isDirectory: true)
        model.revealInFinder(new)
        check(revealed == [folder], "Reveal in Finder shows the project folder")
        check(model.shellTarget == .iterm, "A plain shell uses the remembered terminal")
        model.openShell(new)
        check(folderOpens.count == 1 && folderOpens[0].0 == [folder] && folderOpens[0].1 == iTerm,
              "Open in the terminal opens the folder there")
        model.choose(target: .vscode)
        check(model.shellTarget == .terminal, "With VS Code remembered, a plain shell uses the first installed terminal")
        model.openInEditor(new)
        check(folderOpens.count == 2 && folderOpens[1].0 == [folder] && folderOpens[1].1 == apps[.vscode],
              "Open in VS Code opens the folder there")
        model.choose(target: .iterm)
        existing = [new.path]
        let menuScans = scans.count
        model.revealInFinder(old); model.openShell(old); model.openInEditor(old)
        drain()
        check(revealed.count == 1 && folderOpens.count == 2 && scans.count == menuScans + 1,
              "A folder that has gone opens nothing and rescans")
        usage.toggleDemo()
        model.revealInFinder(model.projects[0]); model.openShell(model.projects[0]); model.openInEditor(model.projects[0])
        check(revealed.count == 1 && folderOpens.count == 2, "Sample projects open nothing")
        usage.toggleDemo()
        drain()

        // MARK: Text
        check(model.labels == ProjectRules.labels(for: model.projects, home: home), "Labels follow the rule")
        check(model.footerText == "3 projects in ~/Coding", "The footer counts the projects in the chosen folders")
        let quietScans = scans.count
        model.removeFolder(code)
        check(model.projects.isEmpty && model.emptyText == "Add a folder in Settings › Projects." && scans.count == quietScans,
              "Removing the last folder empties the list without a scan")

        // MARK: Programs and terminals are saved
        model.setClaudePath("/opt/claude")
        model.setOtherTerminal("/Apps/Ghostty.app")
        check(defaults.string(forKey: ClaudeProgram.preferenceKey) == "/opt/claude"
              && defaults.string(forKey: ProjectLauncher.otherTerminalKey) == "/Apps/Ghostty.app",
              "The chosen claude and terminal are saved")
        model.clearOtherTerminal()
        check(defaults.object(forKey: ProjectLauncher.otherTerminalKey) == nil, "Removing the terminal forgets it")

        // MARK: An other terminal that Nocci already offers
        apps[.otherTerminal] = iTerm
        model.refreshAvailability()
        check(!model.installed.contains(.otherTerminal) && model.targets.filter { model.targetNames[$0] == "iTerm" }.count == 1,
              "A terminal Nocci already offers is never listed twice")
        apps[.otherTerminal] = nil
        model.refreshAvailability()
        check(!model.setOtherTerminal(iTerm.path) && defaults.object(forKey: ProjectLauncher.otherTerminalKey) == nil,
              "Choosing iTerm or Terminal as the other terminal is refused and nothing is saved")
        check(model.setOtherTerminal("/Apps/Ghostty.app") && defaults.string(forKey: ProjectLauncher.otherTerminalKey) == "/Apps/Ghostty.app",
              "Any other app is accepted")
        model.clearOtherTerminal()

        // MARK: Starting in Nocci
        tab.send(.projects)
        // `// MARK: Text` removed the only folder; the notch checks below need its projects listed and scanned.
        model.addFolder(code)
        drain()
        check(model.scanned && model.projects.contains { $0.path == new.path },
              "The projects are listed again for the notch checks")
        var nocciStarts: [(start: TerminalStart, place: TerminalPlace, tab: UUID)] = []
        model.refreshAvailability()
        check(!model.installed.contains(.nocci), "Nocci is not offered until the app can host a session")
        model.onStartInNocci = { start, place in
            let id = UUID()
            nocciStarts.append((start, place, id))
            return id
        }
        model.refreshAvailability()
        check(model.installed.last == .nocci && model.targetNames[.nocci] == "Nocci (experimental)",
              "Nocci is offered last, under its name, marked experimental")
        existing.insert(new.path)
        model.choose(agent: .claude)
        model.open(new)
        model.choose(target: .nocci)
        model.prompt = "fix the tests"
        let launchesBefore = launches.count
        model.start()
        check(nocciStarts.map { $0.start } == [TerminalStart(folder: new.path, label: "new", agent: .claude, program: "/bin/claude",
                                                             prompt: "fix the tests")] && nocciStarts.map { $0.place } == [.notch],
              "Start hands Nocci the folder, label, agent, program and prompt, for the notch")
        let newTab = nocciStarts[0].tab
        check(launches.count == launchesBefore && model.selected == nil && !model.endedByLaunch,
              "Nothing else is launched, and compose ends without handing the keyboard back")
        check(model.notchSessions == [new.path: NotchSession(tab: newTab, title: "new · Claude Code", waiting: false)]
              && model.shownFolder == new.path && model.showingTerminal && model.shownTab == newTab && model.typing,
              "The tile shows the new session at once, with the keyboard")
        check(model.footerText == "Click to type · Back keeps it running", "The footer says the session keeps running")
        model.backToList()
        check(!model.typing && !model.showingTerminal && model.shownFolder == nil && model.notchSessions[new.path] != nil,
              "Back returns to the list with the session still running")
        model.open(new)
        check(model.selected == nil && model.shownFolder == new.path && model.showingTerminal && !model.typing,
              "Clicking a project with a notch session shows its terminal without taking the keyboard")
        model.beganTyping()
        check(model.typing, "A click inside the terminal gives it the keyboard")
        model.endTyping()
        check(!model.typing && model.showingTerminal, "Clicking outside gives the keyboard back and keeps the terminal shown")
        model.beganTyping()
        usage.expanded = false
        check(!model.typing && model.shownFolder == new.path, "Collapsing gives the keyboard back and keeps the terminal remembered")
        usage.expanded = true
        model.backToList()
        model.compose(new)
        check(model.selected == new && model.prompt == "", "New Session… composes even with a notch session, and a sent prompt is not a draft")
        model.prompt = "and the docs"
        model.start()
        check(nocciStarts.count == 2 && nocciStarts[1].place == .window && model.endedByLaunch && model.selected == nil
              && model.notchSessions.count == 1 && model.shownFolder == nil,
              "A second Nocci start in the same project opens in the window")
        model.compose(new)
        programs[.claude] = nil
        model.refreshAvailability()
        check(model.statusLine?.text == "Claude Code wasn’t found. Choose it in Settings › Projects." && !model.canStart,
              "Nocci needs the agent's program too")
        model.start()
        check(nocciStarts.count == 2, "Nothing starts without the program")
        programs[.claude] = "/bin/claude"
        model.refreshAvailability()
        model.endCompose()

        // MARK: A notch session while the tile is elsewhere
        model.setNotchSessions([new.path: NotchSession(tab: newTab, title: "new · Claude Code", waiting: true)])
        check(model.notchSessions[new.path]?.waiting == true && model.shownFolder == nil,
              "A waiting session reaches its row, and the list stays shown")
        model.open(new)
        tab.send(.usage)
        check(!model.showingTerminal && model.shownTab == nil && model.shownFolder == new.path,
              "On another tab the terminal is not shown but is remembered")
        tab.send(.projects)
        check(model.showingTerminal && model.shownTab == newTab && !model.typing,
              "Coming back shows the same terminal, without taking the keyboard")
        model.beganTyping()
        tab.send(.usage)
        check(!model.typing, "A tab switch gives the keyboard back")
        tab.send(.projects)
        var moved: [UUID] = []
        model.onMoveToWindow = { moved.append($0) }
        usage.toggleDemo()
        check(model.demo && !model.showingTerminal && model.shownFolder == new.path && model.notchSessions[new.path] != nil
              && moved.isEmpty, "Demo mode hides the terminal without moving or forgetting it")
        model.open(model.projects[0])
        check(!model.showingTerminal && model.selected == nil, "A sample row never shows a terminal")
        usage.toggleDemo()
        check(model.showingTerminal && moved.isEmpty, "Leaving demo shows it again before the rescan lands")
        drain()
        check(model.showingTerminal && moved.isEmpty && model.notchSessions[new.path] != nil,
              "The rescan still lists its project, so it stays in the notch")

        // MARK: Giving the keyboard back from inside giving it back
        //
        // AppDelegate hands the keyboard back when `typing` clears, which
        // resigns the panel and calls endTyping again from inside the change.
        var typingReentry = Set<AnyCancellable>()
        model.$typing.removeDuplicates().dropFirst()
            .sink { typing in if !typing { model.endTyping() } }
            .store(in: &typingReentry)
        model.beganTyping()
        model.endTyping()
        check(!model.typing && model.showingTerminal, "Ending typing from inside its own change is ignored")
        typingReentry.removeAll()

        // MARK: A session whose tab or project has gone
        let ghost = UUID()
        model.setNotchSessions([new.path: NotchSession(tab: newTab, title: "new", waiting: false),
                                code + "/gone": NotchSession(tab: ghost, title: "gone", waiting: false)])
        check(moved == [ghost] && Array(model.notchSessions.keys) == [new.path] && model.showingTerminal,
              "A session whose project is no longer listed moves to the window")
        model.setNotchSessions([:])
        check(model.shownFolder == nil && !model.showingTerminal, "A shown terminal whose tab has gone returns the tile to the list")

        // A plain folder in which the agent made a repository is listed as a
        // group from then on. While its terminal is on screen it stays in the
        // notch; back on the list, where it has no row, it moves to the window,
        // where it can still be reached.
        model.setNotchSessions([new.path: NotchSession(tab: newTab, title: "new", waiting: false)])
        model.open(new)
        let listed = results[[code]]
        results[[code]] = DiscoveryResult(projects: [project("notes", repo: false), project("old", minutes: 600)],
                                          folders: [code: .available])
        let wasExisting = existing.contains(new.path)
        existing.insert(new.path)
        model.scan(force: true)
        drain()
        check(model.showingTerminal && model.notchSessions[new.path] != nil && moved == [ghost],
              "A shown session whose folder still exists stays in the notch when a rescan no longer lists it")
        model.backToList()
        check(moved == [ghost, newTab] && model.notchSessions[new.path] == nil && !model.showingTerminal,
              "Back on the list, where it has no row, it moves to the window")
        results[[code]] = listed
        if !wasExisting { existing.remove(new.path) }
        model.scan(force: true)
        drain()

        // MARK: Open in window and Close
        model.setNotchSessions([new.path: NotchSession(tab: newTab, title: "new", waiting: false)])
        model.open(new)
        model.beganTyping()
        model.moveShownToWindow()
        check(moved.last == newTab && model.shownFolder == nil && !model.typing && model.notchSessions.isEmpty,
              "Open in window hands the tab over and returns the tile to the list")
        var closing: [UUID] = []
        var keep = true
        model.onCloseSession = { closing.append($0); return !keep }
        model.setNotchSessions([new.path: NotchSession(tab: newTab, title: "new", waiting: false)])
        model.open(new)
        model.closeShown()
        check(closing == [newTab] && model.showingTerminal && model.notchSessions[new.path] != nil,
              "Close asks, and keeping the session keeps it shown")
        keep = false
        model.closeShown()
        check(closing == [newTab, newTab] && !model.showingTerminal && model.shownFolder == nil && model.notchSessions.isEmpty,
              "Closing returns the tile to the list")

        // MARK: Projects turned off, and the last folder removed
        model.setNotchSessions([new.path: NotchSession(tab: newTab, title: "new", waiting: false)])
        model.open(new)
        moved = []
        model.settings.enabled = false
        check(moved == [newTab] && model.notchSessions.isEmpty && model.shownFolder == nil && !model.showingTerminal,
              "Turning Projects off moves every notch session to the window")
        model.settings.enabled = true
        drain()
        model.setNotchSessions([new.path: NotchSession(tab: newTab, title: "new", waiting: false)])
        moved = []
        model.removeFolder(code)
        check(moved == [newTab] && model.notchSessions.isEmpty, "Removing the last folder moves its notch sessions to the window")
        model.addFolder(code)
        drain()
        model.choose(target: .terminal)

        // MARK: The appearance preview never saves
        let quietSuite = suite + "-preview"
        let quiet = UserDefaults(suiteName: quietSuite)!
        let preview = ProjectModel(usage: usage, tab: tab.eraseToAnyPublisher(), defaults: quiet, saves: false,
                                   scanner: { _ in DiscoveryResult() }, launch: { _, done in done(.success(())) },
                                   program: { _ in nil }, application: { _ in nil }, home: home, now: { clock },
                                   io: { $0() }, main: { $0() })
        preview.settings.enabled = true
        preview.addFolder(code)
        preview.choose(agent: .codex)
        preview.setClaudePath("/x")
        preview.setOtherTerminal("/y")
        check(!quiet.dictionaryRepresentation().keys.contains { $0.hasPrefix("projects.") },
              "The appearance preview's model never saves")
        UserDefaults().removePersistentDomain(forName: quietSuite)

        print("\(checks) project model checks passed")
    }
}
