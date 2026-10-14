// Optional UI fixture harness, not run by test.sh. Build it from the repository root with:
//   swiftc -swift-version 5 -module-cache-path .build/module-cache Tests/HistoryPreview.swift \
//     Sources/Freshness.swift Sources/Usage.swift Sources/Alerts.swift Sources/Pace.swift \
//     Sources/Presentation.swift Sources/ClaudeIntegration.swift Sources/UsageModel.swift \
//     Sources/HistoryStore.swift Sources/HistoryView.swift \
//     -framework AppKit -framework SwiftUI -framework Charts -lsqlite3 -o .build/history-preview
// and run it from a temporary .app with its own bundle identifier, never Nocci's.
// Runs the real HistoryView using synthetic data and a temporary store, never live accounts.
import AppKit

@main
struct HistoryPreview {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NotchHistoryPreview-\(UUID())")
        let domain = "NotchHistoryPreview.\(UUID())"
        let defaults = UserDefaults(suiteName:domain)!
        defer {
            defaults.removePersistentDomain(forName:domain)
            try? FileManager.default.removeItem(at:root)
        }
        let now = Date(), start = now.addingTimeInterval(-12*3600)
        let store = HistoryStore(directory:root)
        for minute in stride(from:0,to:720,by:5) {
            // Include a reset at six hours and a two-hour missing-observation interval.
            if (180..<300).contains(minute) { continue }
            let captured = start.addingTimeInterval(Double(minute)*60)
            let reset = start.addingTimeInterval(minute < 360 ? 21600 : 43200)
            let snapshot = UsageSnapshot(windows:[.init(label:"5-hour",used:Double(minute % 360)/4,reset:reset,kind:.session)],updated:captured)
            try store.record(snapshot,provider:"claude",epoch:"fixture",now:captured,since:start)
        }
        store.close()
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let menu = NSMenu(), item = NSMenuItem(), appMenu = NSMenu()
        appMenu.addItem(withTitle:"Quit History Preview",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        item.submenu = appMenu; menu.addItem(item); app.mainMenu = menu
        let usage = UsageModel(demo:true,fetchCodex:{ _ in },loadClaude:{ $0(nil) },inspectClaude:{ _ in .notConfigured },defaults:defaults)
        let history = HistoryModel(usage:usage,defaults:defaults,directory:root)
        history.show()
        app.run()
        withExtendedLifetime(history) {}
    }
}
