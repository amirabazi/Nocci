import Foundation

// Presentation suppression is a value with rules, tested as one. Nothing here
// touches windows, menus or the notification centre.
@main
struct PresentationTests {
    static func main() {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            guard condition() else { fatalError("FAIL: \(label)") }
            checks += 1
        }
        let now = Date(timeIntervalSince1970: 5_000_000)

        check(!PresentationState().isActive(at: now), "Presentation mode is off by default")
        check(PresentationState().until == nil, "Off means no expiry at all")

        let hour = PresentationState(minutes: 60, from: now)
        check(hour.isActive(at: now), "A timed session is active immediately")
        check(hour.isActive(at: now.addingTimeInterval(3_599)), "A one-hour session is active just before it lapses")
        check(!hour.isActive(at: now.addingTimeInterval(3_600)), "A one-hour session lapses exactly on time")
        check(!hour.isActive(at: now.addingTimeInterval(86_400)), "A lapsed session stays lapsed")

        let half = PresentationState(minutes: 30, from: now)
        check(half.isActive(at: now.addingTimeInterval(1_799)) && !half.isActive(at: now.addingTimeInterval(1_800)),
              "A thirty-minute session lapses on time")

        let manual = PresentationState.untilEnded
        check(manual.isActive(at: now) && manual.isActive(at: now.addingTimeInterval(86_400 * 365)),
              "An open-ended session never lapses on its own")
        check(!manual.isTimed, "An open-ended session is not a timed one")
        check(hour.isTimed, "A timed session knows it is timed")

        // Persistence: an absolute expiry, so a relaunch resumes or restores.
        let suiteName = "notch-presentation-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!

        check(PresentationState.load(from: defaults, now: now) == PresentationState(),
              "Nothing stored means presentation mode is off")

        hour.save(to: defaults)
        check(PresentationState.load(from: defaults, now: now) == hour,
              "A session still running is resumed after a relaunch")
        check(PresentationState.load(from: defaults, now: now.addingTimeInterval(1_800)) == hour,
              "A session resumed mid-way keeps its original expiry")
        check(PresentationState.load(from: defaults, now: now.addingTimeInterval(3_600)) == PresentationState(),
              "A session that lapsed while the app was closed restores normal behaviour")

        manual.save(to: defaults)
        check(PresentationState.load(from: defaults, now: now.addingTimeInterval(86_400)) == manual,
              "An open-ended session survives a relaunch")

        PresentationState().save(to: defaults)
        check(PresentationState.load(from: defaults, now: now) == PresentationState(),
              "Ending presentation mode clears the stored expiry")

        UserDefaults().removePersistentDomain(forName: suiteName)

        check(hour.menuDescription(at: now) == "Ends in 60m", "A timed session reports its remaining time")
        check(hour.menuDescription(at: now.addingTimeInterval(3_000)) == "Ends in 10m",
              "The remaining time counts down")
        check(manual.menuDescription(at: now) == "On until you end it", "An open-ended session says so")

        print("\(checks) presentation checks passed")
    }
}
