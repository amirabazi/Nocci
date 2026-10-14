import AppKit
import Foundation
import UserNotifications

/// The only part of the alert feature that touches UserNotifications. The
/// decision rules live in `Alerts.swift` and never import this framework.
final class NotificationService: NSObject, ObservableObject, AlertDelivery {
    enum Status: Equatable { case notDetermined, allowed, denied, provisional, unavailable }

    @Published private(set) var status: Status = .notDetermined
    @Published private(set) var errorMessage: String?
    /// Raised when the user clicks a delivered alert, with its identifier.
    var onOpenRequested: ((String) -> Void)?

    private let center: UNUserNotificationCenter?

    override init() {
        // `UNUserNotificationCenter.current()` raises for a bundle macOS does
        // not accept, and that is an Objective-C exception Swift cannot catch.
        // Only construct it when the process really is a bundled app.
        center = Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
        super.init()
        center?.delegate = self
        if center == nil { status = .unavailable }
    }

    var statusMessage: String {
        switch status {
        case .notDetermined: return "Nocci will ask for permission when you turn an alert on."
        case .allowed: return "Notifications are allowed."
        case .provisional: return "Notifications are delivered quietly to Notification Centre."
        case .denied: return "Notifications are turned off for Nocci in System Settings."
        case .unavailable: return "This build cannot post notifications. Run Nocci from a built app bundle."
        }
    }

    /// Test delivery is available only after macOS has granted some form of
    /// notification authorization. The button remains visible while disabled
    /// so permission and recovery are understandable in one place.
    var canDeliver: Bool { status == .allowed || status == .provisional }

    /// Reads the real system state. Never prompts.
    func refresh() {
        guard let center else { return }
        center.getNotificationSettings { [weak self] settings in
            let status: Status
            switch settings.authorizationStatus {
            case .notDetermined: status = .notDetermined
            case .denied: status = .denied
            case .provisional: status = .provisional
            case .authorized: status = .allowed
            @unknown default: status = .notDetermined
            }
            DispatchQueue.main.async {
                self?.status = status
                // An error from while permission was missing is out of date
                // once the user allows notifications.
                if status == .allowed || status == .provisional { self?.errorMessage = nil }
            }
        }
    }

    /// Both options are requested together, so enabling sound later needs no
    /// second prompt. Called only when the user switches an alert on.
    func requestAuthorization() {
        guard let center, status == .notDetermined else { return }
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            DispatchQueue.main.async {
                self?.errorMessage = error?.localizedDescription
                self?.status = granted ? .allowed : .denied
            }
        }
    }

    func send(_ message: AlertMessage, sound: Bool) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = message.title
        content.body = message.body
        if sound { content.sound = .default }
        // A stable identifier means a repeated crossing replaces rather than stacks.
        center.add(UNNotificationRequest(identifier: message.identifier, content: content, trigger: nil)) { [weak self] error in
            guard let error else { return }
            DispatchQueue.main.async { self?.errorMessage = error.localizedDescription }
        }
    }

    /// Clears only Nocci's own delivered notifications. The notification
    /// centre scopes this to the calling app, so nothing else is touched.
    func clearDelivered() {
        center?.removeAllDeliveredNotifications()
    }

    func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }
}

extension NotificationService: UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // The app is an accessory and is rarely frontmost, but when it is the
        // banner must still appear. Sound follows the content, not this option.
        completionHandler(notification.request.content.sound == nil ? [.banner] : [.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let identifier = response.notification.request.identifier
        DispatchQueue.main.async { [weak self] in self?.onOpenRequested?(identifier) }
        completionHandler()
    }
}
