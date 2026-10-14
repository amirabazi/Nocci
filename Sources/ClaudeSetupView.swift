import AppKit
import SwiftUI

/// Owns the Claude Code setup state shown in Settings. Reading state never
/// changes anything; the file is written only by an explicit Enable or
/// Disconnect action.
final class ClaudeIntegrationState: ObservableObject {
    @Published private(set) var connection: ClaudeConnection = .notConfigured
    @Published private(set) var plan: ClaudePlan?
    @Published private(set) var blocker: String?
    @Published private(set) var failure: String?
    @Published private(set) var message: String?
    @Published private(set) var conflicting = false
    /// The command the status line runs now; nil when it was removed.
    @Published private(set) var conflictingCommand: String?
    @Published private(set) var disconnectPreview: ClaudeDisconnectPreview?
    @Published var reviewing = false
    @Published var confirmingDisconnect = false

    private let make: () -> ClaudeInstaller
    init(installer: @escaping () -> ClaudeInstaller = ClaudeIntegrationState.live) { make = installer }

    static func live() -> ClaudeInstaller {
        ClaudeInstaller(paths: ClaudePaths.resolve(),
                        appPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
    }

    func refresh(snapshot: ClaudeSnapshotInfo) {
        let installer = make()
        connection = installer.connection(snapshot: snapshot)
        disconnectPreview = try? installer.disconnectPlan()
        do {
            plan = try installer.plan()
            blocker = nil
        } catch {
            plan = nil
            blocker = describe(error)
        }
    }

    func enable(snapshot: ClaudeSnapshotInfo) {
        failure = nil
        do {
            let record = try make().install()
            message = record.previousCommand == nil
                ? "Usage tracking is set up. Usage appears once Claude Code answers in a session."
                : "Usage tracking is set up. Your previous status line still runs and is shown as before."
        } catch {
            message = nil
            failure = describe(error)
        }
        reviewing = false
        refresh(snapshot: snapshot)
    }

    func disconnect(_ mode: ClaudeDisconnectMode, snapshot: ClaudeSnapshotInfo) {
        failure = nil
        confirmingDisconnect = false
        do {
            let outcome = try make().disconnect(mode)
            conflicting = false
            conflictingCommand = nil
            if outcome.keptCurrentCommand {
                message = "Nocci stopped managing your status line and left it as it is."
                    + (outcome.remainingWrapperPath.map { " Delete \($0) when you no longer need it." } ?? "")
            } else if let restored = outcome.restoredCommand {
                message = "Restored your previous status line: \(restored)"
            } else {
                message = "Removed the status line Nocci added."
            }
        } catch ClaudeIntegrationError.conflictingStatusLine(let current, _) {
            message = nil
            conflicting = true
            conflictingCommand = current
        } catch {
            message = nil
            failure = describe(error)
        }
        refresh(snapshot: snapshot)
    }

    func dismissConflict() {
        conflicting = false
        conflictingCommand = nil
    }

    private func describe(_ error: Error) -> String {
        (error as? ClaudeIntegrationError)?.errorDescription ?? error.localizedDescription
    }
}

/// The Claude section of the Providers tab.
struct ClaudeSetupSection: View {
    @ObservedObject var state: ClaudeIntegrationState
    @ObservedObject var model: UsageModel

    var body: some View {
        SettingsTile("Claude", glyph: .mark("claude"),
                     footer: "Nocci reads only the usage percentages and reset times Claude Code puts in its status line. Prompts, transcripts, and credentials are never read or stored.",
                     status: {
            Label(state.connection.title, systemImage: symbol)
                .font(.callout).foregroundStyle(tint).lineLimit(1)
        }) {
            Text(state.connection.detail)
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let blocker = state.blocker {
                Text(blocker).font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let failure = state.failure {
                Text(failure).font(.callout).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let message = state.message {
                Text(message).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(state.connection.isConfigured ? "Review Setup…" : "Enable Usage Tracking…") {
                    state.refresh(snapshot: model.claudeSnapshot)
                    state.reviewing = true
                }
                .disabled(state.plan == nil)
                if state.connection.isConfigured {
                    Button("Disconnect…") { state.confirmingDisconnect = true }
                }
            }
        }
        .onAppear { state.refresh(snapshot: model.claudeSnapshot) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            state.refresh(snapshot: model.claudeSnapshot)
        }
        // Published values arrive before the model property is assigned.
        // Use the emitted snapshot, including bridge-only events, directly.
        .onReceive(model.$claude.map {
            ClaudeSnapshotInfo(updated: $0?.updated, hasWindows: !($0?.windows.isEmpty ?? true), lastEvent: $0?.lastEvent)
        }.removeDuplicates()) { snapshot in
            state.refresh(snapshot: snapshot)
        }
        .onReceive(model.$claudeConnection.removeDuplicates()) { _ in
            state.refresh(snapshot: model.claudeSnapshot)
        }
        .sheet(isPresented: $state.reviewing) {
            ClaudeReviewSheet(state: state, model: model)
        }
        .alert("Disconnect Claude Code?", isPresented: $state.confirmingDisconnect) {
            Button("Disconnect", role: .destructive) { disconnect(.restore) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(disconnectMessage)
        }
        .alert("Your status line changed", isPresented: Binding(get: { state.conflicting },
                                                                set: { if !$0 { state.dismissConflict() } })) {
            Button(state.conflictingCommand == nil ? "Keep it removed" : "Keep the current status line") {
                disconnect(.keepCurrentCommand)
            }
            Button(state.disconnectPreview?.restoresCommand == nil ? "Remove the status line" : "Restore the previous one",
                   role: .destructive) { disconnect(.restoreOverridingConflict) }
            Button("Cancel", role: .cancel) { state.dismissConflict() }
        } message: {
            Text((state.conflictingCommand.map { "Your status line now runs \($0), which Nocci didn’t configure." }
                  ?? "Your status line was removed after Nocci set it up.")
                 + " Nothing has been changed. Either choice ends usage tracking and deletes any backup Nocci made of your settings.")
        }
    }

    private func disconnect(_ mode: ClaudeDisconnectMode) {
        state.disconnect(mode, snapshot: model.claudeSnapshot)
        model.refreshClaudeConnection()
    }

    private var symbol: String {
        switch state.connection {
        case .receiving: return "checkmark.circle"
        case .waiting, .connectedWithoutLimits, .stale: return "clock"
        case .conflict, .moved, .unavailable: return "exclamationmark.triangle"
        case .notConfigured: return "circle.dashed"
        }
    }
    private var tint: Color {
        switch state.connection {
        case .receiving: return .green
        case .conflict, .moved, .unavailable, .stale: return .orange
        default: return .secondary
        }
    }
    private var disconnectMessage: String {
        guard let preview = state.disconnectPreview else {
            return "Nocci will remove its status-line configuration."
        }
        if let restored = preview.restoresCommand {
            return "Your previous status line is restored in \(preview.settingsPath):\n\n\(restored)\n\nThe bridge script and any backup Nocci made of your settings are deleted. Other settings are left alone."
        }
        return "The status line Nocci added to \(preview.settingsPath) is removed, and its bridge script and any backup Nocci made of your settings are deleted. Other settings are left alone."
    }
}

/// Shows every change before anything is written.
struct ClaudeReviewSheet: View {
    @ObservedObject var state: ClaudeIntegrationState
    @ObservedObject var model: UsageModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: title,
                        subtitle: subtitle,
                        glyph: .mark("claude"))
                .padding(20)
            Hairline()
            ScrollView {
                VStack(alignment: .leading, spacing: NotchMetrics.sectionGap) {
                    if let plan = state.plan {
                        ReviewItem(label: "Settings file", value: plan.settingsPath,
                                   note: plan.settingsExists ? "Only the statusLine entry below is merged. Every other setting is kept." : "This file will be created.",
                                   code: plan.settingsFragment)
                        if let backup = plan.backupPath {
                            ReviewItem(label: "Backup", value: backup, note: "A copy of your current settings, made before the change. Deleted when you disconnect.")
                        } else if plan.settingsExists {
                            ReviewItem(label: "Backup", value: "Already saved", note: "The backup from your first setup is kept until you disconnect.")
                        }
                        if plan.addsRefreshInterval {
                            ReviewItem(label: "Refresh interval", value: "\(ClaudeInstaller.refreshIntervalSeconds) seconds",
                                       note: "Claude Code re-runs the bridge on a timer as well as on events, so usage stays current between messages. A value you set yourself is never replaced.")
                        }
                        if let preserved = plan.preservedCommand {
                            ReviewItem(label: "Existing status line", value: preserved,
                                       note: "Kept. A bridge script sends usage to Nocci, then runs this command and shows its output.")
                        }
                        ReviewItem(label: "Bridge script", value: plan.wrapperPath,
                                   note: "Created by Nocci and removed when you disconnect.", code: plan.wrapperScript)
                        if !plan.warnings.isEmpty {
                            ReviewNotes(title: "Before you enable", messages: plan.warnings.map(\.message))
                        }
                    } else if let blocker = state.blocker {
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
                Button("Cancel") { state.reviewing = false }
                    .keyboardShortcut(.cancelAction)
                Button(button) {
                    state.enable(snapshot: model.claudeSnapshot)
                    model.refreshClaudeConnection()
                }
                    .keyboardShortcut(.defaultAction)
                    .disabled(state.plan == nil || state.plan?.action == .upToDate)
            }
            .padding(20)
        }
        .frame(width: 560, height: 520)
        .background(Color.black)
    }

    private var title: String {
        switch state.plan?.action {
        case .repair: return "Update Claude Code usage tracking"
        case .upToDate: return "Claude Code usage tracking is already set up"
        default: return "Enable Claude Code usage tracking"
        }
    }
    private var button: String { state.plan?.action == .repair ? "Update Setup" : "Enable Usage Tracking" }
    private var subtitle: String {
        state.plan?.action == .upToDate
            ? "Everything below is already in place, so there is nothing to write."
            : "Nothing is written until you choose \(button). Your existing status line is never run during setup."
    }
}
