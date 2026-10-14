import Foundation

/// The single definition of "stale" for provider readings.
///
/// It lives in its own leaf file, importing nothing but Foundation, because
/// `Usage`, `ClaudeIntegration`, `UsageModel` and `HistoryStore` all need it
/// and none of them should have to depend on each other to get it.
///
/// There is no clock object: every call takes `now` explicitly, which is what
/// makes these rules testable and is the pattern the rest of the app already
/// uses. Claude is event-driven, so a stale reading means no Claude Code
/// activity, not a broken connection.
enum Freshness {
    static let staleAfter: TimeInterval = 300

    static func isStale(_ updated: Date, at now: Date) -> Bool {
        now.timeIntervalSince(updated) >= staleAfter
    }

    static func isFresh(_ updated: Date, at now: Date) -> Bool {
        !isStale(updated, at: now)
    }

    /// Whole minutes elapsed, never negative: a provider clock running ahead of
    /// ours must not render as a reading from the future.
    static func minutesAgo(_ updated: Date, at now: Date) -> Int {
        max(0, Int(now.timeIntervalSince(updated) / 60))
    }

    static func summary(_ updated: Date, at now: Date) -> String {
        let minutes = minutesAgo(updated, at: now)
        if isStale(updated, at: now) { return "Last updated \(minutes)m ago" }
        return minutes > 0 ? "Updated \(minutes)m ago" : "Updated just now"
    }
}
