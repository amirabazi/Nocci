import Foundation

struct PaceSample: Equatable {
    var captured: Date
    var used: Double
}

enum PaceVerdict: Equatable {
    case insufficient, noIncrease, likelyToLast, closeToLimit, mayRunOut

    /// Every phrase is hedged on purpose. These are estimates from observed
    /// percentage points, not a model of the plan's real capacity.
    var summary: String {
        switch self {
        case .insufficient: return "Not enough recent data"
        case .noIncrease: return "No recent usage increase"
        case .likelyToLast: return "At this pace, likely to last"
        case .closeToLimit: return "At this pace, close to the limit"
        case .mayRunOut: return "At this pace, may run out before reset"
        }
    }
    var isWarning: Bool { self == .closeToLimit || self == .mayRunOut }
}

struct PaceEstimate: Equatable {
    var verdict: PaceVerdict
    /// The eligible observed span the estimate rests on, so the UI can say
    /// "Based on the last 60 minutes" rather than implying continuous coverage.
    var basisMinutes: Int
    var projectedAtReset: Double?
}

enum Pace {
    static let lookback: TimeInterval = 2 * 3600
    static let minimumObservations = 4
    static let minimumSpan: TimeInterval = 30 * 60
    static let maximumInterval: TimeInterval = 15 * 60
    static let minimumRisingIntervals = 2
    /// Below this, a decrease is rounding rather than a new period.
    static let decreaseTolerance = 1.0

    static func estimate(samples: [PaceSample], now: Date, reset: Date?) -> PaceEstimate {
        let none = PaceEstimate(verdict: .insufficient, basisMinutes: 0, projectedAtReset: nil)
        guard let reset, reset > now else { return none }

        let recent = samples
            .filter { now.timeIntervalSince($0.captured) <= lookback && $0.captured <= now }
            .sorted { $0.captured < $1.captured }
        guard let latest = recent.last, Freshness.isFresh(latest.captured, at: now) else { return none }

        // A material decrease means a reset or a correction; only the samples
        // after it describe the current period.
        var segment = recent
        for index in stride(from: recent.count - 1, to: 0, by: -1) where
            recent[index - 1].used - recent[index].used > decreaseTolerance {
            segment = Array(recent[index...])
            break
        }

        guard segment.count >= minimumObservations,
              let first = segment.first,
              latest.captured.timeIntervalSince(first.captured) >= minimumSpan else { return none }

        var hours = 0.0
        var gained = 0.0
        var rising = 0
        var eligible = 0
        for (previous, current) in zip(segment, segment.dropFirst()) {
            let elapsed = current.captured.timeIntervalSince(previous.captured)
            guard elapsed > 0, elapsed <= maximumInterval else { continue }
            eligible += 1
            hours += elapsed / 3600
            let delta = current.used - previous.used
            if delta > 0 { gained += delta; rising += 1 }
        }

        // Count the observations the eligible intervals actually connect, not
        // the ones that were merely present in the window.
        guard eligible + 1 >= minimumObservations, hours > 0 else { return none }
        let basis = Int((hours * 60).rounded())
        guard basis >= Int(minimumSpan / 60) else { return none }
        guard rising >= minimumRisingIntervals else {
            return PaceEstimate(verdict: .noIncrease, basisMinutes: basis, projectedAtReset: nil)
        }

        let rate = gained / hours
        let projected = latest.used + rate * (reset.timeIntervalSince(now) / 3600)
        let verdict: PaceVerdict = projected > 100 ? .mayRunOut : projected >= 90 ? .closeToLimit : .likelyToLast
        return PaceEstimate(verdict: verdict, basisMinutes: basis, projectedAtReset: projected)
    }
}

extension Pace {
    /// A provider's line reports its limiting window. An unknown window
    /// outranks a calm one, because claiming the whole allowance is safe while
    /// one quota is unmeasured would be the one genuinely misleading outcome.
    static func combine(_ estimates: [PaceEstimate]) -> PaceEstimate {
        func rank(_ verdict: PaceVerdict) -> Int {
            switch verdict {
            case .mayRunOut: return 4
            case .closeToLimit: return 3
            case .insufficient: return 2
            // An idle window is known information, not an unknown one, so it
            // must not outrank a genuine estimate from a sibling window.
            case .likelyToLast: return 1
            case .noIncrease: return 0
            }
        }
        guard var worst = estimates.first else {
            return PaceEstimate(verdict: .insufficient, basisMinutes: 0, projectedAtReset: nil)
        }
        for estimate in estimates.dropFirst() where rank(estimate.verdict) > rank(worst.verdict) {
            worst = estimate
        }
        return worst
    }
}

/// Requires two consecutive evaluations before moving between a calm label and
/// a warning one, so ordinary variation cannot make the line flicker.
struct PaceTracker {
    private(set) var published: PaceVerdict?
    private var pending: PaceVerdict?
    private var pendingCount = 0

    mutating func update(_ verdict: PaceVerdict) -> PaceVerdict {
        guard let current = published else {
            published = verdict
            return verdict
        }
        guard verdict != current else {
            pending = nil
            pendingCount = 0
            return current
        }
        // Only crossing the calm/warning boundary needs confirming.
        guard verdict.isWarning != current.isWarning else {
            published = verdict
            return verdict
        }
        if pending == verdict { pendingCount += 1 } else { pending = verdict; pendingCount = 1 }
        guard pendingCount >= 2 else { return current }
        published = verdict
        pending = nil
        pendingCount = 0
        return verdict
    }
}
