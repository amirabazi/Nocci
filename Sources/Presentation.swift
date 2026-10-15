import Foundation

/// Manual suppression of this app's own surfaces, modelled separately from the
/// user's normal hidden/pinned preferences so ending it restores what they chose.
///
/// This is not meeting detection and not screen-capture protection. It hides
/// Nocci and discards Nocci notifications, nothing else.
struct PresentationState: Equatable {
    /// nil means off. `Date.distantFuture` means on until ended by hand.
    /// Anything else is an absolute expiry, so a relaunch can resume or restore.
    var until: Date?

    init(until: Date? = nil) { self.until = until }

    init(minutes: Int, from now: Date) {
        until = now.addingTimeInterval(TimeInterval(minutes) * 60)
    }

    static let untilEnded = PresentationState(until: .distantFuture)

    func isActive(at now: Date) -> Bool {
        guard let until else { return false }
        return now < until
    }

    func menuDescription(at now: Date) -> String {
        guard let until else { return "Off" }
        guard until != .distantFuture else { return "On until you end it" }
        let minutes = max(0, Int(ceil(until.timeIntervalSince(now) / 60)))
        return "Ends in \(minutes)m"
    }

    /// A session that lapsed while the app was closed restores normal behaviour
    /// rather than resuming, because the expiry stored is absolute.
    static func load(from defaults: UserDefaults = .standard, now: Date = Date()) -> PresentationState {
        guard let stamp = defaults.object(forKey: "presentationUntil") as? Double else { return PresentationState() }
        let state = PresentationState(until: Date(timeIntervalSince1970: stamp))
        return state.isActive(at: now) ? state : PresentationState()
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let until else {
            defaults.removeObject(forKey: "presentationUntil")
            return
        }
        defaults.set(until.timeIntervalSince1970, forKey: "presentationUntil")
    }
}
