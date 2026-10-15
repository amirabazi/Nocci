import Foundation
import SQLite3

struct HistorySample: Identifiable {
    var id: Double { captured.timeIntervalSince1970 }
    let provider: String
    let window: String
    let epoch: String
    let captured: Date
    let reset: Date?
    let used: Double
    let segment: String
}

struct HistoryFailure: LocalizedError {
    let detail: String
    var errorDescription: String? { "History is unavailable: \(detail). Live usage is unaffected. Retry, or clear history to start a new store." }
}

/// The export file could not be written. The store itself is fine, so this
/// must not carry HistoryFailure's advice to clear it.
struct HistoryExportFailure: LocalizedError {
    let detail: String
    var errorDescription: String? { "\(detail). History itself is unchanged; choose another location and try again." }
}

/// Synchronous SQLite adapter. The app calls it only on HistoryModel's serial utility queue.
/// Schema 1 records observed utilization, never tokens, messages, credentials or account IDs.
final class HistoryStore {
    static let queryLimit = 20_000
    let directory: URL
    var file: URL { directory.appendingPathComponent("history.sqlite") }
    private var database: OpaquePointer?
    private var lastPrune: Date?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(directory: URL) { self.directory = directory }
    deinit { close() }
    func close() { if let database { sqlite3_close(database) }; database = nil }

    func open(create: Bool) throws -> Bool {
        if database != nil { return true }
        let fm = FileManager.default
        guard create || fm.fileExists(atPath: file.path) else { return false }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let attributes = try fm.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw HistoryFailure(detail: "invalid history directory") }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        if !fm.fileExists(atPath: file.path) {
            guard fm.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw HistoryFailure(detail: "could not create the database")
            }
        }
        for suffix in ["", "-journal", "-wal", "-shm"] {
            let path = file.path + suffix
            if fm.fileExists(atPath: path) {
                guard try fm.attributesOfItem(atPath: path)[.type] as? FileAttributeType == .typeRegular else {
                    throw HistoryFailure(detail: "invalid database file")
                }
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            }
        }
        var connection: OpaquePointer?
        guard sqlite3_open_v2(file.path, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if let connection { sqlite3_close(connection) }
            throw HistoryFailure(detail: "could not open the database")
        }
        database = connection
        do {
            sqlite3_busy_timeout(database, 1500)
            try execute("PRAGMA journal_mode=DELETE; PRAGMA secure_delete=ON;")
            let version = try scalar("PRAGMA user_version")
            guard version == 0 || version == 1 else { throw HistoryFailure(detail: "unsupported database version \(version)") }
            if version == 0 {
                // Version zero is accepted only for an empty database, not an unknown legacy schema.
                guard try scalar("SELECT count(*) FROM sqlite_master WHERE type='table'") == 0 else {
                    throw HistoryFailure(detail: "unrecognised database schema")
                }
                try execute("""
                    BEGIN IMMEDIATE;
                    CREATE TABLE samples (
                        provider TEXT NOT NULL, window TEXT NOT NULL, epoch TEXT NOT NULL,
                        captured REAL NOT NULL, reset REAL, used REAL NOT NULL CHECK(used>=0 AND used<=100),
                        segment TEXT NOT NULL, minute INTEGER NOT NULL,
                        PRIMARY KEY(provider,window,segment,minute), UNIQUE(provider,window,captured));
                    CREATE INDEX samples_time ON samples(provider,window,captured);
                    CREATE INDEX samples_retention ON samples(captured);
                    PRAGMA user_version=1;
                    COMMIT;
                    """)
            }
            let check = try prepare("PRAGMA quick_check(1)")
            defer { sqlite3_finalize(check) }
            guard sqlite3_step(check) == SQLITE_ROW, string(check, 0) == "ok" else {
                throw HistoryFailure(detail: "database integrity check failed")
            }
            // Also validate the schema before declaring an existing version usable.
            let statement = try prepare("SELECT provider,window,epoch,captured,reset,used,segment,minute FROM samples LIMIT 0")
            sqlite3_finalize(statement)
            return true
        } catch { close(); throw error }
    }

    /// Only fresh observations are eligible. Re-reading Claude's snapshot cannot invent samples.
    func record(_ snapshot: UsageSnapshot, provider: String, epoch: String, now: Date, since: Date) throws {
        guard ["claude", "codex"].contains(provider), snapshot.updated >= since,
              snapshot.updated <= now.addingTimeInterval(5), Freshness.isFresh(snapshot.updated, at: now) else { return }
        guard try open(create: true) else { return }
        try execute("BEGIN IMMEDIATE")
        do {
            for window in snapshot.windows where window.used.isFinite {
                if let reset = window.reset, reset <= snapshot.updated { continue }
                let kind = window.resolvedKind.rawValue
                let previous = try latest(provider: provider, window: kind)
                if let previous, previous.captured >= snapshot.updated { continue }
                let continues: Bool
                if let previous, let oldReset = previous.reset, let reset = window.reset {
                    continues = previous.epoch == epoch && abs(oldReset.timeIntervalSince(reset)) <= 60
                        && oldReset > snapshot.updated && snapshot.updated.timeIntervalSince(previous.captured) <= 900
                        && window.used >= previous.used - 1
                } else { continues = false }
                let segment = continues ? previous!.segment : UUID().uuidString
                let statement = try prepare("""
                    INSERT INTO samples(provider,window,epoch,captured,reset,used,segment,minute) VALUES(?,?,?,?,?,?,?,?)
                    ON CONFLICT(provider,window,segment,minute) DO UPDATE SET
                    captured=excluded.captured, reset=excluded.reset, used=excluded.used
                    WHERE excluded.captured>samples.captured
                    """)
                defer { sqlite3_finalize(statement) }
                bind(provider, statement, 1); bind(kind, statement, 2); bind(epoch, statement, 3)
                sqlite3_bind_double(statement, 4, snapshot.updated.timeIntervalSince1970)
                if let reset = window.reset { sqlite3_bind_double(statement, 5, reset.timeIntervalSince1970) }
                else { sqlite3_bind_null(statement, 5) }
                sqlite3_bind_double(statement, 6, min(100, max(0, window.used)))
                bind(segment, statement, 7)
                sqlite3_bind_int64(statement, 8, Int64(floor(snapshot.updated.timeIntervalSince1970 / 60)))
                try step(statement)
            }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }

    /// With `bucket`, each segment's lowest and highest reading per bucket of
    /// that many seconds instead of every minute, so a month or three fit
    /// under the query limit with the extremes and the segments kept. SQLite
    /// takes a bare column's value from the row that `max` or `min` picked.
    func query(provider: String, window: String, since: Date, until: Date, bucket: TimeInterval? = nil) throws -> [HistorySample] {
        guard try open(create: false) else { return [] }
        let columns = "provider,window,epoch,captured,reset,used,segment"
        let range = "FROM samples WHERE provider=?1 AND window=?2 AND captured>=?3 AND captured<=?4"
        let sql: String
        if bucket != nil {
            let grouped = "GROUP BY segment, CAST(captured / ?6 AS INTEGER)"
            sql = "SELECT \(columns) FROM (SELECT provider,window,epoch,captured,reset,max(used) AS used,segment \(range) \(grouped) "
                + "UNION SELECT provider,window,epoch,captured,reset,min(used) AS used,segment \(range) \(grouped)) "
                + "ORDER BY captured DESC LIMIT ?5"
        } else {
            sql = "SELECT \(columns) \(range) ORDER BY captured DESC LIMIT ?5"
        }
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        bind(provider, statement, 1); bind(window, statement, 2)
        sqlite3_bind_double(statement, 3, since.timeIntervalSince1970)
        sqlite3_bind_double(statement, 4, until.timeIntervalSince1970)
        sqlite3_bind_int(statement, 5, Int32(Self.queryLimit))
        if let bucket { sqlite3_bind_double(statement, 6, max(60, bucket)) }
        var rows: [HistorySample] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw failure() }
            rows.append(sample(statement))
        }
        return rows.reversed()
    }

    /// Every retained sample, oldest first per provider and quota, written as
    /// CSV a chunk at a time, so a full 90 days never sits in memory. It is
    /// written beside `url` and moved into place only once complete, so a
    /// file the user chose to replace survives a failure. Returns how many
    /// samples were written; a failure removes only the partial file.
    func exportCSV(to url: URL) throws -> Int {
        let fm = FileManager.default
        let partial = url.appendingPathExtension("partial")
        guard fm.createFile(atPath: partial.path, contents: Data(HistoryExport.header.utf8)) else {
            throw HistoryExportFailure(detail: "Could not create a file in that folder")
        }
        do {
            let count = try write(to: partial)
            if fm.fileExists(atPath: url.path) {
                _ = try fm.replaceItemAt(url, withItemAt: partial)
            } else {
                try fm.moveItem(at: partial, to: url)
            }
            return count
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }
    }
    private func write(to url: URL) throws -> Int {
        do {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            guard try open(create: false) else { return 0 }
            let statement = try prepare("SELECT provider,window,epoch,captured,reset,used,segment FROM samples ORDER BY provider,window,captured")
            defer { sqlite3_finalize(statement) }
            var count = 0, chunk = ""
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW else { throw failure() }
                chunk += HistoryExport.line(sample(statement))
                count += 1
                if chunk.utf8.count >= 65_536 { try handle.write(contentsOf: Data(chunk.utf8)); chunk = "" }
            }
            try handle.write(contentsOf: Data(chunk.utf8))
            return count
        } catch let error as HistoryFailure {
            throw error
        } catch {
            throw HistoryExportFailure(detail: "Could not write the export file")
        }
    }

    func prune(days: Int, now: Date, force: Bool = false) throws {
        guard force || lastPrune.map({ now.timeIntervalSince($0) >= 86400 }) ?? true else { return }
        guard try open(create: false) else { return }
        let statement = try prepare("DELETE FROM samples WHERE captured < ?")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, now.addingTimeInterval(-Double([7,30,90].contains(days) ? days : 30) * 86400).timeIntervalSince1970)
        try step(statement)
        lastPrune = now
    }

    /// Caller must obtain user confirmation. The dedicated store is closed on the serial queue first.
    func clear() throws {
        close()
        if FileManager.default.fileExists(atPath: directory.path) {
            guard try FileManager.default.attributesOfItem(atPath: directory.path)[.type] as? FileAttributeType == .typeDirectory else {
                throw HistoryFailure(detail: "invalid history directory")
            }
        }
        for suffix in ["", "-journal", "-wal", "-shm"] {
            let path = file.path + suffix
            if FileManager.default.fileExists(atPath: path) { try FileManager.default.removeItem(atPath: path) }
        }
        lastPrune = nil
    }

    private func latest(provider: String, window: String) throws -> HistorySample? {
        let statement = try prepare("SELECT provider,window,epoch,captured,reset,used,segment FROM samples WHERE provider=? AND window=? ORDER BY captured DESC LIMIT 1")
        defer { sqlite3_finalize(statement) }
        bind(provider, statement, 1); bind(window, statement, 2)
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW else { throw failure() }
        return sample(statement)
    }
    private func sample(_ s: OpaquePointer) -> HistorySample {
        HistorySample(provider: string(s,0), window: string(s,1), epoch: string(s,2),
                      captured: Date(timeIntervalSince1970: sqlite3_column_double(s,3)),
                      reset: sqlite3_column_type(s,4) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(s,4)),
                      used: sqlite3_column_double(s,5), segment: string(s,6))
    }
    private func string(_ s: OpaquePointer, _ index: Int32) -> String {
        sqlite3_column_text(s,index).map { String(cString: $0) } ?? ""
    }
    private func bind(_ value: String, _ s: OpaquePointer, _ index: Int32) {
        _ = value.withCString { sqlite3_bind_text(s,index,$0,-1,transient) }
    }
    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database,sql,-1,&statement,nil) == SQLITE_OK, let statement else { throw failure() }
        return statement
    }
    private func step(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }
    private func scalar(_ sql: String) throws -> Int {
        let s = try prepare(sql); defer { sqlite3_finalize(s) }
        guard sqlite3_step(s) == SQLITE_ROW else { throw failure() }
        return Int(sqlite3_column_int(s,0))
    }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database,sql,nil,nil,nil) == SQLITE_OK else { throw failure() }
    }
    private func failure() -> HistoryFailure { HistoryFailure(detail: database.map { String(cString: sqlite3_errmsg($0)) } ?? "database closed") }
}

/// The export's columns: no epoch or segment, which are Nocci's own
/// bookkeeping, and times in UTC so a spreadsheet in any zone reads them alike.
enum HistoryExport {
    static let header = "provider,quota,captured_utc,used_percent,resets_at_utc\n"

    static func line(_ sample: HistorySample) -> String {
        let reset = sample.reset.map(timestamp) ?? ""
        return "\(sample.provider),\(sample.window),\(timestamp(sample.captured)),\(sample.used),\(reset)\n"
    }

    /// "2026-09-30T12:00:00Z".
    private static func timestamp(_ date: Date) -> String { date.formatted(.iso8601) }
}

enum HistoryPlot {
    /// Preserve segment boundaries and extrema; bound chart rendering independently of retained rows.
    static func points(_ rows: [HistorySample], limit: Int = 1600) -> [HistorySample] {
        guard rows.count > limit else { return rows }
        let bucketSize = max(1, Int(ceil(Double(rows.count) / Double(max(1, limit / 4)))))
        var selected: [HistorySample] = []
        var start = 0
        while start < rows.count {
            var end = min(rows.count, start + bucketSize)
            if let boundary = ((start + 1)..<end).first(where: { rows[$0].segment != rows[start].segment }) { end = boundary }
            let bucket = Array(rows[start..<end])
            let candidates = [bucket.first!, bucket.min(by: { $0.used < $1.used })!, bucket.max(by: { $0.used < $1.used })!, bucket.last!]
            var seen = Set<Double>()
            selected += candidates.sorted(by: { $0.captured < $1.captured }).filter { seen.insert($0.id).inserted }
            start = end
        }
        return Array(selected.suffix(limit))
    }
}
