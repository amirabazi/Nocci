import Foundation

// Deterministic fixtures only. Pace must refuse to guess far more often than
// it estimates, so most of these check that it declines.
@main
struct PaceTests {
    static func main() {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            guard condition() else { fatalError("FAIL: \(label)") }
            checks += 1
        }
        let start = Date(timeIntervalSince1970: 9_000_000)
        func at(_ minutes: Double) -> Date { start.addingTimeInterval(minutes * 60) }

        /// Seven readings over an hour, rising five points every ten minutes:
        /// 10% to 40%, a steady 30 points per hour.
        var steady: [PaceSample] = []
        for step in 0...6 { steady.append(PaceSample(captured: at(Double(step) * 10), used: 10 + Double(step) * 5)) }
        let now = at(60)

        let soon = Pace.estimate(samples: steady, now: now, reset: at(120))
        check(soon.verdict == .likelyToLast, "Thirty points an hour with one hour left is likely to last")
        check(soon.projectedAtReset == 70, "Projection is current usage plus rate times hours remaining")
        check(soon.basisMinutes == 60, "The estimate reports the span it is based on")

        check(Pace.estimate(samples: steady, now: now, reset: at(180)).verdict == .closeToLimit,
              "Landing exactly on 100 is close to the limit, not a failure")
        check(Pace.estimate(samples: steady, now: now, reset: at(240)).verdict == .mayRunOut,
              "Projected past 100 may run out before reset")

        // Refusals.
        check(Pace.estimate(samples: Array(steady.prefix(3)), now: at(20), reset: at(180)).verdict == .insufficient,
              "Fewer than four observations is not enough data")
        var brief: [PaceSample] = []
        for step in 0...4 { brief.append(PaceSample(captured: at(Double(step) * 5), used: 10 + Double(step))) }
        check(Pace.estimate(samples: brief, now: at(20), reset: at(180)).verdict == .insufficient,
              "A span under thirty minutes is not enough data")
        var flat: [PaceSample] = []
        for step in 0...6 { flat.append(PaceSample(captured: at(Double(step) * 10), used: 42)) }
        check(Pace.estimate(samples: flat, now: now, reset: at(180)).verdict == .noIncrease,
              "No usage increase is stated as such, never as an all-clear")
        check(Pace.estimate(samples: steady, now: now, reset: nil).verdict == .insufficient,
              "Without a reset time there is nothing to project to")
        check(Pace.estimate(samples: steady, now: now, reset: at(30)).verdict == .insufficient,
              "A reset already in the past cannot be projected to")
        check(Pace.estimate(samples: steady, now: at(66), reset: at(180)).verdict == .insufficient,
              "A stale latest reading is not a basis for an estimate")

        // Intervals longer than fifteen minutes are rejected, which here leaves
        // too few eligible observations to say anything.
        var sparse: [PaceSample] = []
        for step in 0...5 { sparse.append(PaceSample(captured: at(Double(step) * 20), used: 10 + Double(step) * 5)) }
        check(Pace.estimate(samples: sparse, now: at(100), reset: at(300)).verdict == .insufficient,
              "Sparse events leave pace unavailable rather than confident")

        // A material decrease is a reset or a correction: start a new segment.
        var afterReset = steady
        for step in 1...6 { afterReset.append(PaceSample(captured: at(60 + Double(step) * 10), used: Double(step) * 4)) }
        let renewed = Pace.estimate(samples: afterReset, now: at(120), reset: at(240))
        check(renewed.basisMinutes == 50,
              "A reset starts a new segment: the basis is the 50 minutes since it, not the whole 120")
        check(renewed.projectedAtReset == 72,
              "The new segment projects from its own rate: 24 points, 24 per hour, two hours left")

        // A one-point dip is rounding, not a reset.
        var wobble = steady
        wobble[3] = PaceSample(captured: at(30), used: steady[2].used - 0.5)
        check(Pace.estimate(samples: wobble, now: now, reset: at(120)).basisMinutes == 60,
              "A sub-point decrease is tolerated as rounding")

        // Idle time counts against the rate rather than being ignored.
        var idled = steady
        idled.append(PaceSample(captured: at(70), used: 40))
        idled.append(PaceSample(captured: at(80), used: 40))
        let slowed = Pace.estimate(samples: idled, now: at(80), reset: at(140))
        check(slowed.projectedAtReset! < soon.projectedAtReset!, "Idle intervals slow the projected rate")

        check(Pace.estimate(samples: [], now: now, reset: at(180)).verdict == .insufficient,
              "No samples at all is not enough data")

        // Hysteresis: a label may not flip on a single evaluation.
        var tracker = PaceTracker()
        check(tracker.update(.likelyToLast) == .likelyToLast, "The first verdict is adopted immediately")
        check(tracker.update(.mayRunOut) == .likelyToLast, "One warning evaluation does not flip the label")
        check(tracker.update(.mayRunOut) == .mayRunOut, "Two consecutive warnings do flip the label")
        check(tracker.update(.likelyToLast) == .mayRunOut, "One calm evaluation does not clear a warning")
        check(tracker.update(.likelyToLast) == .likelyToLast, "Two consecutive calm evaluations clear it")
        var flicker = PaceTracker()
        _ = flicker.update(.likelyToLast)
        for _ in 0..<10 { _ = flicker.update(.mayRunOut); _ = flicker.update(.likelyToLast) }
        check(flicker.update(.likelyToLast) == .likelyToLast, "Alternating evaluations never oscillate the label")

        // A provider's line reports its limiting window. An unknown window must
        // never be rounded up into a confident all-clear for the whole provider.
        func estimate(_ verdict: PaceVerdict, _ minutes: Int = 60) -> PaceEstimate {
            PaceEstimate(verdict: verdict, basisMinutes: minutes, projectedAtReset: nil)
        }
        check(Pace.combine([]).verdict == .insufficient, "A provider with no windows has nothing to say")
        check(Pace.combine([estimate(.likelyToLast), estimate(.likelyToLast)]).verdict == .likelyToLast,
              "Two calm windows are calm")
        check(Pace.combine([estimate(.likelyToLast), estimate(.mayRunOut)]).verdict == .mayRunOut,
              "The limiting window decides")
        check(Pace.combine([estimate(.closeToLimit), estimate(.mayRunOut)]).verdict == .mayRunOut,
              "The more severe of two warnings decides")
        check(Pace.combine([estimate(.likelyToLast), estimate(.closeToLimit)]).verdict == .closeToLimit,
              "A single window close to the limit is reported")
        check(Pace.combine([estimate(.likelyToLast), estimate(.insufficient)]).verdict == .insufficient,
              "An unknown window suppresses an all-clear for the provider")
        check(Pace.combine([estimate(.mayRunOut), estimate(.insufficient)]).verdict == .mayRunOut,
              "A known warning still outranks an unknown window")
        check(Pace.combine([estimate(.noIncrease), estimate(.likelyToLast)]).verdict == .likelyToLast,
              "An idle window does not suppress a genuine estimate")
        check(Pace.combine([estimate(.noIncrease), estimate(.noIncrease)]).verdict == .noIncrease,
              "All windows idle reports no increase")
        check(Pace.combine([estimate(.likelyToLast, 45), estimate(.mayRunOut, 80)]).basisMinutes == 80,
              "The reported basis is the deciding window's")

        print("\(checks) pace checks passed")
    }
}
