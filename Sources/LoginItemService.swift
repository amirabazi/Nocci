import Foundation
import Combine
import ServiceManagement

protocol LoginItemManaging {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

struct MainAppLoginItem: LoginItemManaging {
    var status: SMAppService.Status { SMAppService.mainApp.status }
    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
}

final class LoginItemService: ObservableObject {
    @Published private(set) var status: SMAppService.Status
    @Published private(set) var errorMessage: String?
    private let service: LoginItemManaging

    init(service: LoginItemManaging = MainAppLoginItem()) {
        self.service = service
        status = service.status
    }

    // Pending approval is registered but not yet eligible to run. Keeping the
    // switch on allows the user to unregister it without claiming it is enabled.
    var isRegistered: Bool { status == .enabled || status == .requiresApproval }
    var statusMessage: String {
        switch status {
        case .enabled: return "Nocci will open automatically when you log in."
        case .requiresApproval: return "Allow Nocci in System Settings to finish enabling launch at login."
        case .notRegistered: return "Open Nocci automatically when you log in to your Mac."
        case .notFound: return "macOS couldn’t find this app’s login registration. Try enabling it again from a stable app location."
        @unknown default: return "Login status is unavailable. Check System Settings."
        }
    }

    func refresh() {
        let current = service.status
        if current != status { errorMessage = nil }
        status = current
    }

    func setEnabled(_ enabled: Bool) {
        refresh()
        errorMessage = nil
        guard enabled != isRegistered else { return }
        do {
            if enabled { try service.register() }
            else { try service.unregister() }
            refresh()
        } catch {
            refresh()
            errorMessage = "Couldn’t \(enabled ? "enable" : "disable") launch at login. \(error.localizedDescription)"
        }
    }

    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}
