import AppKit

final class FakeSession: TerminalProcess {
    let view = NSView()
    var agentRunning = true
    /// A program the shell runs after the agent, such as an editor.
    var otherProgram = false
    var programRunning: Bool { agentRunning || otherProgram }
    var waitingSince: Date?
    var onChange: (() -> Void)?
    var closed = 0
    var cleared = 0
    var fontSizes: [Double] = []
    func setFontSize(_ size: Double) { fontSizes.append(size) }
    func clearWait() { cleared += 1; waitingSince = nil }
    func miniView() -> NSView { NSView() }
    func close() { closed += 1; agentRunning = false }
}

// Drives the real terminal model with fake sessions, recorded questions and
// an isolated defaults suite. No process starts and nothing is shown.
@main
struct TerminalModelTests {
    static func main() {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            guard condition() else { fatalError("FAIL: \(label)") }
            checks += 1
        }
        let suite = "nocci-terminal-model-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        var made: [(start: TerminalStart, size: Double, tab: UUID, session: FakeSession)] = []
        var questions: [(question: String, action: String)] = []
        var answer = false
        var duringQuestion: (() -> Void)?
        var activations: [Bool] = []
        var shows = 0
        var programs: [ProjectAgent: String] = [.claude: "/bin/claude", .codex: "/bin/codex"]
        let existing: Set<String> = ["/p/api", "/p/web"]
        defaults.set(40.0, forKey: TerminalRules.fontSizeKey)
        let model = TerminalModel(defaults: defaults,
                                  makeSession: { start, size, tab in
                                      let session = FakeSession()
                                      made.append((start, size, tab, session))
                                      return session
                                  },
                                  confirm: { question, action in
                                      questions.append((question, action))
                                      duringQuestion?()
                                      return answer
                                  },
                                  findProgram: { programs[$0] }, folderExists: { existing.contains($0) })
        model.onActivationChange = { activations.append($0) }
        model.onShow = { shows += 1 }
        check(model.fontSize == 24, "A saved size is clamped on load")

        // MARK: Starting
        let api = TerminalStart(folder: "/p/api", label: "api", agent: .claude, program: "/bin/claude", prompt: "fix it")
        model.start(api)
        check(model.tabs.count == 1 && model.selection == model.tabs[0].id && model.tabs[0].start == api, "A start opens a selected tab")
        check(made.count == 1 && made[0].start == api && made[0].size == 24, "The session gets the start and the font size")
        check(activations == [true] && shows == 1, "The first tab makes Nocci a regular app and shows the window")
        check(model.title(for: model.tabs[0]) == "api · Claude Code", "The title names the running agent")
        let web = TerminalStart(folder: "/p/web", label: "web", agent: .codex, program: "/bin/codex", prompt: "")
        model.start(web)
        check(model.tabs.count == 2 && model.selection == model.tabs[1].id && activations == [true] && shows == 2,
              "A second start adds a tab without changing the app again")
        let revision = model.revision
        made[1].session.agentRunning = false
        made[1].session.onChange?()
        check(model.revision == revision + 1 && model.title(for: model.tabs[1]) == "web", "A session's change redraws its title")

        // MARK: Start page
        model.newTab()
        let page = model.selection
        check(model.tabs.count == 3 && model.selectedTab?.start == nil && model.title(for: model.tabs[2]) == "New Tab",
              "New Tab opens a start page")
        model.selection = model.tabs[0].id
        model.newTab()
        check(model.tabs.count == 3 && model.selection == page, "A second New Tab selects the open start page")
        model.startDraft()
        check(model.draftStatus == "Choose a project or a folder." && made.count == 2, "Start needs a folder")
        model.chooseDraft(folder: "/p/gone", label: "gone")
        model.startDraft()
        check(model.draftStatus == "This folder no longer exists." && made.count == 2, "A folder that has gone is refused")
        model.chooseDraft(folder: "/p/web", label: "web")
        check(model.draftStatus == nil, "Choosing a folder clears the message")
        programs[.codex] = nil
        model.draftAgent = .codex
        model.startDraft()
        check(model.draftStatus == "Codex wasn't found. Choose it in Settings › Providers." && made.count == 2,
              "A missing program is refused")
        programs[.codex] = "/bin/codex"
        model.draftPrompt = "  \n "
        model.startDraft()
        check(made.count == 3 && made[2].start == TerminalStart(folder: "/p/web", label: "web", agent: .codex, program: "/bin/codex", prompt: ""),
              "Start runs the chosen agent in the chosen folder, and a blank prompt is no prompt")
        check(model.tabs.count == 3 && model.tabs[2].id == page && model.tabs[2].start != nil && model.selection == page
              && model.draftStatus == nil && model.draftPrompt == "", "The start page's tab becomes the session")

        // MARK: Closing
        questions = []; answer = false
        check(!model.close(model.tabs[0].id) && model.tabs.count == 3 && made[0].session.closed == 0, "Declining keeps a running tab")
        check(questions.count == 1 && questions[0].question == "Close this tab? Claude Code is still running in api."
              && questions[0].action == "Close", "The question names the agent and the tab")
        answer = true
        let first = model.tabs[0].id, second = model.tabs[1].id
        model.selection = first
        check(model.close(first) && made[0].session.closed == 1 && model.tabs.count == 2 && model.selection == second,
              "Closing the selected tab selects the one to its right")
        let last = model.tabs[1].id
        model.selection = last
        check(model.close(last) && model.tabs.count == 1 && model.selection == model.tabs[0].id,
              "Closing the rightmost selected tab selects the one to its left")
        questions = []
        check(model.close(model.tabs[0].id) && questions.isEmpty, "A tab whose agent has ended closes without asking")
        check(model.tabs.isEmpty && model.selection == nil && activations == [true, false],
              "Closing the last tab makes Nocci an accessory app again")
        model.newTab()
        check(activations == [true, false, true], "A start page alone makes Nocci a regular app")
        model.closeSelected()
        check(model.tabs.isEmpty && activations == [true, false, true, false], "Closing an unstarted tab asks nothing")

        // MARK: The close button and quitting
        model.start(api); model.start(api)
        let a = made[made.count - 2].session, b = made[made.count - 1].session
        b.agentRunning = false
        questions = []; answer = false
        check(!model.closeAll() && model.tabs.count == 2 && questions.map(\.question) == ["Close the window? 1 session is still running."],
              "The close button asks with the count")
        check(!model.canQuit() && questions.last?.question == "Quit Nocci? 1 session is still running." && questions.last?.action == "Quit",
              "Quitting asks too")
        answer = true
        check(model.canQuit() && model.closeAll() && model.tabs.isEmpty && a.closed == 1 && b.closed == 1,
              "Confirming closes every session")
        model.start(web)
        let c = made[made.count - 1].session
        c.agentRunning = false
        questions = []
        check(model.canQuit() && questions.isEmpty, "Nothing is asked when no agent runs")
        model.closeAllNow()
        check(c.closed == 1 && model.tabs.isEmpty && activations.last == false, "Quitting closes the rest without asking")

        // A code review can land while the close button's question is up; its
        // new tab is not one the user agreed to close.
        model.start(api)
        let asked = made[made.count - 1].session
        answer = true
        duringQuestion = { model.start(web) }
        check(!model.closeAll(), "The window stays for a tab that opened during the question")
        duringQuestion = nil
        let arrived = made[made.count - 1].session
        check(asked.closed == 1 && arrived.closed == 0 && model.tabs.count == 1 && model.tabs[0].start == web,
              "A tab opened during the question stays open")
        check(activations.last == true && model.selection == model.tabs[0].id,
              "Nocci stays a regular app, on that tab, while it is open")
        model.closeAllNow()

        // A program other than the agent, such as an editor or a server
        // started from the shell afterwards, is asked about too.
        model.start(web)
        let editor = made[made.count - 1].session
        editor.agentRunning = false
        editor.otherProgram = true
        questions = []; answer = false
        check(!model.close(model.tabs[0].id) && questions.last?.question == "Close this tab? A program is still running in web.",
              "Closing a tab with a program running asks")
        check(!model.canQuit() && questions.last?.question == "Quit Nocci? 1 session is still running.",
              "Quitting counts a running program")
        model.closeAllNow()

        // MARK: A start page opened by a summon
        let showsBefore = shows
        model.newTab(show: false)
        check(model.tabs.count == 1 && model.selectedTab?.start == nil && shows == showsBefore && activations.last == true,
              "A summon's start page makes Nocci regular without showing the ordinary window")
        model.closeAllNow()

        // MARK: Selection and font size
        model.start(api); model.start(web); model.start(api)
        let ids = model.tabs.map(\.id)
        model.selection = ids[2]
        model.selectNext()
        check(model.selection == ids[0], "Next wraps to the first tab")
        model.selectPrevious()
        check(model.selection == ids[2], "Previous wraps to the last tab")
        model.smallerFont()
        check(model.fontSize == 23 && defaults.double(forKey: TerminalRules.fontSizeKey) == 23
              && made.suffix(3).allSatisfy { $0.session.fontSizes == [23] }, "A new size is saved and applied to every tab")
        model.biggerFont(); model.biggerFont()
        check(model.fontSize == 24, "Sizes stop at 24")
        model.actualSizeFont()
        check(model.fontSize == 13, "Actual Size returns to 13")
        model.closeAllNow()

        // MARK: Nocci-hosted waits and closed tabs
        let closedBefore = model.closedTabs
        check(closedBefore.isSuperset(of: ids), "Tabs closed earlier in the run are remembered")
        model.start(api)
        let apiTab = model.tabs[0].id
        check(made.last?.tab == apiTab, "The session is told its tab's ID before it starts")
        model.newTab(show: false)
        let pageTab = model.selectedTab!.id
        model.start(web)
        let webTab = model.tabs[1].id
        check(webTab == pageTab && made.last?.tab == webTab && model.tabs[1].start == web,
              "A session started in a start page keeps that tab's ID")
        check(model.waits.isEmpty && !model.waiting(model.tabs[1]), "No wait until a session reports one")
        let since = Date(timeIntervalSince1970: 1_800_000_000)
        let webSession = made.last!.session
        webSession.waitingSince = since
        webSession.onChange?()
        check(model.waits == [TerminalWait(tab: webTab, label: "web", since: since)] && model.waiting(model.tabs[1])
              && !model.waiting(model.tabs[0]), "A session's wait is published with its tab and label")
        model.clearWait(webTab)
        check(webSession.cleared == 1 && model.waits.isEmpty && !model.waiting(model.tabs[1]),
              "Clearing a wait tells the session and drops it")
        model.clearWait(UUID())
        check(webSession.cleared == 1, "Clearing an unknown tab does nothing")
        webSession.waitingSince = since
        webSession.onChange?()
        answer = true
        model.close(webTab)
        check(model.closedTabs == closedBefore.union([webTab]) && model.waits.isEmpty, "A closed tab is remembered and its wait goes with it")
        model.newTab(show: false)
        let emptyPage = model.selectedTab!.id
        model.close(emptyPage)
        check(!model.closedTabs.contains(emptyPage), "A start page that never ran a session is not a closed session")
        model.closeAllNow()
        check(model.closedTabs == closedBefore.union([webTab, apiTab]) && model.waits.isEmpty,
              "Closing everything remembers every session tab")

        // MARK: Notch tabs
        do {
        activations = []
        questions = []
        let showsBeforeNotch = shows
        let first = model.start(api, place: .notch)
        let firstSession = made.last!.session
        check(model.tabs.map(\.id) == [first] && model.tabs[0].place == .notch && made.last?.tab == first
              && made.last?.size == TerminalRules.notchFontSize,
              "A notch start opens a tab at the notch's own font size")
        check(shows == showsBeforeNotch && model.selection == nil && model.selectedTab == nil && model.windowTabs.isEmpty
              && activations.isEmpty, "A notch start neither shows the window, selects its tab, nor makes Nocci regular")
        model.newTab(show: false)
        let windowPage = model.selection!
        let second = model.start(web, place: .notch)
        let secondSession = made.last!.session
        check(second != windowPage && model.selectedTab?.id == windowPage && model.selectedTab?.start == nil,
              "A notch start never takes the window's open start page")
        check(activations == [true] && model.windowTabs.map(\.id) == [windowPage], "The window lists its own tabs only")
        model.biggerFont()
        check(firstSession.fontSizes.isEmpty && secondSession.fontSizes.isEmpty, "The window's text size leaves notch tabs alone")
        model.actualSizeFont()
        check(model.closeAll() && model.tabs.map(\.id) == [first, second] && firstSession.closed == 0 && secondSession.closed == 0
              && activations == [true, false], "The window's close button closes window tabs only")
        answer = false
        check(!model.canQuit() && questions.last?.question == "Quit Nocci? 2 sessions are still running.",
              "Quitting still asks while notch agents run")
        answer = true
        let windowFirst = model.start(api)
        let third = model.start(web, place: .notch)
        let thirdSession = made.last!.session
        let windowSecond = model.start(api)
        check(model.windowTabs.map(\.id) == [windowFirst, windowSecond] && model.selection == windowSecond,
              "Window starts are listed and selected around a notch tab")
        model.selection = windowFirst
        model.selectNext()
        check(model.selection == windowSecond, "Next Tab skips a notch tab")
        model.selectPrevious()
        check(model.selection == windowFirst, "Previous Tab skips it too")
        check(model.close(windowFirst) && model.selection == windowSecond,
              "Closing the selected tab selects the next window tab, never a notch tab")
        check(model.close(windowSecond) && model.selection == nil && activations.last == false
              && model.tabs.map(\.id) == [first, second, third],
              "Closing the last window tab leaves the notch tabs running and Nocci an accessory app")
        let showsBeforeMove = shows
        let activationsBeforeMove = activations.count
        model.moveToWindow(first)
        check(model.tabs.first { $0.id == first }?.place == .window && model.selection == first && model.windowTabs.map(\.id) == [first]
              && firstSession.fontSizes == [model.fontSize] && shows == showsBeforeMove + 1
              && activations.count == activationsBeforeMove + 1 && activations.last == true,
              "Open in window moves the tab, at the window's size, selects and shows it, and makes Nocci regular")
        model.moveToWindow(first)
        model.moveToWindow(UUID())
        check(shows == showsBeforeMove + 1 && activations.count == activationsBeforeMove + 1,
              "Moving a tab already in the window, or one that has gone, does nothing")
        let notchSince = Date(timeIntervalSince1970: 1_800_000_100)
        secondSession.waitingSince = notchSince
        secondSession.onChange?()
        check(model.waits == [TerminalWait(tab: second, label: "web", since: notchSince)], "A notch tab's Codex wait is published")
        let activationsBeforeClose = activations.count
        check(model.close(second) && model.closedTabs.contains(second) && model.waits.isEmpty
              && activations.count == activationsBeforeClose, "Closing a notch tab is remembered and never changes the app")
        model.closeAllNow()
        check(model.tabs.isEmpty && firstSession.closed == 1 && thirdSession.closed == 1 && activations.last == false,
              "Quitting closes window and notch tabs alike")
        model.start(web, place: .notch)
        let activationsBeforeQuit = activations.count
        model.closeAllNow()
        check(model.tabs.isEmpty && activations.count == activationsBeforeQuit,
              "Quitting with only notch tabs never reports the window closing")
        }

        print("\(checks) terminal model checks passed")
    }
}
