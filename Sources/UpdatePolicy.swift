import Foundation

enum UpdateChannel: String, CaseIterable {
    case stable, preview

    var title: String { self == .stable ? "Stable" : "Preview" }
    var allowedSparkleChannels: Set<String> { self == .stable ? [] : ["preview"] }

    static func load(from defaults: UserDefaults = .standard) -> UpdateChannel {
        defaults.string(forKey: "updateChannel").flatMap(UpdateChannel.init(rawValue:)) ?? .stable
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: "updateChannel")
    }
}

struct UpdateConfiguration: Equatable {
    static let defaultReleasesURL = URL(string: "https://github.com/amirabazi/Nocci/releases")!

    var feedURL: URL?
    var publicKey: String?
    var releasesURL: URL

    init(info: [String: Any], releasesURL: URL = defaultReleasesURL) {
        let feed = (info["SUFeedURL"] as? String).flatMap(URL.init(string:))
        let key = info["SUPublicEDKey"] as? String
        self.feedURL = feed
        self.publicKey = key
        self.releasesURL = releasesURL
    }

    var isConfigured: Bool {
        guard let feedURL, feedURL.scheme?.lowercased() == "https",
              feedURL.user == nil, feedURL.password == nil,
              let publicKey, let bytes = Data(base64Encoded: publicKey), bytes.count == 32 else { return false }
        return true
    }
}

enum UpdatePolicy {
    /// Scheduled network work stays quiet during Presentation Mode. A manual
    /// check is an explicit user action and may proceed through Sparkle's UI.
    static func allowsCheck(presentationActive: Bool, userInitiated: Bool) -> Bool {
        userInitiated || !presentationActive
    }

    /// Production builds disallow silent automatic installation. Every
    /// relaunch therefore follows a choice in Sparkle's standard UI.
    static func allowsRelaunch(presentationActive: Bool, explicitInstall: Bool) -> Bool {
        explicitInstall || !presentationActive
    }

    /// The status line after an update cycle. Sparkle reports "no update
    /// found" (1001) and a cancelled or postponed install (4007, 4008) as
    /// errors; none of them is a failure.
    static func cycleMessage(domain: String?, code: Int, description: String) -> String {
        switch (domain, code) {
        case (nil, _): return "Update check finished."
        case ("Nocci.UpdatePolicy", _): return "Automatic checks are paused during Presentation Mode."
        case ("SUSparkleErrorDomain", 1001): return "Nocci is up to date."
        case ("SUSparkleErrorDomain", 4007), ("SUSparkleErrorDomain", 4008): return "Update check finished."
        default: return "Update check failed: \(description)"
        }
    }
}
