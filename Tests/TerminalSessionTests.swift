import AppKit
import SwiftTerm

// Real pseudo-terminals, real shells and a fake agent in temporary folders:
// the terminal's launch path end to end. The shells read only the
// startup files written here, never the developer's own.
@main
struct TerminalSessionTests {
    static func main() throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            guard condition() else { fatalError("FAIL: \(label)") }
            checks += 1
        }
        func pump(timeout: TimeInterval = 10, until done: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while !done(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            return done()
        }
        func gone(_ pid: pid_t) -> Bool { kill(pid, 0) == -1 && errno == ESRCH }
        func screen(_ session: TerminalSession) -> String {
            let terminal = (session.view as! TerminalView).getTerminal()
            return (0..<terminal.rows).map { terminal.getLine(row: $0)?.translateToString(trimRight: true) ?? "" }
                .joined(separator: "\n")
        }
        func lines(_ path: String) -> [String] {
            ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").components(separatedBy: "\n")
        }
        _ = NSApplication.shared
        let manager = FileManager.default
        let temporary = manager.temporaryDirectory.appendingPathComponent("nocci-terminal-session-tests-" + UUID().uuidString)
        try manager.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: temporary) }
        // `pwd` reports the real path; resolvingSymlinksInPath would drop /private again.
        let root = URL(fileURLWithPath: String(cString: realpath(temporary.path, nil)))
        let home = root.appendingPathComponent("home")
        let folder = root.appendingPathComponent("My 'Project' $(x) café")
        try manager.createDirectory(at: home.appendingPathComponent(".config/fish"), withIntermediateDirectories: true)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let record = root.appendingPathComponent("agent").path
        let shellRecord = root.appendingPathComponent("shell").path
        let agent = root.appendingPathComponent("fake-agent").path
        // The prompt goes to its own file so its line break survives.
        try """
        #!/bin/sh
        { printf 'cwd=%s\\n' "$(pwd)"; printf 'argc=%s\\n' "$#"; printf 'first=%s\\n' "$1"
          printf 'prompt=%s\\n' "${NOCCI_PROMPT-unset}"; printf 'agent=%s\\n' "${NOCCI_AGENT-unset}"
          printf 'lang=%s\\n' "${LANG-unset}"; printf 'path=%s\\n' "$PATH"; printf 'pid=%s\\n' "$$"; } > "$TEST_RECORD"
        [ "$#" -ge 2 ] && printf '%s' "$2" > "$TEST_RECORD.prompt"
        printf 'tab=%s\\n' "${NOCCI_TERMINAL_TAB-unset}" >> "$TEST_RECORD"
        [ -n "$TEST_OSC9" ] && printf '\\033]9;%s\\007' "$TEST_OSC9"
        [ -n "$TEST_DSR" ] && printf '\\033[6n'
        [ -n "$TEST_READ" ] && { stty raw -echo; head -c "$TEST_READ" > "$TEST_RECORD.input"; stty sane; }
        [ -n "$TEST_SIZE" ] && { sleep "$TEST_SIZE"; stty size > "$TEST_RECORD.size"; }
        [ -n "$TEST_SLEEP" ] && sleep "$TEST_SLEEP"
        exit 0
        """.write(toFile: agent, atomically: true, encoding: .utf8)
        chmod(agent, 0o755)
        // The launching shell has NOCCI_AGENT; the user's shell that follows does
        // not, so that one records where it started and what it was given, then exits.
        let posixStartup = """
        export PATH="/startup-files:$PATH"
        if [ -z "${NOCCI_AGENT+x}" ]; then { pwd; printf 'prompt=%s\\n' "${NOCCI_PROMPT-unset}"; } > "$TEST_SHELL_RECORD"; exit 0; fi
        """
        for name in [".zshrc", ".bash_profile", ".profile"] {
            try posixStartup.write(to: home.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try """
        set -gx PATH /startup-files $PATH
        if not set -q NOCCI_AGENT
            begin; pwd; if set -q NOCCI_PROMPT; printf 'prompt=%s\\n' $NOCCI_PROMPT; else; printf 'prompt=unset\\n'; end; end > $TEST_SHELL_RECORD
            exit 0
        end
        """.write(to: home.appendingPathComponent(".config/fish/config.fish"), atomically: true, encoding: .utf8)

        func start(_ shell: String, program: String, prompt: String, agent: ProjectAgent = .claude, tab: UUID? = nil,
                   extra: [String: String] = [:]) -> TerminalSession {
            for path in [record, record + ".prompt", record + ".input", record + ".size", shellRecord] { try? manager.removeItem(atPath: path) }
            let start = TerminalStart(folder: folder.path, label: "My Project", agent: agent, program: program, prompt: prompt)
            let base = ["HOME": home.path, "ZDOTDIR": home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                        "TEST_RECORD": record, "TEST_SHELL_RECORD": shellRecord].merging(extra) { $1 }
            return TerminalSession(start: start, shell: TerminalRules.launchShell(account: shell),
                                   environment: TerminalRules.environment(base: base, start: start, accountShell: shell,
                                                                          locale: "en_US.UTF-8", tab: tab),
                                   fontSize: 13)
        }
        func key(_ characters: String, _ keyCode: UInt16) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                             characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
        }

        // MARK: Each shell, with a hostile prompt and folder
        let hostile = "-leading \"double\" 'single' $(touch pwned) `touch pwned2` \\ back\nline two 🦊 café"
        let shells = ["/bin/zsh", "/bin/bash", "/bin/sh", "/opt/homebrew/bin/fish", "/usr/local/bin/fish"]
            .filter { manager.isExecutableFile(atPath: $0) }
        check(shells.contains("/bin/zsh"), "zsh is present")
        for shell in shells {
            let session = start(shell, program: agent, prompt: hostile)
            var changes = 0
            session.onChange = { changes += 1 }
            check(session.agentRunning && session.processID > 0, "\(shell): the agent counts as running from the start")
            check(pump { !session.agentRunning }, "\(shell): the end-of-agent marker arrives")
            let agentLines = lines(record)
            check(agentLines.contains("cwd=" + folder.path), "\(shell): the agent runs in the project folder")
            check(agentLines.contains("argc=2") && agentLines.contains("first=--"), "\(shell): the prompt is one argument after --")
            check((try? String(contentsOfFile: record + ".prompt", encoding: .utf8)) == hostile,
                  "\(shell): the prompt reaches the agent exactly")
            check(agentLines.contains("prompt=unset") && agentLines.contains("agent=unset"),
                  "\(shell): neither variable reaches the agent")
            check(agentLines.contains("lang=en_US.UTF-8"), "\(shell): the agent gets a UTF-8 locale")
            check(agentLines.contains { $0.hasPrefix("path=/startup-files:") }, "\(shell): the startup files ran before the agent")
            check(!manager.fileExists(atPath: folder.appendingPathComponent("pwned").path)
                  && !manager.fileExists(atPath: folder.appendingPathComponent("pwned2").path), "\(shell): nothing in the prompt ran")
            check(pump { session.exited }, "\(shell): the user's shell follows, then exits")
            check(Array(lines(shellRecord).prefix(2)) == [folder.path, "prompt=unset"],
                  "\(shell): the user's shell starts in the folder without the prompt")
            check(screen(session).contains("[Process completed]"), "\(shell): an ended tab says so")
            check(changes == 2, "\(shell): the agent ending and the process ending are each reported once")
        }

        // MARK: No prompt
        let plain = start("/bin/zsh", program: agent, prompt: "")
        check(pump { plain.exited }, "Without a prompt the session runs to the end")
        check(lines(record).contains("argc=0") && !manager.fileExists(atPath: record + ".prompt"),
              "Without a prompt the agent gets no arguments")

        // MARK: A missing program
        let missing = start("/bin/zsh", program: root.appendingPathComponent("no-such-agent").path, prompt: "hi")
        check(pump { !missing.agentRunning }, "A missing program still ends the agent part")
        check(pump { missing.exited } && lines(shellRecord).first == folder.path, "The user's shell still follows")

        // MARK: A shell that cannot start
        let broken = TerminalSession(start: TerminalStart(folder: folder.path, label: "x", agent: .claude, program: agent, prompt: ""),
                                     shell: root.appendingPathComponent("no-such-shell").path, environment: [], fontSize: 13)
        check(pump(timeout: 5) { broken.exited } && !broken.agentRunning, "A shell that cannot start ends the tab at once")

        // MARK: Codex waits
        let waiting = start("/bin/zsh", program: agent, prompt: "", agent: .codex,
                            extra: ["TEST_OSC9": "Codex needs your approval", "TEST_DSR": "1", "TEST_SLEEP": "4"])
        var waitChanges = 0
        waiting.onChange = { waitChanges += 1 }
        check(pump { waiting.waitingSince != nil }, "A Codex notification marks the tab as needing you")
        check(waitChanges == 1, "The wait is reported once")
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        check(waiting.waitingSince != nil && waiting.agentRunning, "The emulator answering a cursor query does not count as the user typing")
        (waiting.view as! TerminalView).send(txt: "y")
        check(waiting.waitingSince == nil && waitChanges == 2, "The next key the user sends clears the wait")
        check(lines(record).contains { $0.hasPrefix("first=-c") }, "The Codex flags reach the agent as its own arguments")
        check(pump { waiting.exited }, "The session runs to the end")
        let claudeTab = start("/bin/zsh", program: agent, prompt: "", agent: .claude, extra: ["TEST_OSC9": "hello", "TEST_SLEEP": "1"])
        check(pump { !claudeTab.agentRunning } && claudeTab.waitingSince == nil, "A Claude Code tab ignores OSC 9; its waits come from hooks")
        check(pump { claudeTab.exited }, "The Claude tab runs to the end")
        let ending = start("/bin/zsh", program: agent, prompt: "", agent: .codex, extra: ["TEST_OSC9": "done"])
        check(pump { !ending.agentRunning } && ending.waitingSince == nil, "A wait ends with the agent")
        (ending.view as! TerminalView).feed(text: "\u{1b}]9;printed by the shell afterwards\u{07}")
        check(ending.waitingSince == nil, "A notification after the agent has ended is not a wait")
        check(pump { ending.exited }, "The ending tab runs to the end")
        let progress = start("/bin/zsh", program: agent, prompt: "", agent: .codex, extra: ["TEST_OSC9": "4;1;50", "TEST_SLEEP": "1"])
        check(pump { !progress.agentRunning } && progress.waitingSince == nil, "A progress report is not a wait")
        check(pump { progress.exited }, "The progress tab runs to the end")
        let cleared = start("/bin/zsh", program: agent, prompt: "", agent: .codex, extra: ["TEST_OSC9": "approve?", "TEST_SLEEP": "2"])
        var clearedChanges = 0
        cleared.onChange = { clearedChanges += 1 }
        check(pump { cleared.waitingSince != nil }, "A second Codex tab waits too")
        cleared.clearWait()
        check(cleared.waitingSince == nil && clearedChanges == 2, "Dismissing a wait clears it and reports once")
        cleared.clearWait()
        check(clearedChanges == 2, "Clearing again reports nothing")
        check(pump { cleared.exited }, "The cleared tab runs to the end")

        // MARK: The tab reaches the child
        let tab = UUID()
        let tagged = start("/bin/zsh", program: agent, prompt: "", tab: tab)
        check(pump { tagged.exited } && lines(record).contains("tab=" + tab.uuidString), "The tab's ID reaches the agent's environment")
        let untagged = start("/bin/zsh", program: agent, prompt: "")
        check(pump { untagged.exited } && lines(record).contains("tab=unset"), "Without a tab the variable is absent")

        // MARK: The mini view reads the screen
        let shown = start("/bin/zsh", program: agent, prompt: "", extra: ["TEST_SLEEP": "3"])
        func trimmed(_ rows: [ScreenRow]) -> [String] { rows.map { $0.text.trimmingCharacters(in: .whitespaces) } }
        // The fake agent writes to files, not the terminal, so the screen is fed directly.
        (shown.view as! TerminalView).feed(text: "one\r\ntwo\r\nthree\r\nfour\r\n")
        check(shown.screenText(last: 3).contains("four"), "The mini view sees the screen")
        let rows = shown.screenRows(last: 3)
        check(trimmed(rows) == ["three", "four", ""] && rows.last?.cursor == 0 && rows.dropLast().allSatisfy { $0.cursor == nil },
              "A short screen shows its last rows down to the cursor, not the blank bottom")
        check(trimmed(shown.screenRows(last: 10)) == ["one", "two", "three", "four", ""],
              "Asking for more rows than there is content returns what there is")
        (shown.view as! TerminalView).feed(text: (1...80).map { "line \($0)" }.joined(separator: "\r\n"))
        check(trimmed(shown.screenRows(last: 3)) == ["line 78", "line 79", "line 80"],
              "A full screen shows its bottom rows, the cursor row included")
        (shown.view as! TerminalView).feed(text: "\r\nfox 🦊 é\u{301} \u{1b}[1;4;31mdone\u{1b}[0m")
        let foxRow = shown.screenRows(last: 1).last!
        check(foxRow.text.contains("fox 🦊 é\u{301} done") && shown.screenText(last: 1).contains("🦊"),
              "Wide and combined characters are drawn and read whole")
        let fox = foxRow.cells.firstIndex { $0.character == "🦊" }!
        check(foxRow.cells[fox].width == 2 && foxRow.cells[fox + 1].column == foxRow.cells[fox].column + 2
              && foxRow.cells.enumerated().allSatisfy { $0.element.column >= $0.offset },
              "Every cell keeps its grid column, so nothing after a wide character drifts from the cursor")
        let styled = foxRow.cells.first { $0.character == "d" }!
        check(styled.bold && styled.underline && styled.foreground != foxRow.cells[0].foreground && !foxRow.cells[0].bold,
              "Bold, underline and colour come from the cell")
        var screenChanges = 0
        shown.onScreenChange = { screenChanges += 1 }
        (shown.view as! TerminalView).feed(text: "\r\nworld")
        check(pump(timeout: 2) { screenChanges > 0 }, "A screen change is reported to the mini view")
        check(shown.label == "My Project", "The mini view's label is the tab's")
        let mini = shown.miniView()
        check(mini.acceptsFirstResponder && mini.accessibilityLabel() == "Terminal for My Project",
              "The mini view takes the keyboard and names its session")
        check(pump { shown.exited }, "The shown tab runs to the end")

        // MARK: Keys typed into the mini view reach the session
        let typed = start("/bin/zsh", program: agent, prompt: "", extra: ["TEST_READ": "6"])
        let keys = typed.miniView()
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        for event in [key("y", 16), key("\u{1b}", 53), key(String(Character(UnicodeScalar(NSUpArrowFunctionKey)!)), 126), key("\r", 36)] {
            keys.keyDown(with: event)
        }
        check(pump { manager.fileExists(atPath: record + ".input") && ((try? Data(contentsOf: URL(fileURLWithPath: record + ".input")))?.count ?? 0) >= 6 },
              "Keys typed into the mini view reach the session")
        check((try? String(contentsOfFile: record + ".input", encoding: .utf8)) == "y\u{1b}\u{1b}[A\r",
              "A letter, Escape, an arrow and Return arrive exactly as the window would send them")
        check(pump { typed.exited }, "The typed tab runs to the end")

        // MARK: The notch's container
        let hosted = start("/bin/zsh", program: agent, prompt: "", extra: ["TEST_SIZE": "2"])
        let hostedTerminal = (hosted.view as! TerminalView).getTerminal()
        let tile = TerminalContainer(frame: .zero)
        tile.session = hosted.view
        check(hosted.view.superview == nil, "A container with no size yet leaves the session alone")
        tile.setFrameSize(NSSize(width: 480, height: 300))
        check(hosted.view.superview === tile && hosted.view.frame == tile.bounds,
              "Once it has a size the container shows the session, filling it")
        // The shell creates the file before stty writes to it, so wait for its line.
        check(pump { !(lines(record + ".size").first ?? "").isEmpty }
              && lines(record + ".size").first == "\(hostedTerminal.rows) \(hostedTerminal.cols)",
              "The child sees the container's size, never a squeezed one")
        let tileColumns = hostedTerminal.cols
        let newer = TerminalContainer(frame: NSRect(x: 0, y: 0, width: 480, height: 300))
        newer.session = hosted.view
        check(hosted.view.superview === newer, "A newer container in the tile takes the session")
        tile.setFrameSize(NSSize(width: 480, height: 300))
        tile.layout()
        check(hosted.view.superview === newer, "An older container laid out again never takes the session back from a newer one")
        tile.session = nil
        check(hosted.view.superview === newer, "An older container letting go never takes it from the newer one")
        let window = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        window.addSubview(hosted.view)
        hosted.view.frame = window.bounds
        newer.setFrameSize(NSSize(width: 400, height: 300))
        newer.layout()
        check(hosted.view.superview === window && hostedTerminal.cols > tileColumns,
              "Once the window has the session no container takes it back, and it follows the window's size")
        newer.session = nil
        check(hosted.view.superview === window, "Letting go after Open in window leaves the session in the window")
        check(pump { hosted.exited }, "The hosted tab runs to the end")

        // MARK: Ctrl-C
        // An interactive zsh drops the rest of its script when a job dies of
        // SIGINT; the script's INT trap is what keeps the marker and the shell.
        for shell in shells {
            let interrupted = start(shell, program: agent, prompt: "", extra: ["TEST_SLEEP": "30"])
            var marked = false
            interrupted.onChange = { if !interrupted.exited { marked = true } }
            check(pump { manager.fileExists(atPath: record) }, "\(shell): the sleeping agent started")
            (interrupted.view as! TerminalView).send(txt: "\u{3}")
            check(pump { marked }, "\(shell): Ctrl-C ends the agent and the marker follows")
            check(pump { interrupted.exited } && lines(shellRecord).first == folder.path, "\(shell): the user's shell still follows")
        }

        // MARK: The clipboard
        // A query would hand the clipboard to whatever printed it; only writes are honoured.
        let clipboardAgent = root.appendingPathComponent("clipboard-agent").path
        try """
        #!/bin/sh
        printf '\\033]52;c;?\\007'
        printf '\\033]52;c;aGVsbG8=\\007'
        stty -icanon min 0 time 10
        dd bs=1 count=200 of="$TEST_RECORD" 2>/dev/null
        """.write(toFile: clipboardAgent, atomically: true, encoding: .utf8)
        chmod(clipboardAgent, 0o755)
        var copied: [String] = []
        let clipboardStart = TerminalStart(folder: folder.path, label: "x", agent: .claude, program: clipboardAgent, prompt: "")
        for path in [record, shellRecord] { try? manager.removeItem(atPath: path) }
        let clipboard = TerminalSession(start: clipboardStart, shell: "/bin/zsh",
                                        environment: TerminalRules.environment(base: ["HOME": home.path, "ZDOTDIR": home.path,
                                                                                      "PATH": "/usr/bin:/bin", "TEST_RECORD": record,
                                                                                      "TEST_SHELL_RECORD": shellRecord],
                                                                               start: clipboardStart, accountShell: "/bin/zsh",
                                                                               locale: "en_US.UTF-8"),
                                        fontSize: 13, copy: { copied.append($0) })
        check(pump { !clipboard.agentRunning }, "The clipboard agent ran")
        check(copied == ["hello"], "A program's clipboard write goes to Nocci's own handler")
        check((try? Data(contentsOf: URL(fileURLWithPath: record)))?.isEmpty == true, "A clipboard query gets no answer")

        // MARK: Closing a busy tab
        let busy = start("/bin/zsh", program: agent, prompt: "", extra: ["TEST_SLEEP": "30"])
        check(pump { manager.fileExists(atPath: record) }, "The sleeping agent started")
        let shellID = busy.processID
        let agentID = pid_t(lines(record).first { $0.hasPrefix("pid=") }.flatMap { Int32($0.dropFirst(4)) } ?? 0)
        check(agentID > 0 && !gone(agentID), "The agent is running")
        check(busy.programRunning, "A running agent counts as a running program")
        // Another tab's processes must never hold this tab's terminal.
        check(fcntl(busy.ptyDescriptor, F_GETFD) & FD_CLOEXEC != 0, "A tab's terminal is never inherited by later tabs")
        busy.close()
        check(!busy.agentRunning && busy.exited, "A closed tab no longer counts as running")
        check(pump(timeout: 5) { gone(shellID) && gone(agentID) }, "Closing ends the shell and the agent, and the shell is reaped")

        // An agent that ignores the hang-up is killed once the grace ends.
        let stubbornAgent = root.appendingPathComponent("stubborn-agent").path
        try """
        #!/bin/sh
        trap '' HUP
        printf 'pid=%s\n' "$$" > "$TEST_RECORD"
        sleep 30
        """.write(toFile: stubbornAgent, atomically: true, encoding: .utf8)
        chmod(stubbornAgent, 0o755)
        let stubborn = start("/bin/zsh", program: stubbornAgent, prompt: "")
        check(pump { manager.fileExists(atPath: record) && !lines(record).filter { $0.hasPrefix("pid=") }.isEmpty },
              "The stubborn agent started")
        let stubbornID = pid_t(lines(record).first { $0.hasPrefix("pid=") }.flatMap { Int32($0.dropFirst(4)) } ?? 0)
        stubborn.close()
        check(stubbornID > 0 && pump(timeout: 6) { gone(stubbornID) }, "An agent that ignores the hang-up does not outlive its tab")

        print("\(checks) terminal session checks passed")
    }
}
