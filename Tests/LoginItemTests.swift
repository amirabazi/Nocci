import Foundation
import ServiceManagement

private final class FakeLoginItem: LoginItemManaging {
    var status: SMAppService.Status = .notRegistered
    var registrations = 0
    var removals = 0
    var registrationResult: SMAppService.Status = .enabled
    var failure: Error?
    func register() throws {
        registrations += 1
        if let failure { throw failure }
        status = registrationResult
    }
    func unregister() throws {
        removals += 1
        if let failure { throw failure }
        status = .notRegistered
    }
}

@main
struct LoginItemTests {
    static func main() {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            guard condition() else { fatalError("FAIL: \(label)") }
            checks += 1
        }
        let fake = FakeLoginItem()
        let model = LoginItemService(service: fake)
        check(!model.isRegistered && fake.registrations == 0, "Construction never enables login")
        model.setEnabled(false)
        check(fake.removals == 0, "Already disabled is a no-op")
        model.setEnabled(true)
        check(model.status == .enabled && model.isRegistered && fake.registrations == 1, "Register reads resulting system state")
        model.setEnabled(true)
        check(fake.registrations == 1, "Repeated enable does not register again")
        model.setEnabled(false)
        check(model.status == .notRegistered && !model.isRegistered && fake.removals == 1, "Disable unregisters")
        fake.registrationResult = .requiresApproval
        model.setEnabled(true)
        check(model.isRegistered && model.status == .requiresApproval, "Pending approval remains registered")
        check(model.statusMessage.contains("System Settings"), "Pending state explains approval")
        model.setEnabled(false)
        check(!model.isRegistered && fake.removals == 2, "Pending registration can be disabled")
        fake.failure = NSError(domain: "Fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Test failure"])
        model.setEnabled(true)
        check(!model.isRegistered && model.errorMessage?.contains("Test failure") == true, "Failed registration does not fake enabled state")
        fake.status = .enabled
        model.refresh()
        check(model.isRegistered && model.errorMessage == nil, "External system change reconciles state and clears old error")
        model.setEnabled(false)
        check(model.isRegistered && model.errorMessage != nil, "Failed removal preserves actual registration")
        fake.failure = nil
        model.setEnabled(false)
        check(!model.isRegistered && model.errorMessage == nil, "Retry succeeds and clears error")
        fake.status = .notFound
        model.refresh()
        check(!model.isRegistered && model.statusMessage.contains("stable app location"), "Missing service shows recovery guidance")
        fake.registrationResult = .enabled
        model.setEnabled(true)
        check(model.isRegistered, "Missing service can retry registration")
        fake.status = .requiresApproval
        model.refresh()
        check(model.status == .requiresApproval, "External approval revocation is reflected")
        print("\(checks) login-item checks passed (fake service; no system registration changed)")
    }
}
