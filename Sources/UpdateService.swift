import AppKit
import Combine
import Sparkle

/// Owns Sparkle's standard native updater UI. The feed and public key are
/// release-time configuration injected by `build.sh`, so a local build without
/// them stays usable in manual mode instead of failing.
/// `SPUUpdater` must itself be used on the main thread, so every entry point
/// asserts that the way the rest of the app's observable objects do.
final class UpdateService: NSObject, ObservableObject {
    @Published private(set) var configured: Bool
    @Published private(set) var automaticallyChecks = false
    @Published private(set) var statusMessage: String
    @Published private(set) var channel: UpdateChannel

    let configuration: UpdateConfiguration
    let versionDescription: String

    private let defaults: UserDefaults
    private let presentationActive: () -> Bool
    private var controller: SPUStandardUpdaterController?
    private var explicitInstallApproved = false

    init(bundle: Bundle = .main,
         defaults: UserDefaults = .standard,
         presentationActive: @escaping () -> Bool) {
        let info = bundle.infoDictionary ?? [:]
        configuration = UpdateConfiguration(info: info)
        configured = configuration.isConfigured
        channel = UpdateChannel.load(from: defaults)
        self.defaults = defaults
        self.presentationActive = presentationActive
        let marketing = info["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info["CFBundleVersion"] as? String ?? "unknown"
        versionDescription = "\(marketing) (\(build))"
        statusMessage = configuration.isConfigured
            ? "The signed update feed is ready."
            : "Automatic updates are not configured in this build. Use Open Releases… to check manually."
        super.init()
    }

    func start() {
        precondition(Thread.isMainThread)
        guard configured, controller == nil else { return }
        let controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        controller.startUpdater()
        sync()
        DispatchQueue.main.async { [weak self] in self?.sync() }
    }

    var actionTitle: String { configured ? "Check for Updates…" : "Open Releases…" }

    func performPrimaryAction() {
        precondition(Thread.isMainThread)
        guard configured else {
            NSWorkspace.shared.open(configuration.releasesURL)
            return
        }
        guard let controller, controller.updater.canCheckForUpdates else {
            statusMessage = "The updater is busy. Try again in a moment."
            sync()
            return
        }
        statusMessage = "Checking for updates…"
        controller.checkForUpdates(nil)
        sync()
    }

    func setAutomaticallyChecks(_ enabled: Bool) {
        precondition(Thread.isMainThread)
        guard configured, let updater = controller?.updater else { return }
        updater.automaticallyChecksForUpdates = enabled
        sync()
    }

    func setChannel(_ channel: UpdateChannel) {
        precondition(Thread.isMainThread)
        guard self.channel != channel else { return }
        self.channel = channel
        channel.save(to: defaults)
        controller?.updater.resetUpdateCycleAfterShortDelay()
        statusMessage = channel == .stable
            ? "Stable releases selected."
            : "Preview releases and stable releases selected."
    }

    func presentationDidEnd() {
        precondition(Thread.isMainThread)
        guard automaticallyChecks else { return }
        controller?.updater.resetUpdateCycleAfterShortDelay()
    }

    private func sync() {
        guard let updater = controller?.updater else {
            automaticallyChecks = false
            return
        }
        automaticallyChecks = updater.automaticallyChecksForUpdates
    }
}

extension UpdateService: SPUUpdaterDelegate {
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        channel.allowedSparkleChannels
    }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        let userInitiated = updateCheck == .updates
        guard UpdatePolicy.allowsCheck(presentationActive: presentationActive(),
                                       userInitiated: userInitiated) else {
            throw NSError(domain: "Nocci.UpdatePolicy", code: 1,
                          userInfo: [NSLocalizedDescriptionKey:
                            "Automatic checks are paused during Presentation Mode."])
        }
    }

    func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice,
                 forUpdate updateItem: SUAppcastItem, state: SPUUserUpdateState) {
        if choice == .install { explicitInstallApproved = true }
    }

    func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool {
        UpdatePolicy.allowsRelaunch(presentationActive: presentationActive(),
                                    explicitInstall: explicitInstallApproved)
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
                 error: (any Error)?) {
        let error = error as NSError?
        statusMessage = UpdatePolicy.cycleMessage(domain: error?.domain, code: error?.code ?? 0,
                                                  description: error?.localizedDescription ?? "")
        sync()
    }
}
