import Foundation

@main
struct UpdatePolicyTests {
    static func main() {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            guard condition() else { fatalError("FAIL: \(label)") }
            checks += 1
        }

        let feed = "https://updates.example.com/nocci/appcast.xml"
        let key = Data(repeating: 7, count: 32).base64EncodedString()
        let configured = UpdateConfiguration(info: ["SUFeedURL": feed, "SUPublicEDKey": key])
        check(configured.isConfigured, "An HTTPS feed and 32-byte Ed25519 public key enable updates")
        check(configured.feedURL?.absoluteString == feed, "The configured feed is preserved exactly")
        check(configured.releasesURL == UpdateConfiguration.defaultReleasesURL,
              "Manual recovery uses the project releases page")

        check(!UpdateConfiguration(info: ["SUFeedURL": "http://updates.example.com/appcast.xml",
                                          "SUPublicEDKey": key]).isConfigured,
              "An insecure HTTP feed is rejected")
        check(!UpdateConfiguration(info: ["SUFeedURL": "https://user:secret@example.com/appcast.xml",
                                          "SUPublicEDKey": key]).isConfigured,
              "Feed URLs cannot embed credentials")
        check(!UpdateConfiguration(info: ["SUFeedURL": feed]).isConfigured,
              "A feed without an update-signing key stays disabled")
        check(!UpdateConfiguration(info: ["SUFeedURL": feed, "SUPublicEDKey": "not-a-key"]).isConfigured,
              "A malformed public key stays disabled")

        let suite = "notch-update-policy-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        check(UpdateChannel.load(from: defaults) == .stable, "Stable is the default channel")
        check(UpdateChannel.stable.allowedSparkleChannels.isEmpty,
              "Stable accepts only Sparkle's default channel")
        check(UpdateChannel.preview.allowedSparkleChannels == ["preview"],
              "Preview opts into preview items while retaining stable items")
        UpdateChannel.preview.save(to: defaults)
        check(UpdateChannel.load(from: defaults) == .preview, "The chosen update channel persists")
        defaults.set("unknown", forKey: "updateChannel")
        check(UpdateChannel.load(from: defaults) == .stable, "An unknown stored channel recovers to stable")
        UserDefaults().removePersistentDomain(forName: suite)

        check(UpdatePolicy.allowsCheck(presentationActive: false, userInitiated: false),
              "Scheduled checks run normally outside Presentation Mode")
        check(!UpdatePolicy.allowsCheck(presentationActive: true, userInitiated: false),
              "Scheduled checks stay quiet during Presentation Mode")
        check(UpdatePolicy.allowsCheck(presentationActive: true, userInitiated: true),
              "A manual check remains available during Presentation Mode")
        check(!UpdatePolicy.allowsRelaunch(presentationActive: true, explicitInstall: false),
              "An automatic relaunch is suppressed during Presentation Mode")
        check(UpdatePolicy.allowsRelaunch(presentationActive: true, explicitInstall: true),
              "An explicitly approved install may relaunch during Presentation Mode")

        // Sparkle reports "no update" and a cancelled install as errors; neither
        // is a failure the user should read about.
        check(UpdatePolicy.cycleMessage(domain: nil, code: 0, description: "") == "Update check finished.",
              "A finished cycle without an error says so")
        check(UpdatePolicy.cycleMessage(domain: "SUSparkleErrorDomain", code: 1001, description: "You're up to date!")
                == "Nocci is up to date.", "No update found is not a failure")
        check(UpdatePolicy.cycleMessage(domain: "SUSparkleErrorDomain", code: 4007, description: "Canceled")
                == "Update check finished.", "A cancelled install is not a failure")
        check(UpdatePolicy.cycleMessage(domain: "SUSparkleErrorDomain", code: 4008, description: "Later")
                == "Update check finished.", "Installing later is not a failure")
        check(UpdatePolicy.cycleMessage(domain: "Nocci.UpdatePolicy", code: 1, description: "x")
                == "Automatic checks are paused during Presentation Mode.", "The presentation pause is named")
        check(UpdatePolicy.cycleMessage(domain: "SUSparkleErrorDomain", code: 2001, description: "The feed could not be downloaded.")
                == "Update check failed: The feed could not be downloaded.", "A real failure is reported")

        print("\(checks) update-policy checks passed")
    }
}
