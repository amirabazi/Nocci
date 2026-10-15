import Foundation

// The diagnostic view is the one place that deliberately shows internals, so
// what it may NOT show is the part worth testing.
@main
struct DiagnosticsTests {
    static func main() {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            guard condition() else { fatalError("FAIL: \(label)") }
            checks += 1
        }
        let now = Date(timeIntervalSince1970: 8_000_000)
        let home = "/Users/someone"

        check(Diagnostics.abbreviate("/Users/someone/.claude/nocci-statusline.sh", home: home)
                == "~/.claude/nocci-statusline.sh", "A home-relative path is abbreviated")
        check(Diagnostics.abbreviate("/opt/homebrew/bin/codex", home: home) == "/opt/homebrew/bin/codex",
              "A path outside home is left alone")
        check(Diagnostics.abbreviate("/Users/someone", home: home) == "~", "The home directory itself abbreviates")

        check(Diagnostics.category(for: "Codex took too long. Try refreshing.") == "timeout",
              "A timeout is categorised")
        check(Diagnostics.category(for: "Codex stopped answering. Check that codex login works in Terminal.") == "disconnected",
              "A disconnection is categorised")
        check(Diagnostics.category(for: "Codex wasn’t found. Install it and choose it with Set Up Codex, or hide Codex in Settings › Appearance.") == "not configured",
              "A missing executable is categorised")
        check(Diagnostics.category(for: "Usage unavailable. Sign in with ChatGPT in Codex.") == "sign-in required",
              "A server refusal is categorised")
        check(Diagnostics.category(for: "") == "none", "No message is no error")
        check(Diagnostics.category(for: CodexReader.connectingMessage) == "connecting",
              "Connecting is not reported as an error")
        check(Diagnostics.category(for: CodexReader.noLimitsMessage) == "no limits reported",
              "An account without limits is not reported as an unknown error")
        check(Diagnostics.category(for: "Bearer sk-abcdef0123456789 rejected by /Users/someone/x") == "other",
              "An unrecognised message is reduced to a category, never echoed")

        let connected = DiagnosticInput(
            appVersion: "0.1.0", home: home,
            codexPath: "/Users/someone/.local/bin/codex", codexExecutable: true,
            claudeConfigured: true, bridgePath: "/Users/someone/.claude/nocci-statusline.sh",
            bridgePresent: true, claudeStatus: "Receiving usage",
            lastClaudeEvent: now.addingTimeInterval(-90), lastClaudeRead: now.addingTimeInterval(-90),
            lastCodexRead: now.addingTimeInterval(-30), codexMessage: "", now: now)
        let rows = Diagnostics.rows(connected)
        let text = Diagnostics.text(rows)

        check(!text.contains(home), "The real home directory never appears in the output")
        check(text.contains("~/.local/bin/codex"), "The executable is shown abbreviated")
        check(text.contains("0.1.0"), "The app version is shown")
        check(text.contains("Receiving usage"), "The Claude connection state is shown")
        check(text.contains("Bridge script: present"), "Bridge presence is reported")
        check(text.contains("Last Claude event: 1m ago"), "Event age is reported in plain terms")
        check(text.contains("Codex error: none"), "A clean run reports no error category")
        check(rows.allSatisfy { !$0.value.isEmpty }, "No row is ever rendered blank")

        // Acceptance: diagnostics stay usable with nothing connected at all.
        let empty = DiagnosticInput(
            appVersion: "0.1.0", home: home,
            codexPath: nil, codexExecutable: false,
            claudeConfigured: false, bridgePath: nil, bridgePresent: false,
            claudeStatus: "Not connected",
            lastClaudeEvent: nil, lastClaudeRead: nil, lastCodexRead: nil,
            codexMessage: "Codex wasn’t found. Install it and choose it with Set Up Codex, or hide Codex in Settings › Appearance.", now: now)
        let emptyText = Diagnostics.text(Diagnostics.rows(empty))
        check(emptyText.contains("Codex executable: not found"), "A missing executable is stated plainly")
        check(emptyText.contains("Last Claude event: never"), "A provider that never reported says never")
        check(emptyText.contains("Codex error: not configured"), "The error category still appears")
        check(Diagnostics.rows(empty).count == Diagnostics.rows(connected).count,
              "The same rows appear whether or not anything is connected")

        print("\(checks) diagnostics checks passed")
    }
}
