import Foundation
import SQLite3

@main
struct HistoryTests {
    static func main() throws {
        var checks = 0
        func check(_ condition: Bool, _ name: String) {
            guard condition else { fatalError("FAIL: \(name)") }; checks += 1
        }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("NotchHistoryTests-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let store = HistoryStore(directory: root.appendingPathComponent("History"))
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = base.addingTimeInterval(18000)
        func snapshot(_ seconds: Double, _ used: Double = 25, reset date: Date? = nil, weekly: Bool = false) -> UsageSnapshot {
            UsageSnapshot(windows: [.init(label: weekly ? "Weekly" : "5-hour", used: used,
                                         reset: date ?? reset, kind: weekly ? .weekly : .session)], updated: base.addingTimeInterval(seconds))
        }
        func record(_ seconds: Double, _ used: Double = 25, epoch: String = "one", reset date: Date? = nil) throws {
            try store.record(snapshot(seconds,used,reset:date), provider:"claude", epoch:epoch,
                             now:base.addingTimeInterval(seconds), since:base)
        }
        func rows(_ provider: String = "claude", _ window: String = "session") throws -> [HistorySample] {
            try store.query(provider:provider,window:window,since:base,until:base.addingTimeInterval(86400))
        }
        check(try rows().isEmpty && !fm.fileExists(atPath:store.directory.path), "Reading absent history does not create a store")
        try store.record(snapshot(0),provider:"claude",epoch:"one",now:base.addingTimeInterval(300),since:base)
        check(!fm.fileExists(atPath:store.file.path), "Stale snapshot cannot create history")
        try store.record(snapshot(60),provider:"claude",epoch:"one",now:base,since:base)
        check(!fm.fileExists(atPath:store.file.path), "Future observation is rejected")
        try store.record(snapshot(0),provider:"claude",epoch:"one",now:base,since:base.addingTimeInterval(1))
        check(!fm.fileExists(atPath:store.file.path), "Opt-in does not backfill previous observations")
        try record(0)
        check(try rows().count == 1 && rows()[0].used == 25, "Fresh reading records the canonical percentage")
        check((try fm.attributesOfItem(atPath:store.directory.path)[.posixPermissions] as? Int) == 0o700, "Directory is owner-only")
        check((try fm.attributesOfItem(atPath:store.file.path)[.posixPermissions] as? Int) == 0o600, "Database is owner-only")
        try record(0); store.close(); try record(0)
        check(try rows().count == 1, "Duplicate identity survives reopening")
        try record(10,30)
        check(try rows().count == 1 && rows()[0].used == 30 && rows()[0].captured == base.addingTimeInterval(10), "Minute uses latest observation")
        try record(5,29)
        check(try rows()[0].used == 30, "Out-of-order sample cannot overwrite latest")
        try record(70,35)
        check(try rows().count == 2 && rows()[0].segment == rows()[1].segment, "Continuous samples share a chart segment")
        try record(80,2,reset:base.addingTimeInterval(36000))
        check(try rows().count == 3 && rows()[1].segment != rows()[2].segment, "Same-minute reset preserves both sides and breaks line")
        try record(90,3,reset:base.addingTimeInterval(36010))
        check(try rows().count == 3 && rows().last!.used == 3, "Minor reset correction keeps latest-per-minute policy")
        try record(2000,7,reset:base.addingTimeInterval(36010))
        check(try rows()[2].segment != rows()[3].segment, "Long gaps break lines")
        try record(2060,8,epoch:"two",reset:base.addingTimeInterval(36010))
        check(try rows()[3].segment != rows()[4].segment, "Connection epoch breaks lines")
        try record(2120,2,epoch:"two",reset:base.addingTimeInterval(36010))
        check(try rows()[4].segment != rows()[5].segment, "Unexplained material decrease breaks lines")
        var unknown = snapshot(2200,3); unknown.windows[0].reset = nil
        try store.record(unknown,provider:"claude",epoch:"two",now:unknown.updated,since:base)
        check(try rows().last!.reset == nil && rows().last!.segment != rows()[5].segment, "Unknown reset has no inferred connection")
        try store.record(snapshot(2300,.nan),provider:"claude",epoch:"two",now:base.addingTimeInterval(2300),since:base)
        check(try rows().count == 7, "Non-finite usage is not a plotted zero")
        try store.record(snapshot(2300,90,reset:base.addingTimeInterval(100)),provider:"claude",epoch:"two",now:base.addingTimeInterval(2300),since:base)
        check(try rows().count == 7, "Expired window is not recorded")
        try store.record(UsageSnapshot(windows:[],updated:base.addingTimeInterval(2300)),provider:"claude",epoch:"two",now:base.addingTimeInterval(2300),since:base)
        check(try rows().count == 7, "Missing quota does not become zero")
        try store.record(snapshot(2400,61,weekly:true),provider:"claude",epoch:"two",now:base.addingTimeInterval(2400),since:base)
        try store.record(snapshot(2400,18),provider:"codex",epoch:"two",now:base.addingTimeInterval(2400),since:base)
        check(try rows("claude","weekly").first?.used == 61 && rows("codex").first?.used == 18, "Provider and quota selections stay separate")
        check(try rows().first?.captured.timeIntervalSince1970 == base.timeIntervalSince1970 + 10, "Capture times are UTC instants, independent of local DST")
        try store.prune(days:7,now:base.addingTimeInterval(8 * 86400))
        check(try rows().isEmpty && rows("claude","weekly").isEmpty, "Retention removes expired samples across quotas")
        try record(3000,30)
        try store.prune(days:7,now:base.addingTimeInterval(8 * 86400 + 10))
        check(try rows().count == 1, "Automatic prune runs at most once a day")
        try store.prune(days:7,now:base.addingTimeInterval(8 * 86400 + 10),force:true)
        check(try rows().isEmpty, "Changing retention can prune immediately")
        let bridge = root.appendingPathComponent("claude.json")
        try Data("bridge fixture".utf8).write(to:bridge)
        try store.clear()
        check(!fm.fileExists(atPath:store.file.path) && fm.fileExists(atPath:bridge.path), "Clear removes only history, preserves bridge")
        try Data("not a sqlite database".utf8).write(to:store.file)
        do { _ = try rows(); check(false,"Corruption must fail") } catch { check(error is HistoryFailure,"Corruption is an actionable history-only error") }
        check(try String(contentsOf:store.file,encoding:.utf8) == "not a sqlite database", "Corruption never silently destroys the store")
        try store.clear(); try record(0)
        check(try rows().count == 1, "Confirmed reset recovers from corruption")
        store.close()
        func sql(_ file: URL, _ command: String) throws {
            var db: OpaquePointer?
            guard sqlite3_open(file.path,&db) == SQLITE_OK else { fatalError("Fixture database open failed") }
            defer { sqlite3_close(db) }
            guard sqlite3_exec(db,command,nil,nil,nil) == SQLITE_OK else { fatalError(String(cString:sqlite3_errmsg(db))) }
        }
        try sql(store.file,"PRAGMA user_version=99")
        do { _ = try rows(); check(false,"Future schema must fail") } catch { check(error.localizedDescription.contains("version 99"),"Unsupported migration is explicit") }
        try store.clear()
        _ = try store.open(create:true)
        check(try rows().isEmpty,"Empty version-zero database migrates to version one")
        store.close()
        // 90 days × 1 sample/minute × 2 providers × 2 quotas = 518,400 rows.
        let benchmarkStart = Date()
        try sql(store.file,"""
            BEGIN;
            WITH RECURSIVE minutes(n) AS (SELECT 0 UNION ALL SELECT n+1 FROM minutes WHERE n<129599),
            providers(p) AS (VALUES('claude'),('codex')), windows(w) AS (VALUES('session'),('weekly'))
            INSERT INTO samples SELECT p,w,'fixture',1800000000+n*60,1800000000+(n/300+1)*18000,n%100,
            p||w||CAST(n/300 AS TEXT),30000000+n FROM minutes CROSS JOIN providers CROSS JOIN windows;
            COMMIT;
            """)
        let seedTime = Date().timeIntervalSince(benchmarkStart)
        let queryStart = Date()
        let dense = try store.query(provider:"claude",window:"session",since:base.addingTimeInterval(83*86400),until:base.addingTimeInterval(90*86400))
        let queryTime = Date().timeIntervalSince(queryStart)
        let plotStart = Date(); let plot = HistoryPlot.points(dense); let plotTime = Date().timeIntervalSince(plotStart)
        check(dense.count == 10080,"Seven-day query from 90-day fixture is complete")
        check(plot.count <= 1600 && !plot.isEmpty,"Dense chart rendering is bounded")
        check(plot.last?.captured == dense.last?.captured,"Downsampling retains latest reading")
        check(Set(plot.map(\.segment)).isSubset(of:Set(dense.map(\.segment))),"Downsampling preserves true segment identities")
        let bounded = try store.query(provider:"claude",window:"session",since:base,until:base.addingTimeInterval(90*86400))
        check(bounded.count == HistoryStore.queryLimit,"Chart queries are bounded even for extended ranges")
        let longStart = Date()
        let month = try store.query(provider:"claude",window:"session",since:base.addingTimeInterval(60*86400),
                                    until:base.addingTimeInterval(90*86400),bucket:HistoryModel.bucket(days:30))
        let quarter = try store.query(provider:"claude",window:"session",since:base,until:base.addingTimeInterval(90*86400),
                                      bucket:HistoryModel.bucket(days:90))
        let longTime = Date().timeIntervalSince(longStart)
        check(HistoryModel.bucket(days:1) == nil && HistoryModel.bucket(days:7) == nil && HistoryModel.bucket(days:30) == 900,
              "Only ranges past a week are simplified, 30 days to 15-minute steps")
        check(month.count < HistoryStore.queryLimit && quarter.count < HistoryStore.queryLimit,
              "30 and 90 days fit under the query limit, so no range is cut short")
        check(month.first!.captured.timeIntervalSince(base) < 60*86400 + 900 && quarter.first!.captured.timeIntervalSince(base) < 900,
              "A long range reaches back to its start")
        check(zip(quarter, quarter.dropFirst()).allSatisfy { $0.captured < $1.captured }, "Simplified rows stay in time order")
        let fullMonth = dense.first!.captured.timeIntervalSince1970
        let everyMinute = try store.query(provider:"claude",window:"session",since:base.addingTimeInterval(89*86400),
                                          until:base.addingTimeInterval(90*86400))
        let simplifiedDay = try store.query(provider:"claude",window:"session",since:base.addingTimeInterval(89*86400),
                                            until:base.addingTimeInterval(90*86400),bucket:900)
        check(simplifiedDay.map(\.used).max() == everyMinute.map(\.used).max()
              && simplifiedDay.map(\.used).min() == everyMinute.map(\.used).min(), "Each bucket keeps its lowest and highest reading")
        check(Set(simplifiedDay.map(\.segment)) == Set(everyMinute.map(\.segment)), "No segment is lost or merged")
        check(fullMonth > 0 && longTime < 5, "Long ranges query quickly")
        print(String(format:"History benchmark: 518400 rows seeded %.3fs; 7-day open/query %.3fs; %d chart points prepared %.3fs; 30- and 90-day queries %.3fs",seedTime,queryTime,plot.count,plotTime,longTime))
        let exported = root.appendingPathComponent("export.csv")
        let exportStart = Date()
        check(try store.exportCSV(to:exported) == 518400, "Export writes every retained sample")
        let exportTime = Date().timeIntervalSince(exportStart)
        let exportText = try String(contentsOf:exported, encoding:.utf8)
        let exportLines = exportText.split(separator:"\n")
        check(exportLines.count == 518401 && exportLines[0] == "provider,quota,captured_utc,used_percent,resets_at_utc",
              "The export has a header and one line per sample")
        check(exportLines[1] == "claude,session,2027-01-15T08:00:00Z,0.0,2027-01-15T13:00:00Z",
              "Lines are oldest first, in UTC, with the used percentage and reset")
        check(!exportText.contains("fixture") && !exportText.contains("claudesession"), "The epoch and segment stay out of the export")
        check(exportLines.last!.hasPrefix("codex,weekly,"), "Providers and quotas follow one another in order")
        print(String(format:"History export: 518400 samples written %.3fs, %.1f MB",exportTime,Double(exportText.utf8.count)/1_000_000))
        check(try HistoryStore(directory:root.appendingPathComponent("Absent")).exportCSV(to:exported) == 0
              && (try String(contentsOf:exported, encoding:.utf8)) == HistoryExport.header,
              "Exporting with no history writes only the header and creates no store")
        check(!fm.fileExists(atPath:root.appendingPathComponent("Absent").path), "An empty export never creates a database")
        check(!fm.fileExists(atPath:exported.appendingPathExtension("partial").path), "A finished export leaves no partial file behind")
        let unwritableExport = root.appendingPathComponent("Missing folder/export.csv")
        do { _ = try store.exportCSV(to:unwritableExport); check(false,"An export into a missing folder must fail") }
        catch { check(error is HistoryExportFailure && !(error is HistoryFailure),
                      "A file that cannot be created is an export failure, not a history failure") }
        check(!fm.fileExists(atPath:unwritableExport.appendingPathExtension("partial").path), "A failed export removes its partial file")
        let kept = root.appendingPathComponent("kept.csv")
        try "previous export".write(to:kept, atomically:true, encoding:.utf8)
        let corrupt = root.appendingPathComponent("Corrupt")
        try fm.createDirectory(at:corrupt, withIntermediateDirectories:true)
        try "not a database".write(to:corrupt.appendingPathComponent("history.sqlite"), atomically:true, encoding:.utf8)
        do { _ = try HistoryStore(directory:corrupt).exportCSV(to:kept); check(false,"A corrupt store must fail the export") }
        catch { check(error is HistoryFailure, "A broken store is still reported as a history failure") }
        check((try String(contentsOf:kept, encoding:.utf8)) == "previous export", "A failed export leaves the file it would have replaced untouched")
        check(try store.exportCSV(to:kept) == 518400 && (try String(contentsOf:kept, encoding:.utf8)).hasPrefix(HistoryExport.header),
              "A successful export replaces the chosen file")
        let unwritable = root.appendingPathComponent("missing-folder/export.csv")
        do { _ = try store.exportCSV(to:unwritable); check(false,"An unwritable export must fail") }
        catch { check(!fm.fileExists(atPath:unwritable.path),"A failed export leaves no file") }
        let one = HistorySample(provider:"codex",window:"weekly",epoch:"e",captured:Date(timeIntervalSince1970:1_800_000_000),
                                reset:nil,used:37.25,segment:"s")
        check(HistoryExport.line(one) == "codex,weekly,2027-01-15T08:00:00Z,37.25,\n", "A missing reset is an empty field")

        // Model ingestion: use a fake clock, isolated defaults and a separate temporary directory.
        let domain = "NotchHistoryModel.\(UUID())"
        let preferences = UserDefaults(suiteName:domain)!
        defer { preferences.removePersistentDomain(forName:domain) }
        var clock = base
        let usage = UsageModel(fetchCodex:{ _ in },loadClaude:{ $0(nil) },inspectClaude:{ _ in .notConfigured },defaults:preferences)
        let location = root.appendingPathComponent("Model")
        let model = HistoryModel(usage:usage,defaults:preferences,directory:location,now:{ clock })
        func drain() {
            model.queue.sync {}
            RunLoop.main.run(until:Date().addingTimeInterval(0.02))
            model.queue.sync {}
            RunLoop.main.run(until:Date().addingTimeInterval(0.02))
        }
        func published(_ seconds: Double, _ value: Double = 15) {
            clock = base.addingTimeInterval(seconds); usage.codex = snapshot(seconds,value)
        }
        drain(); published(0); drain()
        check(!model.recording && model.retention == 30 && !fm.fileExists(atPath:location.path),"Recording defaults off with no database created")
        model.setRecording(true); published(60); drain(); model.provider = "codex"; drain()
        check(model.rows.count == 1 && model.rows[0].used == 15,"Opt-in records fresh model publications")
        model.setRecording(false); published(120,30); drain(); model.reload(); drain()
        check(model.rows.count == 1,"Pausing preserves old readings and stops new ones")
        model.setRecording(true); clock = base.addingTimeInterval(180); usage.toggleDemo(); drain(); model.reload(); drain()
        check(model.rows.count == 1,"Demo samples are never persisted")
        usage.toggleDemo(); published(240,40); drain(); model.reload(); drain()
        check(model.rows.count == 2 && model.rows[0].segment != model.rows[1].segment,"Resuming starts a separate segment")
        usage.codex = nil; published(300,41); drain(); model.reload(); drain()
        check(model.rows.count == 3 && model.rows[1].segment != model.rows[2].segment,"Explicit connection clear breaks history")
        usage.preferences.showCodex = false; published(330,80); drain(); model.reload(); drain()
        check(model.rows.count == 3,"Hidden providers are not recorded")
        usage.preferences.showCodex = true
        model.provider = "claude"; model.provider = "codex"; drain()
        check(model.rows.count == 3 && model.rows.allSatisfy { $0.provider == "codex" },"Rapid filter changes ignore obsolete query completions")
        model.setRetention(90); drain()
        check(preferences.integer(forKey:"history.retentionDays") == 90 && preferences.bool(forKey:"history.recording"),"Recording and retention preferences persist")
        check(model.ranges == [1, 7, 30, 90], "Every range up to 90 days is offered while 90 days are kept")
        model.rangeDays = 90; drain()
        check(model.simplified && model.rows.count == 3, "A long range is simplified and still shows every reading here")
        model.setRetention(30); drain()
        check(model.ranges == [1, 7, 30] && model.rangeDays == 30, "Keeping less narrows the ranges, and the shown one with them")
        model.setRetention(7); drain()
        check(model.ranges == [1, 7] && model.rangeDays == 7 && !model.simplified, "A week's range is never simplified")
        let modelExport = root.appendingPathComponent("model-export.csv")
        model.export(to:modelExport); drain()
        check(!model.exporting && model.exportNotice == "Exported 3 samples to model-export.csv.", "The model reports what it exported")
        model.setRetention(90); drain()
        model.clearConfirmed(); drain()
        check(model.rows.isEmpty && !fm.fileExists(atPath:location.appendingPathComponent("history.sqlite").path),"Clear drains pending access and resets model")
        published(360,42); drain(); model.reload(); drain()
        check(model.rows.count == 1,"Recording can continue after clear")
        model.window = "weekly"; drain()
        check(model.rows.isEmpty,"Missing weekly data is an empty chart, not a session substitute")
        model.setRecording(false); drain()
        print("\(checks) history checks passed (temporary stores; no real usage or preferences changed)")
    }
}
