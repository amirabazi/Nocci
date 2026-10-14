import Foundation

// One definition of "stale", so the five copies of 300 cannot drift apart.
@main
struct FreshnessTests {
    static func main() {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            guard condition() else { fatalError("FAIL: \(label)") }
            checks += 1
        }
        let read = Date(timeIntervalSince1970: 6_000_000)
        func at(_ seconds: TimeInterval) -> Date { read.addingTimeInterval(seconds) }

        check(Freshness.staleAfter == 300, "The stale threshold stays five minutes")

        check(!Freshness.isStale(read, at: read), "A reading taken now is fresh")
        check(!Freshness.isStale(read, at: at(299)), "A reading is fresh until the threshold")
        check(Freshness.isStale(read, at: at(300)), "A reading is stale exactly on the threshold")
        check(Freshness.isStale(read, at: at(86_400)), "An old reading stays stale")
        check(Freshness.isFresh(read, at: at(299)) && !Freshness.isFresh(read, at: at(300)),
              "Fresh is the exact inverse of stale")

        // A provider clock running ahead must not read as stale.
        check(!Freshness.isStale(read, at: at(-3_600)), "A reading from the future is not stale")
        check(Freshness.minutesAgo(read, at: at(-3_600)) == 0, "A future reading reports no elapsed time")

        check(Freshness.minutesAgo(read, at: read) == 0, "No time elapsed reads as zero minutes")
        check(Freshness.minutesAgo(read, at: at(59)) == 0, "Under a minute reads as zero minutes")
        check(Freshness.minutesAgo(read, at: at(60)) == 1, "A full minute reads as one")
        check(Freshness.minutesAgo(read, at: at(3_660)) == 61, "Elapsed minutes do not wrap at an hour")

        check(Freshness.summary(read, at: read) == "Updated just now", "A brand new reading says so")
        check(Freshness.summary(read, at: at(120)) == "Updated 2m ago", "A recent reading reports its age")
        check(Freshness.summary(read, at: at(300)) == "Last updated 5m ago",
              "A stale reading is worded differently from a fresh one")
        check(Freshness.summary(read, at: at(-3_600)) == "Updated just now",
              "A future reading is not described as aged")

        print("\(checks) freshness checks passed")
    }
}
