import AppKit
import SwiftUI

enum SettingsTab: Hashable, CaseIterable {
    case general, providers, appearance, alerts, pullRequests, sessions, projects

    var title: String {
        switch self {
        case .general: return "General"
        case .providers: return "Providers"
        case .appearance: return "Appearance"
        case .alerts: return "Alerts"
        case .pullRequests: return "Pull Requests"
        case .sessions: return "Sessions"
        case .projects: return "Projects"
        }
    }

    /// SF Symbols that exist on macOS 13, the deployment floor. Sessions uses
    /// the same symbol as its tab in the notch.
    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .providers: return "person.2"
        case .appearance: return "paintbrush"
        case .alerts: return "bell"
        case .pullRequests: return "arrow.triangle.pull"
        case .sessions: return "terminal"
        case .projects: return "folder"
        }
    }
}

/// The window draws its tabs in the title bar row, which an empty unified
/// toolbar makes 52 points tall with the traffic lights centred in it. The
/// page below keeps the 560 by 560 the tabs had before.
enum SettingsMetrics {
    static let width: CGFloat = 560
    static let barHeight: CGFloat = 52
    static let pageHeight: CGFloat = 560
    static var windowHeight: CGFloat { barHeight + pageHeight }
    /// Room for the tab bar with its widest name showing: measured at 280 to
    /// 320 points on 24 September 2026, Pull Requests being the widest.
    static let tabBarWidth: CGFloat = 340
    static let tabBarHeight: CGFloat = 28
}

final class SettingsState: ObservableObject {
    @Published var tab: SettingsTab = .general
    @Published var showingDiagnostics = false
    @Published var showingAlertThresholds = false
    @Published var claudeAlertThresholdText = ""
    @Published var codexAlertThresholdText = ""
    @Published var gitlabHostDraft = ""
    @Published var reviewingSessions = false
    @Published var confirmingSessionsOff = false
    @Published var sessionPlan: ClaudeHooksPlan?
    @Published var sessionBlocker: String?
    @Published var sessionError: String?
    @Published var projectFolderNotice: String?
    @Published private(set) var executablePath = CodexReader.executable()
    func refresh() {
        let path = CodexReader.executable()
        if path != executablePath { executablePath = path }
    }
    func editAlertThresholds(_ preferences: AlertPreferences) {
        claudeAlertThresholdText = AlertThreshold.text(preferences.claudeThresholds)
        codexAlertThresholdText = AlertThreshold.text(preferences.codexThresholds)
        showingAlertThresholds = true
    }
}

struct SettingsView: View {
    @ObservedObject var model: UsageModel
    @ObservedObject var loginItem: LoginItemService
    @ObservedObject var settingsState: SettingsState
    @ObservedObject var claudeState: ClaudeIntegrationState
    @ObservedObject var notifications: NotificationService
    @ObservedObject var updates: UpdateService
    @ObservedObject var pullRequests: PullRequestModel
    @ObservedObject var sessions: ClaudeSessionModel
    @ObservedObject var projects: ProjectModel
    let reviews: CodeReviewModel
    let hotKeys: HotKeyService
    let shortcutRecorder: ShortcutRecorder

    var body: some View {
        VStack(spacing: 0) {
            // The tab bar is laid over this row by `SettingsWindowContent`.
            Color.clear.frame(height: SettingsMetrics.barHeight)
            ZStack {
                page
                    .id(settingsState.tab)
                    .transition(.opacity.animation(.easeInOut(duration: 0.15)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // A scroll view would otherwise draw on up under the tab bar and
            // the traffic lights once it scrolls.
            .clipped()
        }
        .frame(width: SettingsMetrics.width, height: SettingsMetrics.windowHeight)
        .background(Color.black)
        .ignoresSafeArea()
        .onAppear { reconcile() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in reconcile() }
        // Only Settings' own window: the notch panel and the terminal become
        // key often, and each check here runs on the thread driving hover.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            if (note.object as? NSWindow)?.contentView is SettingsWindowContent { reconcile() }
        }
        .onReceive(model.$refreshing) { _ in settingsState.refresh() }
    }

    @ViewBuilder private var page: some View {
        switch settingsState.tab {
        case .general: general
        case .providers: providers
        case .appearance: appearance
        case .alerts: alerts
        case .pullRequests: PullRequestSettingsForm(model: pullRequests, reviews: reviews, settingsState: settingsState,
                                                    notifications: notifications)
        case .sessions: ClaudeSessionSettingsForm(model: sessions, notifications: notifications, settingsState: settingsState)
        case .projects: ProjectSettingsForm(model: projects, settingsState: settingsState)
        }
    }

    private var general: some View {
        SettingsPage {
            SettingsTile("Startup", glyph: .symbol("power"),
                         footer: "Keep Nocci in a stable location, such as Applications, before enabling launch at login.") {
                SettingsToggle("Launch at login", isOn: Binding(get: { loginItem.isRegistered },
                                                               set: { loginItem.setEnabled($0) }))
                Text(loginItem.statusMessage)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if loginItem.status == .requiresApproval {
                    Label("Approval needed", systemImage: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                }
                if let message = loginItem.errorMessage {
                    Text(message).font(.callout).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("Open Login Items Settings…") { loginItem.openSystemSettings() }
            }
            ShortcutSettingsTile(hotKeys: hotKeys, recorder: shortcutRecorder)
            SettingsTile("Updates", glyph: .symbol("arrow.down.circle"), footer: updates.configured
                         ? "Stable is recommended. Preview also receives prerelease builds. Update checks never include account or usage data."
                         : "This build has no update feed embedded, so it cannot check for new versions. Released builds ask once whether to check automatically, and never install an update without asking.") {
                if updates.configured {
                    SettingsToggle("Automatically check for updates", isOn: Binding(
                        get: { updates.automaticallyChecks },
                        set: { updates.setAutomaticallyChecks($0) }))
                    Hairline()
                    SettingsRow("Channel") {
                        Picker("Channel", selection: Binding(
                            get: { updates.channel },
                            set: { updates.setChannel($0) })) {
                            ForEach(UpdateChannel.allCases, id: \.self) { channel in
                                Text(channel.title).tag(channel)
                            }
                        }
                    }
                }
                Button(updates.actionTitle) { updates.performPrimaryAction() }
                Text(updates.statusMessage)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            SettingsTile("Nocci", glyph: .symbol("info.circle"), status: {
                Text(updates.versionDescription).font(.callout).foregroundStyle(.secondary)
            }) {
                Button("Open Setup Guide") { model.onOpenGuide?() }
            }
        }
    }

    private var providers: some View {
        SettingsPage {
            ClaudeSetupSection(state: claudeState, model: model)
            SettingsTile("Codex", glyph: .mark("openai"),
                         footer: "Sign in to this executable with your ChatGPT subscription. Usage refreshes about once a minute.") {
                SettingsValue("Executable", settingsState.executablePath ?? "Not found",
                              help: settingsState.executablePath ?? "Choose your installed codex executable.")
                if ProcessInfo.processInfo.environment["NOCCI_CODEX_PATH"] != nil {
                    Text("An environment override controls this executable for the current launch.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Choose Codex Executable…") {
                        model.onChooseCodex?()
                        settingsState.refresh()
                    }
                    Button("Connection Details…") { settingsState.showingDiagnostics = true }
                }
            }
        }
        .sheet(isPresented: $settingsState.showingDiagnostics) {
            DiagnosticsSheet(rows: diagnosticRows()) { settingsState.showingDiagnostics = false }
        }
    }

    /// Assembled here so the sheet itself only ever sees finished strings.
    private func diagnosticRows() -> [DiagnosticRow] {
        let paths = ClaudePaths.resolve()
        let codexPath = settingsState.executablePath
        return Diagnostics.rows(DiagnosticInput(
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            home: FileManager.default.homeDirectoryForCurrentUser.path,
            codexPath: codexPath,
            codexExecutable: codexPath.map { FileManager.default.isRunnableFile(atPath: $0) } ?? false,
            claudeConfigured: model.claudeConnection.isConfigured,
            bridgePath: paths.wrapperFile.path,
            bridgePresent: FileManager.default.fileExists(atPath: paths.wrapperFile.path),
            claudeStatus: model.claudeConnection.shortStatus,
            lastClaudeEvent: model.claude?.lastEvent,
            lastClaudeRead: model.claude?.updated,
            lastCodexRead: model.codex?.updated,
            codexMessage: model.codexMessage,
            now: model.tick))
    }

    private var appearance: some View {
        SettingsPage {
            SettingsTile("Providers", glyph: .symbol("eye"),
                         footer: "At least one provider stays visible. To hide the notch entirely, turn off Show Notch in Nocci’s menu bar menu.") {
                // The last visible provider cannot be switched off, so the
                // constraint is apparent before the click rather than after it.
                SettingsToggle("Claude", mark: "claude", isOn: $model.preferences.showClaude)
                    .disabled(model.preferences.showClaude && !model.preferences.showCodex)
                Hairline()
                SettingsToggle("Codex", mark: "openai", isOn: $model.preferences.showCodex)
                    .disabled(model.preferences.showCodex && !model.preferences.showClaude)
            }
            SettingsTile("Percentages", glyph: .symbol("percent"),
                         footer: "Usage is always measured as the share consumed. This changes only how it is displayed.") {
                SettingsRow("Show") {
                    Picker("Show", selection: $model.preferences.percentages) {
                        Text("Used").tag(PercentageMode.used)
                        Text("Remaining").tag(PercentageMode.remaining)
                    }
                }
            }
            SettingsTile("Compact notch", glyph: .symbol("rectangle.topthird.inset.filled"),
                         footer: "Each provider has its own window. Automatic shows the session window and falls back to weekly. A window the provider did not report shows a dash rather than another quota. This applies when both providers are shown; with one provider the notch shows both of its windows.") {
                compactWindowPicker("Claude", mark: "claude", selection: $model.preferences.claudeWindow)
                Hairline()
                compactWindowPicker("Codex", mark: "openai", selection: $model.preferences.codexWindow)
            }
            SettingsTile("Notch", glyph: .symbol("laptopcomputer"),
                         footer: "A click on the notch always opens it at once. The short pause keeps the panel closed when the pointer only passes over the notch on its way to the menu bar. Hide in full screen slides the notch away while a full-screen app owns its display.") {
                SettingsRow("Open on hover") {
                    Picker("Open on hover", selection: $model.preferences.hoverOpen) {
                        Text("Instantly").tag(HoverOpen.instant)
                        Text("After a short pause").tag(HoverOpen.pause)
                        Text("Click only").tag(HoverOpen.clickOnly)
                    }
                }
                Hairline()
                SettingsToggle("Hide in full screen", isOn: $model.preferences.hideInFullScreen)
            }
            SettingsTile("Pace", glyph: .symbol("speedometer"),
                         footer: "Adds a quiet line to each card estimating whether usage is on track to exhaust an allowance before it resets. It is an estimate from recent percentage changes, not a prediction, and it needs about thirty minutes of observations after launch before it can say anything.") {
                SettingsToggle("Estimate whether an allowance will last", isOn: $model.preferences.showPace)
            }
        }
    }

    private func compactWindowPicker(_ title: String, mark: String, selection: Binding<CompactWindowChoice>) -> some View {
        SettingsRow(title, mark: mark) {
            Picker(title, selection: selection) {
                Text("Session").tag(CompactWindowChoice.session)
                Text("Weekly").tag(CompactWindowChoice.weekly)
                Text("Automatic").tag(CompactWindowChoice.automatic)
            }
        }
    }

    private var alerts: some View {
        SettingsPage {
            SettingsTile("Alerts", glyph: .symbol("bell"),
                         footer: "Claude: \(AlertThreshold.text(model.alertPreferences.claudeThresholds))%. Codex: \(AlertThreshold.text(model.alertPreferences.codexThresholds))%. Each allowance notifies once per level. Turning a provider off forgets what it already notified.") {
                SettingsToggle("Claude", mark: "claude", isOn: Binding(get: { model.alertPreferences.claude },
                                                                       set: { enable(\.claude, $0) }))
                Hairline()
                SettingsToggle("Codex", mark: "openai", isOn: Binding(get: { model.alertPreferences.codex },
                                                                      set: { enable(\.codex, $0) }))
                Hairline()
                SettingsToggle("Also tell me when an allowance resets", isOn: Binding(
                    get: { model.alertPreferences.resets },
                    set: { model.alertPreferences.resets = $0 }))
                Hairline()
                SettingsToggle("Play a sound", isOn: Binding(get: { model.alertPreferences.sound },
                                                             set: { model.alertPreferences.sound = $0 }))
                Button("Customize Thresholds…") {
                    settingsState.editAlertThresholds(model.alertPreferences)
                }
            }
            SettingsTile("Permission", glyph: .symbol("bell.badge"),
                         footer: "The test contains no usage or account data. It follows the sound setting, opens the notch when clicked, and does not change alert thresholds. Alerts always describe the share used, whatever the Appearance tab shows.") {
                Text(notifications.statusMessage)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    model.sendTestNotification()
                } label: {
                    Label("Send Test Notification", systemImage: "bell.badge")
                }
                .disabled(!notifications.canDeliver || model.presentation.isActive(at: model.tick))
                if model.presentation.isActive(at: model.tick) {
                    Text("Test notifications are paused during Presentation Mode.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if notifications.status == .denied {
                    Label("Permission needed", systemImage: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                    Button("Open Notification Settings…") { notifications.openSystemSettings() }
                }
                if let message = notifications.errorMessage {
                    Text(message).font(.callout).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .sheet(isPresented: $settingsState.showingAlertThresholds) {
            AlertThresholdSheet(model: model, state: settingsState)
        }
    }

    /// Permission is requested only when switching an alert on, never at launch.
    private func enable(_ key: WritableKeyPath<AlertPreferences, Bool>, _ value: Bool) {
        model.alertPreferences[keyPath: key] = value
        if value { notifications.requestAuthorization() }
    }

    private func reconcile() {
        loginItem.refresh()
        notifications.refresh()
        settingsState.refresh()
        pullRequests.reloadExecutables()
    }
}

/// The sections as icons in the title bar row. Unlike the notch's tabs, the
/// selected capsule widens to carry its name, since Settings has no other
/// title; the tab that grows is the one just clicked, so it stays under the
/// pointer while the others shift.
struct SettingsTabBar: View {
    @ObservedObject var state: SettingsState
    @Namespace private var namespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(SettingsTab.allCases, id: \.self) { tab in
                let selected = state.tab == tab
                Button {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85)) {
                        state.tab = tab
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 12, weight: .semibold))
                        if selected {
                            Text(tab.title).font(.callout.weight(.semibold)).fixedSize()
                        }
                    }
                    .foregroundStyle(selected ? Color.white : Color.secondary)
                    .padding(.horizontal, selected ? 10 : 0)
                    .frame(minWidth: 32, minHeight: 24)
                    .background {
                        if selected {
                            Capsule().fill(Color.white.opacity(0.12))
                                .matchedGeometryEffect(id: "selection", in: namespace)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(tab.title)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Settings sections")
    }
}

/// The window's content: the page, with the tab bar laid over the title bar
/// row inside a control. A mouse-down in that row moves the window unless it
/// lands on a control AppKit can see, and AppKit never looks inside a SwiftUI
/// hosting view, so tabs drawn in the page itself could not be clicked. The
/// rest of the row still moves the window.
final class SettingsWindowContent: NSView {
    init<Page: View, Tabs: View>(page: Page, tabs: Tabs) {
        super.init(frame: NSRect(x: 0, y: 0, width: SettingsMetrics.width, height: SettingsMetrics.windowHeight))
        // The page's fitting size counts the title bar's safe area on top of
        // a page that already runs under it, so it must not size the window.
        let pageHost = NSHostingView(rootView: page)
        pageHost.sizingOptions = []
        pageHost.frame = bounds
        pageHost.autoresizingMask = [.width, .height]
        addSubview(pageHost)

        let control = TitlebarControl(frame: NSRect(
            x: (bounds.width - SettingsMetrics.tabBarWidth) / 2,
            y: bounds.height - (SettingsMetrics.barHeight + SettingsMetrics.tabBarHeight) / 2,
            width: SettingsMetrics.tabBarWidth, height: SettingsMetrics.tabBarHeight))
        control.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin]
        let tabsHost = TitlebarHost(rootView: tabs)
        tabsHost.sizingOptions = []
        tabsHost.frame = control.bounds
        tabsHost.autoresizingMask = [.width, .height]
        control.addSubview(tabsHost)
        addSubview(control)
    }

    required init?(coder: NSCoder) { nil }
}

/// A control only so AppKit leaves its frame out of the title bar's drag area.
final class TitlebarControl: NSControl {}

/// Sits wholly inside the title bar, whose safe area would otherwise push
/// its content down out of its own frame and out from under the pointer.
final class TitlebarHost<Content: View>: NSHostingView<Content> {
    override var safeAreaInsets: NSEdgeInsets { NSEdgeInsetsZero }
}

/// One tab's tiles, scrolling under the fixed tab bar when they run long.
struct SettingsPage<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView(.vertical) {
            VStack(spacing: NotchMetrics.sectionGap) { content }
                .padding(.top, 6)
                .padding([.horizontal, .bottom], NotchMetrics.panelPadding)
        }
    }
}

enum SettingsGlyph {
    case symbol(String)
    /// A bundled provider or forge mark, drawn in its own colours.
    case mark(String)
}

/// The notch's 22-point circular well, holding a symbol or a mark.
struct SettingsGlyphWell: View {
    let glyph: SettingsGlyph

    var body: some View {
        Group {
            switch glyph {
            case .symbol(let name):
                Image(systemName: name).font(.system(size: 11, weight: .semibold))
            case .mark(let asset):
                // The provider card's sizes: each mark keeps its own
                // proportions, and OpenAI its supplied clear space.
                BrandLogo(asset: asset, size: ["openai": 19, "claude": 13, "github": 13, "gitlab": 14][asset] ?? 13)
            }
        }
        .glyphWell(active: false)
        .accessibilityHidden(true)
    }
}

/// A section as a notch tile: its glyph and title, its rows, then the
/// section's explanation inside the tile rather than loose beneath it.
struct SettingsTile<Status: View, Content: View>: View {
    let title: String
    let glyph: SettingsGlyph
    var footer: String?
    let status: Status
    let content: Content

    init(_ title: String, glyph: SettingsGlyph, footer: String? = nil,
         @ViewBuilder status: () -> Status, @ViewBuilder content: () -> Content) {
        self.title = title
        self.glyph = glyph
        self.footer = footer
        self.status = status()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                SettingsGlyphWell(glyph: glyph)
                Text(title).font(.body.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                status
            }
            VStack(alignment: .leading, spacing: 8) { content }
            if let footer {
                Text(footer).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(NotchMetrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .notchTile()
        .accessibilityElement(children: .contain)
    }
}

extension SettingsTile where Status == EmptyView {
    init(_ title: String, glyph: SettingsGlyph, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title, glyph: glyph, footer: footer, status: { EmptyView() }, content: content)
    }
}

/// A native switch with its label on the leading side of the tile.
struct SettingsToggle: View {
    let title: String
    var mark: String?
    @Binding var isOn: Bool

    init(_ title: String, mark: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.mark = mark
        _isOn = isOn
    }

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 8) {
                if let mark { SettingsGlyphWell(glyph: .mark(mark)) }
                Text(title)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
    }
}

/// A label with a native control on the trailing side. The control carries
/// the same label, hidden, so VoiceOver reads it once, on the control.
struct SettingsRow<Control: View>: View {
    let title: String
    var mark: String?
    let control: Control

    init(_ title: String, mark: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.mark = mark
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 8) {
            if let mark { SettingsGlyphWell(glyph: .mark(mark)) }
            Text(title).accessibilityHidden(true)
            Spacer(minLength: 12)
            control.labelsHidden().fixedSize()
        }
    }
}

/// A read-only value beside its label, read by VoiceOver as one element.
struct SettingsValue: View {
    let title: String
    let value: String
    var tint: Color = .secondary
    /// Paths keep both ends visible and can be copied; prose wraps instead.
    var path = true
    var help: String?

    init(_ title: String, _ value: String, tint: Color = .secondary, path: Bool = true, help: String? = nil) {
        self.title = title
        self.value = value
        self.tint = tint
        self.path = path
        self.help = help
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
            Spacer(minLength: 0)
            if path {
                Text(value).foregroundStyle(tint)
                    .lineLimit(2).truncationMode(.middle)
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
                    .help(help ?? value)
            } else {
                Text(value).foregroundStyle(tint)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The notch's separator weight, between rows and above a sheet's buttons.
struct Hairline: View {
    var body: some View {
        Rectangle().fill(Color.white.opacity(0.08)).frame(height: 0.5)
            .accessibilityHidden(true)
    }
}

/// A sheet's heading: a glyph in the well, the title, and what it is for.
struct SheetHeader: View {
    let title: String
    let subtitle: String
    let glyph: SettingsGlyph

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            SettingsGlyphWell(glyph: glyph)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 15, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// One planned change in a review sheet: what, where and why, with the exact
/// text that will be written when there is one.
struct ReviewItem: View {
    let label: String
    let value: String
    let note: String
    var code: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(label).font(.system(size: 12, weight: .semibold))
                Text(value).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text(note).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let code {
                Text(code)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .padding(NotchMetrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .notchTile()
    }
}

/// The points a review sheet raises before anything is written.
struct ReviewNotes: View {
    let title: String
    let messages: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 12, weight: .semibold))
            ForEach(Array(messages.enumerated()), id: \.offset) { _, message in
                Label(message, systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(NotchMetrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .notchTile()
    }
}

struct AlertThresholdSheet: View {
    @ObservedObject var model: UsageModel
    @ObservedObject var state: SettingsState

    private var parsed: (claude: [Int], codex: [Int])? {
        guard let claude = AlertThreshold.parse(state.claudeAlertThresholdText),
              let codex = AlertThreshold.parse(state.codexAlertThresholdText) else { return nil }
        return (claude, codex)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetHeader(title: "Alert Thresholds",
                        subtitle: "Choose the used-allowance percentages that trigger an alert for each provider.",
                        glyph: .symbol("bell"))

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    HStack(spacing: 8) {
                        SettingsGlyphWell(glyph: .mark("claude"))
                        Text("Claude")
                    }
                    TextField("80, 90, 100", text: $state.claudeAlertThresholdText)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Claude alert thresholds")
                }
                GridRow {
                    HStack(spacing: 8) {
                        SettingsGlyphWell(glyph: .mark("openai"))
                        Text("Codex")
                    }
                    TextField("80, 90, 100", text: $state.codexAlertThresholdText)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Codex alert thresholds")
                }
            }
            .padding(NotchMetrics.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .notchTile()

            if parsed == nil {
                Label("Enter one or more whole numbers from 1 to 100, separated by commas.",
                      systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(.red)
            } else {
                Text("Duplicates are removed and values are saved in ascending order. Saving establishes a new baseline, so existing usage will not trigger an immediate alert.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Hairline()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { state.showingAlertThresholds = false }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(parsed == nil)
            }
        }
        .padding(20)
        .frame(width: 460)
        .background(Color.black)
    }

    private func save() {
        guard let parsed else { return }
        var preferences = model.alertPreferences
        preferences.setThresholds(parsed.claude, for: .claude)
        preferences.setThresholds(parsed.codex, for: .codex)
        model.alertPreferences = preferences
        state.showingAlertThresholds = false
    }
}

/// Shows only the finished strings `Diagnostics` produced. No provider
/// payloads, no auth data, no transcript paths are reachable from here.
struct DiagnosticsSheet: View {
    let rows: [DiagnosticRow]
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: "Connection Details",
                        subtitle: "Useful when something is not updating. Nothing here identifies your account, and no provider content is included.",
                        glyph: .symbol("stethoscope"))
                .padding(20)

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(rows.dropLast().enumerated()), id: \.element.label) { index, row in
                            if index > 0 { Hairline() }
                            SettingsValue(row.label, row.value)
                        }
                    }
                    .padding(NotchMetrics.cardPadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .notchTile()
                    if let note = rows.last {
                        Text("\(note.label): \(note.value)")
                            .font(.subheadline).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }

            Hairline()
            HStack {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Diagnostics.text(rows), forType: .string)
                }
                Spacer()
                Button("Done", action: dismiss).keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        // Sheets attach below the toolbar, 66 points down on macOS 27, so
        // this fits the 612-point window; the rows scroll.
        .frame(width: 480, height: 540)
        .background(Color.black)
    }
}
