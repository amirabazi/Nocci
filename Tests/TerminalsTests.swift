import CoreGraphics
import Foundation

// Every pure terminal rule, with made-up paths, environments and locales.
@main
struct TerminalsTests {
    static func main() {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            guard condition() else { fatalError("FAIL: \(label)") }
            checks += 1
        }

        // MARK: Shells
        let runnable: Set<String> = ["/bin/zsh", "/bin/bash", "/usr/local/bin/fish", "/bin/tcsh"]
        check(TerminalRules.accountShell("/bin/bash", runnable: runnable.contains) == "/bin/bash", "A runnable account shell is used")
        check(TerminalRules.accountShell(nil, runnable: runnable.contains) == "/bin/zsh"
              && TerminalRules.accountShell("", runnable: runnable.contains) == "/bin/zsh"
              && TerminalRules.accountShell("bash", runnable: { _ in true }) == "/bin/zsh"
              && TerminalRules.accountShell("/gone/zsh", runnable: runnable.contains) == "/bin/zsh",
              "A missing, relative or unrunnable account shell falls back to zsh")
        for shell in ["/bin/zsh", "/bin/bash", "/bin/sh", "/usr/local/bin/fish", "/opt/homebrew/bin/fish"] {
            check(TerminalRules.launchShell(account: shell) == shell, "\(shell) runs the launch script itself")
        }
        check(TerminalRules.launchShell(account: "/bin/tcsh") == "/bin/zsh"
              && TerminalRules.launchShell(account: "/usr/local/bin/nu") == "/bin/zsh",
              "A shell the script was not tested under launches through zsh")

        // MARK: Launch script
        let withPrompt = "trap true INT; env -u NOCCI_PROMPT -u NOCCI_AGENT \"$NOCCI_AGENT\" -- \"$NOCCI_PROMPT\"; "
            + "/usr/bin/printf '\\033]7719;agent-exited\\007'; exec env -u NOCCI_PROMPT -u NOCCI_AGENT \"$SHELL\" -l"
        let withoutPrompt = "trap true INT; env -u NOCCI_PROMPT -u NOCCI_AGENT \"$NOCCI_AGENT\"; "
            + "/usr/bin/printf '\\033]7719;agent-exited\\007'; exec env -u NOCCI_PROMPT -u NOCCI_AGENT \"$SHELL\" -l"
        check(TerminalRules.script(hasPrompt: true) == withPrompt,
              "The script survives Ctrl-C, runs the agent with the prompt after --, marks its end, then the user's shell")
        check(TerminalRules.script(hasPrompt: false) == withoutPrompt, "Without a prompt the agent gets no arguments")
        let arguments = TerminalRules.arguments(prompt: "rm -rf $(pwd) `id`")
        check(arguments == ["-l", "-i", "-c", withPrompt], "A login, interactive shell runs the fixed script")
        check(!arguments.joined().contains("rm -rf"), "The prompt never becomes part of the command line")
        check(TerminalRules.arguments(prompt: "") == ["-l", "-i", "-c", withoutPrompt], "An empty prompt is left out")

        // MARK: Environment
        func environment(_ base: [String: String], prompt: String = "fix it", tab: UUID? = nil) -> [String: String] {
            let start = TerminalStart(folder: "/p", label: "p", agent: .claude, program: "/bin/claude", prompt: prompt)
            let list = TerminalRules.environment(base: base, start: start, accountShell: "/bin/bash", locale: "de_DE.UTF-8", tab: tab)
            check(list == list.sorted(), "The environment is in a stable order")
            return Dictionary(uniqueKeysWithValues: list.map { entry -> (String, String) in
                let parts = entry.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                return (parts[0], parts[1])
            })
        }
        let env = environment(["PATH": "/usr/bin:/bin", "HOME": "/Users/someone", "TERM": "dumb", "SHELL": "/bin/zsh"])
        check(env["TERM"] == "xterm-256color" && env["COLORTERM"] == "truecolor", "The terminal says what it is")
        check(env["SHELL"] == "/bin/bash", "SHELL is the account's shell")
        check(env["NOCCI_AGENT"] == "/bin/claude" && env["NOCCI_PROMPT"] == "fix it", "The agent and the prompt travel in the environment")
        check(env["PATH"] == "/usr/bin:/bin" && env["HOME"] == "/Users/someone", "Nocci's own environment is kept")
        check(env["LANG"] == "de_DE.UTF-8", "Without a locale the user's is set")
        check(environment(["LANG": "fr_FR.UTF-8"])["LANG"] == "fr_FR.UTF-8" && environment(["LC_ALL": "C"])["LANG"] == nil
              && environment(["LC_CTYPE": "UTF-8"])["LANG"] == nil, "A locale already set is left alone")
        check(environment(["NOCCI_PROMPT": "stale"], prompt: "")["NOCCI_PROMPT"] == nil,
              "With no prompt no NOCCI_PROMPT is passed, not even an inherited one")
        check(environment([:], prompt: "a=b\nc")["NOCCI_PROMPT"] == "a=b\nc", "A prompt is passed exactly")

        // MARK: Codex notifications and the tab
        let codexScript = "trap true INT; env -u NOCCI_PROMPT -u NOCCI_AGENT \"$NOCCI_AGENT\" -c tui.notifications=true "
            + "-c tui.notification_method=osc9 -c tui.notification_condition=always -- \"$NOCCI_PROMPT\"; "
            + "/usr/bin/printf '\\033]7719;agent-exited\\007'; exec env -u NOCCI_PROMPT -u NOCCI_AGENT \"$SHELL\" -l"
        check(TerminalRules.script(hasPrompt: true, agent: .codex) == codexScript,
              "A Codex tab turns on Codex's terminal notifications for that run only, before the prompt")
        check(TerminalRules.script(hasPrompt: true, agent: .claude) == withPrompt, "Claude Code gets no Codex flags")
        check(TerminalRules.arguments(prompt: "x", agent: .codex) == ["-l", "-i", "-c", codexScript],
              "The Codex flags are part of the fixed script, never of the prompt")
        let tab = UUID()
        check(environment(["PATH": "/bin"], tab: tab)["NOCCI_TERMINAL_TAB"] == tab.uuidString, "The tab's ID reaches the child")
        check(environment(["PATH": "/bin"])["NOCCI_TERMINAL_TAB"] == nil, "Without a tab nothing is added")
        check(environment(["NOCCI_TERMINAL_TAB": "stale"], tab: tab)["NOCCI_TERMINAL_TAB"] == tab.uuidString,
              "A tab ID inherited from an outer Nocci is replaced")
        check(environment(["NOCCI_TERMINAL_TAB": "stale"])["NOCCI_TERMINAL_TAB"] == nil,
              "A tab ID inherited from an outer Nocci never leaks into a tab without one")
        check(TerminalRules.isNotification(osc9: Array("Codex needs your approval".utf8)), "Any text is a notification")
        check(!TerminalRules.isNotification(osc9: Array("4;1;50".utf8)), "A ConEmu progress report is not a notification")
        check(!TerminalRules.isNotification(osc9: []), "An empty sequence is not a notification")
        check(TerminalWait(tab: tab, label: "web", since: Date(timeIntervalSince1970: 1))
              == TerminalWait(tab: tab, label: "web", since: Date(timeIntervalSince1970: 1)), "Waits compare by value")

        // MARK: Locale
        let locales: Set<String> = ["en_US.UTF-8", "de_DE.UTF-8", "pt_BR.UTF-8"]
        check(TerminalRules.locale(identifier: "de_DE", available: locales.contains) == "de_DE.UTF-8", "The user's language and region")
        check(TerminalRules.locale(identifier: "pt_BR@rg=ptzzzz", available: locales.contains) == "pt_BR.UTF-8", "A region override is ignored")
        check(TerminalRules.locale(identifier: "zh-Hans_CN", available: locales.contains) == "en_US.UTF-8"
              && TerminalRules.locale(identifier: "fr_FR", available: locales.contains) == "en_US.UTF-8"
              && TerminalRules.locale(identifier: "en", available: locales.contains) == "en_US.UTF-8",
              "Without a matching UTF-8 locale the fallback is en_US")

        // MARK: Titles and running
        check(TerminalRules.title(label: "api · Work", agent: .codex, agentRunning: true) == "api · Work · Codex"
              && TerminalRules.title(label: "api · Work", agent: .codex, agentRunning: false) == "api · Work",
              "The agent's name shows only while it runs")
        check(TerminalRules.agentRunning(markerSeen: false, exited: false) && !TerminalRules.agentRunning(markerSeen: true, exited: false)
              && !TerminalRules.agentRunning(markerSeen: false, exited: true),
              "An agent runs until the marker arrives or the process ends")

        // MARK: Font size
        check(TerminalRules.clampedFontSize(nil) == 13 && TerminalRules.clampedFontSize(0) == 13
              && TerminalRules.clampedFontSize(-4) == 13 && TerminalRules.clampedFontSize(.nan) == 13,
              "No saved size, or nonsense, is the default")
        check(TerminalRules.clampedFontSize(5) == 9 && TerminalRules.clampedFontSize(40) == 24 && TerminalRules.clampedFontSize(15) == 15,
              "Sizes stay between 9 and 24")

        // MARK: Questions
        check(TerminalRules.closeQuestion(label: "api", agent: .claude, agentRunning: true) == "Close this tab? Claude Code is still running in api."
              && TerminalRules.closeQuestion(label: "api", agent: .claude, agentRunning: false) == nil,
              "Closing a tab asks only while its agent runs")
        check(TerminalRules.closeQuestion(label: "api", agent: .claude, agentRunning: false, programRunning: true)
                == "Close this tab? A program is still running in api."
              && TerminalRules.closeQuestion(label: "api", agent: .claude, agentRunning: true, programRunning: true)
                == "Close this tab? Claude Code is still running in api.",
              "A program the shell runs after the agent is asked about, the agent by name")
        check(TerminalRules.closeAllQuestion(running: 0) == nil
              && TerminalRules.closeAllQuestion(running: 1) == "Close the window? 1 session is still running."
              && TerminalRules.closeAllQuestion(running: 3) == "Close the window? 3 sessions are still running.",
              "Closing the window counts the running sessions")
        check(TerminalRules.quitQuestion(running: 0) == nil
              && TerminalRules.quitQuestion(running: 1) == "Quit Nocci? 1 session is still running."
              && TerminalRules.quitQuestion(running: 2) == "Quit Nocci? 2 sessions are still running.",
              "Quitting counts the running sessions")

        // MARK: Clipboard
        func osc52(_ text: String) -> [UInt8] { Array(text.utf8) }
        check(TerminalRules.clipboardText(osc52: osc52("c;aGVsbG8gd29ybGQ=")) == "hello world"
              && TerminalRules.clipboardText(osc52: osc52(";aGk=")) == "hi", "A program may put text on the clipboard")
        check(TerminalRules.clipboardText(osc52: osc52("c;?")) == nil && TerminalRules.clipboardText(osc52: osc52("?")) == nil,
              "A clipboard query is never answered")
        check(TerminalRules.clipboardText(osc52: osc52("c;not base64!")) == nil && TerminalRules.clipboardText(osc52: osc52("aGk=")) == nil
              && TerminalRules.clipboardText(osc52: [0x63, 0x3B, 0x2F, 0x77, 0x3D, 0x3D]) == nil,
              "Malformed or non-text payloads are ignored")

        // MARK: Placement
        let places: [TerminalPlacement] = [.hidden, .ordinary, .dropped]
        func after(_ event: TerminalEvent) -> [TerminalPlacement] { places.map { TerminalRules.placement(after: event, from: $0) } }
        check(after(.summon) == [.dropped, .dropped, .hidden], "Summon drops a hidden or ordinary window and tucks a dropped one")
        check(after(.show) == [.ordinary, .ordinary, .dropped], "The Dock and a new session show the ordinary window, or leave a dropped one")
        check(after(.resign) == [.hidden, .ordinary, .hidden], "Switching apps tucks only a dropped window")
        check(after(.drag) == [.hidden, .ordinary, .ordinary], "Dragging a dropped window makes it ordinary")
        check(after(.empty) == [.hidden, .hidden, .hidden], "No tabs, no window")
        check(places.map(TerminalRules.savesFrame) == [false, true, false], "Only the ordinary frame is ever saved")
        let chosen = CGRect(x: 100, y: 100, width: 800, height: 520), moved = CGRect(x: 300, y: 50, width: 900, height: 600)
        check(TerminalRules.ordinaryFrame(chosen, leaving: .ordinary, current: moved) == moved
              && TerminalRules.ordinaryFrame(chosen, leaving: .dropped, current: moved) == chosen
              && TerminalRules.ordinaryFrame(chosen, leaving: .hidden, current: moved) == chosen,
              "Leaving the ordinary place remembers where the user last moved or resized it")
        check(TerminalRules.summonTitle(dropped: false) == "Show Terminal" && TerminalRules.summonTitle(dropped: true) == "Hide Terminal",
              "The menu item says what it will do")

        // MARK: Dropped frame
        let visible = CGRect(x: 0, y: 0, width: 1512, height: 944)
        let notch = CGRect(x: 588, y: 944, width: 336, height: 38)
        check(TerminalRules.droppedFrame(size: CGSize(width: 800, height: 520), visible: visible, anchor: notch)
              == CGRect(x: 356, y: 424, width: 800, height: 520), "Centred under the notch, its top against the menu bar")
        check(TerminalRules.droppedFrame(size: CGSize(width: 800, height: 520), visible: visible,
                                         anchor: CGRect(x: 10, y: 944, width: 100, height: 38)).minX == 0
              && TerminalRules.droppedFrame(size: CGSize(width: 800, height: 520), visible: visible,
                                            anchor: CGRect(x: 1450, y: 944, width: 60, height: 38)).maxX == 1512,
              "An anchor near either edge keeps the window on screen")
        check(TerminalRules.droppedFrame(size: CGSize(width: 2000, height: 1200), visible: visible, anchor: notch) == visible,
              "A window larger than the screen is shrunk to it")
        let offset = CGRect(x: 1000, y: 100, width: 1920, height: 1080)
        check(TerminalRules.droppedFrame(size: CGSize(width: 800, height: 520), visible: offset,
                                         anchor: CGRect(x: 1880, y: 1180, width: 160, height: 24))
              == CGRect(x: 1560, y: 660, width: 800, height: 520), "A second screen's coordinates and a pill work the same way")
        check(TerminalRules.dropStart(CGRect(x: 356, y: 424, width: 800, height: 520)) == CGRect(x: 356, y: 448, width: 800, height: 520),
              "A drop starts 24 points higher, behind the menu bar")

        // MARK: Start page
        check(TerminalRules.startRefusal(folder: nil, folderExists: false, program: "/c", prompt: "", agent: .claude)
              == "Choose a project or a folder.", "Start needs a folder")
        check(TerminalRules.startRefusal(folder: "/p", folderExists: false, program: "/c", prompt: "", agent: .claude)
              == "This folder no longer exists.", "A folder that has gone is refused")
        check(TerminalRules.startRefusal(folder: "/p", folderExists: true, program: nil, prompt: "", agent: .codex)
              == "Codex wasn't found. Choose it in Settings › Providers.", "A missing program says where to choose it")
        check(TerminalRules.startRefusal(folder: "/p", folderExists: true, program: "/c", prompt: "a\u{0}", agent: .claude)
              == "This prompt contains a character that can't be passed on.", "The Projects prompt checks apply")
        check(TerminalRules.startRefusal(folder: "/p", folderExists: true, program: "/c", prompt: "-v please", agent: .claude) == nil,
              "A leading hyphen is passed on after --")

        print("\(checks) terminals checks passed")
    }
}
