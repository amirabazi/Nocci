import SwiftUI

/// Settings › Sessions. Turning on writes nothing until the user has reviewed
/// the exact hooks, the same way Claude usage tracking is set up.
struct ClaudeSessionSettingsForm: View {
    @ObservedObject var model: ClaudeSessionModel
    @ObservedObject var notifications: NotificationService
    @ObservedObject var settingsState: SettingsState

    var body: some View {
        SettingsPage {
            SettingsTile("Claude Code Sessions", glyph: .symbol("terminal"),
                         footer: "Shows in the notch when a Claude Code session needs your permission, asks you a question, or finishes its turn, in the terminal and in editors such as VS Code. Nocci adds hooks to your Claude settings after you review them. It keeps only each session’s state, the time, its project folder’s name and the app it runs in: never prompts, replies, tool details or transcripts.") {
                SettingsValue("Status", statusText, tint: statusIsProblem ? .orange : .secondary, path: false)
                HStack {
                    if model.enabled {
                        if case .moved = model.status { Button("Reinstall…", action: review) }
                        Button("Turn Off…") { settingsState.confirmingSessionsOff = true }
                    } else {
                        Button("Turn On…", action: review)
                    }
                }
                if let error = settingsState.sessionError {
                    Text(error).font(.callout).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            SettingsTile("Notifications", glyph: .symbol("bell.badge"),
                         footer: "One notification each time a session starts waiting, naming only its project folder. Nothing is sent in Presentation Mode.") {
                SettingsToggle("Notify me when a session needs me", isOn: Binding(get: { model.notify }, set: { value in
                    model.notify = value
                    if value { notifications.requestAuthorization() }
                }))
                .disabled(!model.enabled)
                if model.notify && notifications.status == .denied {
                    Text(notifications.statusMessage).font(.callout).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open Notification Settings…") { notifications.openSystemSettings() }
                }
            }
        }
        .onAppear {
            model.refreshStatus()
            notifications.refresh()
        }
        .sheet(isPresented: $settingsState.reviewingSessions) {
            ClaudeSessionReviewSheet(model: model, settingsState: settingsState)
        }
        .alert("Turn off Claude Code sessions?", isPresented: $settingsState.confirmingSessionsOff) {
            Button("Turn Off", role: .destructive, action: turnOff)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Nocci removes only its own hooks from your Claude settings and deletes the session files and any settings backup it kept. Your other hooks and settings are left as they are.")
        }
    }

    private var statusText: String {
        switch model.status {
        case .off: return "Off"
        case .on: return "On"
        case .moved: return "On, but Nocci has moved. Reinstall to point the hooks here."
        case .removedOutside: return "Off. Nocci’s hooks were removed from your Claude settings."
        }
    }

    private var statusIsProblem: Bool {
        switch model.status {
        case .moved, .removedOutside: return true
        case .off, .on: return false
        }
    }

    private func review() {
        settingsState.sessionError = nil
        do {
            settingsState.sessionPlan = try model.reviewPlan()
            settingsState.sessionBlocker = nil
        } catch {
            settingsState.sessionPlan = nil
            settingsState.sessionBlocker = error.localizedDescription
        }
        settingsState.reviewingSessions = true
    }

    private func turnOff() {
        do {
            try model.turnOff()
            settingsState.sessionError = nil
        } catch {
            settingsState.sessionError = error.localizedDescription
        }
    }
}

struct ClaudeSessionReviewSheet: View {
    @ObservedObject var model: ClaudeSessionModel
    @ObservedObject var settingsState: SettingsState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: model.enabled ? "Reinstall Claude Code sessions" : "Turn on Claude Code sessions",
                        subtitle: "Nothing is written until you choose \(button). Your own hooks and every other setting are kept.",
                        glyph: .symbol("terminal"))
                .padding(20)
            Hairline()
            ScrollView {
                VStack(alignment: .leading, spacing: NotchMetrics.sectionGap) {
                    if let plan = settingsState.sessionPlan {
                        ReviewItem(label: "Settings file", value: plan.settingsPath,
                                   note: "Nocci adds one entry to each hook below, beside any hooks you already have.",
                                   code: plan.fragment)
                        ReviewItem(label: "Backup", value: plan.backupPath ?? "Not needed",
                                   note: plan.backupPath == nil
                                       ? "Either the file does not exist yet or Nocci already saved a copy of it."
                                       : "A copy of your current settings, made before the change. Deleted when you turn this off.")
                        ReviewItem(label: "What Nocci keeps", value: "State, time, project folder name, app",
                                   note: "Each hook runs Nocci in the background, so Claude Code never waits for it. Prompts, replies, tool details and transcripts are never kept.")
                        if !plan.warnings.isEmpty {
                            ReviewNotes(title: "Before you turn it on", messages: plan.warnings.map(\.message))
                        }
                    } else if let blocker = settingsState.sessionBlocker {
                        Text(blocker).font(.callout).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Hairline()
            HStack {
                Spacer()
                Button("Cancel") { settingsState.reviewingSessions = false }
                    .keyboardShortcut(.cancelAction)
                Button(button, action: turnOn)
                    .keyboardShortcut(.defaultAction)
                    .disabled(settingsState.sessionPlan == nil)
            }
            .padding(20)
        }
        .frame(width: 560, height: 520)
        .background(Color.black)
    }

    private var button: String { model.enabled ? "Reinstall" : "Turn On" }

    private func turnOn() {
        do {
            try model.turnOn()
            settingsState.reviewingSessions = false
        } catch {
            settingsState.sessionPlan = nil
            settingsState.sessionBlocker = error.localizedDescription
        }
    }
}
