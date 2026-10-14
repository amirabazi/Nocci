import AppKit
import SwiftUI

/// The shell hangs from the physical top edge of the display. It meets that
/// edge at full width, flares inward through a concave corner just below it,
/// and rounds off at the bottom, so it reads as an extension of the camera
/// housing rather than a rectangle floating under it.
struct NotchShape: Shape {
    var topRadius: CGFloat = NotchMetrics.flareInset
    var bottomRadius: CGFloat = 20

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let top = max(0, min(topRadius, rect.width / 4, rect.height / 2))
        let bottom = max(0, min(bottomRadius, rect.height - top, rect.width / 2 - top))
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + top, y: rect.minY + top),
                       control: CGPoint(x: rect.minX + top, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + top, y: rect.maxY - bottom))
        p.addQuadCurve(to: CGPoint(x: rect.minX + top + bottom, y: rect.maxY),
                       control: CGPoint(x: rect.minX + top, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - top - bottom, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - top, y: rect.maxY - bottom),
                       control: CGPoint(x: rect.maxX - top, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - top, y: rect.minY + top))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                       control: CGPoint(x: rect.maxX - top, y: rect.minY))
        p.closeSubpath(); return p
    }
}

struct NotchView: View {
    @ObservedObject var model: UsageModel
    @ObservedObject var pullRequests: PullRequestModel
    @ObservedObject var sessions: ClaudeSessionModel
    @ObservedObject var projects: ProjectModel
    let reviews: CodeReviewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Group {
            if model.floating { floatingBody } else { notchBody }
        }
        .offset(y: model.fullScreenHidden ? hiddenOffset : 0)
        .animation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 1.0), value: model.fullScreenHidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
        .environment(\.controlActiveState, .active)
    }

    /// The window never resizes. This one shape grows from the collapsed strip
    /// into the panel and back, anchored at the camera housing.
    private var notchBody: some View {
        let open = model.expanded
        let shape = NotchShape(topRadius: open ? NotchMetrics.openFlare : NotchMetrics.flareInset,
                               bottomRadius: open ? NotchMetrics.openBottomRadius : 20)
        return VStack(spacing: 0) {
            notchRow
            details
                .frame(width: NotchMetrics.expandedWidth,
                       height: detailsHeight, alignment: .top)
                .blur(radius: open || reduceMotion ? 0 : 10)
                .scaleEffect(open || reduceMotion ? 1 : 0.8, anchor: .top)
                .opacity(open ? 1 : 0)
                .animation(contentAnimation(open), value: open)
                .allowsHitTesting(open)
                .accessibilityHidden(!open)
        }
        .frame(width: open ? NotchMetrics.expandedWidth : compactWidth + (model.bouncing ? NotchMetrics.bounceWidth : 0),
               height: model.notchHeight + (open ? detailsHeight : peekExtra),
               alignment: .top)
        .compositingGroup()
        // One black surface with the camera housing. Already opaque, so
        // Reduce Transparency needs no branch.
        .background(Color.black)
        .clipShape(shape)
        .overlay(shape.strokeBorderColor(contrast == .increased ? 0.4 : 0))
        .contentShape(shape)
        .shadow(color: .black.opacity(shapeShadow.opacity), radius: shapeShadow.radius)
        .animation(shapeAnimation(open), value: open)
        .animation(shapeAnimation(true), value: shownTab)
        .animation(shapeAnimation(true), value: projects.showingTerminal)
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.42, dampingFraction: 0.8),
                   value: model.peeking)
        .animation(.spring(response: 0.3, dampingFraction: 0.5), value: model.bouncing)
        .onTapGesture { openFromClick() }
        .contextMenu { notchMenu }
        .accessibilityElement(children: .contain)
    }

    /// Screens without a notch: a pill hangs from the top centre and the
    /// panel floats below it as a rounded card, sliding out from under it.
    private var floatingBody: some View {
        let open = model.expanded
        let wing = NotchMetrics.compactWing(caption: !(model.preferences.showClaude && model.preferences.showCodex))
        let cardHeight = NotchMetrics.floatingHeaderHeight + detailsHeight
        return ZStack(alignment: .top) {
            VStack(spacing: 0) {
                header(gap: 0, height: NotchMetrics.floatingHeaderHeight)
                details
                    .frame(width: NotchMetrics.expandedWidth, height: detailsHeight, alignment: .top)
            }
            .frame(width: NotchMetrics.expandedWidth, height: cardHeight, alignment: .top)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: NotchMetrics.floatingRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: NotchMetrics.floatingRadius, style: .continuous)
                .strokeBorder(.white.opacity(contrast == .increased ? 0.4 : 0), lineWidth: 0.5))
            .shadow(color: .black.opacity(open ? 0.6 : 0), radius: 12)
            .offset(y: open ? 0 : -(cardHeight + model.notchHeight + NotchMetrics.floatingGap))
            .opacity(open ? 1 : 0)
            .padding(.top, model.notchHeight + NotchMetrics.floatingGap)
            .animation(shapeAnimation(open), value: open)
            .animation(shapeAnimation(true), value: shownTab)
            .animation(shapeAnimation(true), value: projects.showingTerminal)
            .allowsHitTesting(open)
            .accessibilityHidden(!open)

            HStack(spacing: NotchMetrics.pillSpacing) {
                compactLeft
                compactRight
            }
            .padding(.horizontal, NotchMetrics.pillPadding)
            .frame(width: NotchMetrics.pillWidth(wing: wing) + (model.bouncing ? NotchMetrics.bounceWidth : 0),
                   height: model.notchHeight + peekExtra)
            .background(Color.black)
            .clipShape(NotchShape(topRadius: 0, bottomRadius: model.notchHeight / 2))
            .overlay(NotchShape(topRadius: 0, bottomRadius: model.notchHeight / 2)
                .strokeBorderColor(contrast == .increased ? 0.4 : 0))
            .contentShape(NotchShape(topRadius: 0, bottomRadius: model.notchHeight / 2))
            .shadow(color: .black.opacity(model.peeking ? 0.5 : 0), radius: 10)
            .animation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.42, dampingFraction: 0.8),
                       value: model.peeking)
            .animation(.spring(response: 0.3, dampingFraction: 0.5), value: model.bouncing)
            .onTapGesture { openFromClick() }
            .contextMenu { notchMenu }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var notchMenu: some View {
        Button("Settings…") { model.onSettings?() }
        ProviderQuickActions()
        Button("Usage History…") { model.onHistory?() }
        Button(TerminalRules.summonTitle(dropped: model.terminalDropped)) { model.onSummonTerminal?() }
        Divider()
        if !model.sampleOnly {
            Menu("Presentation Mode") {
                Button("For 1 hour") { model.presentation = PresentationState(minutes: 60, from: Date()) }
                Button("For 30 minutes") { model.presentation = PresentationState(minutes: 30, from: Date()) }
                Button("Until I end it") { model.presentation = .untilEnded }
            }
        }
        Toggle("Keep Open", isOn: $model.pinned)
        Button("Preview Appearance…") { model.onPreview?() }
        Button("Refresh Usage") { model.refresh() }
        Divider()
        Button("Quit Nocci") { model.onQuit?() }
    }

    /// A click opens at once in every hover mode, through the same path as a
    /// hover open so it plays the tick.
    private func openFromClick() {
        guard !model.expanded else { return }
        if let open = model.onUserOpen { open() } else { model.expand(true) }
    }

    /// Far enough up that any state, open or collapsed, leaves the canvas.
    private var hiddenOffset: CGFloat {
        let tallest = max(NotchMetrics.detailsHeight(list: true, pace: true), NotchMetrics.detailsHeight(slot: model.terminalSlot))
        return -(model.notchHeight + tallest + NotchMetrics.shadowMargin + 60)
    }

    /// Reduce Motion keeps the strip's size and shows the peek by its shadow only.
    private var peekExtra: CGFloat { model.peeking && !reduceMotion ? NotchMetrics.peekHeight : 0 }

    private var shapeShadow: (opacity: Double, radius: CGFloat) {
        if model.expanded { return (0.6, 12) }
        return model.peeking ? (0.5, 10) : (0, 0)
    }

    /// The shown tab's slot, or the terminal's while the Projects tile shows
    /// a notch terminal.
    private var slotHeight: CGFloat {
        if showingProjects && projects.showingTerminal { return max(model.terminalSlot, NotchMetrics.listHeight) }
        return NotchMetrics.slotHeight(list: shownTab != .usage, pace: model.preferences.showPace)
    }

    private var detailsHeight: CGFloat { NotchMetrics.detailsHeight(slot: slotHeight) }

    private var compactWidth: CGFloat {
        NotchMetrics.compactWidth(notchWidth: model.notchWidth,
                                  caption: !(model.preferences.showClaude && model.preferences.showCodex))
    }

    /// Opens with a slight overshoot, closes without one. Reduce Motion
    /// changes the size at once.
    private func shapeAnimation(_ open: Bool) -> Animation? {
        guard !reduceMotion else { return nil }
        return open ? .spring(response: 0.42, dampingFraction: 0.8) : .spring(response: 0.45, dampingFraction: 1.0)
    }

    /// The panel's contents arrive with the shape and leave quickly ahead of it.
    private func contentAnimation(_ open: Bool) -> Animation {
        if reduceMotion { return .easeInOut(duration: 0.15) }
        return open ? .easeOut(duration: 0.3).delay(0.05) : .easeOut(duration: 0.15)
    }

    private var compactRow: some View {
        HStack(spacing: 0) {
            compactLeft.padding(.trailing, NotchMetrics.compactInnerGap)
            Color.clear.frame(width: model.notchWidth, height: model.notchHeight)
            compactRight.padding(.leading, NotchMetrics.compactInnerGap)
        }
        .frame(maxWidth: .infinity)
        .frame(height: model.notchHeight)
    }

    private var availableTabs: [PanelTab] {
        PanelTab.available(pullRequests: pullRequests.settings.enabled, sessions: sessions.enabled,
                           projects: projects.settings.enabled)
    }

    /// The stored tab, or Usage when the stored tab's feature is off. The tab
    /// is stored on `PullRequestModel` because that feature introduced it.
    private var shownTab: PanelTab { PanelTab.shown(stored: pullRequests.tab, available: availableTabs) }
    private var showingPullRequests: Bool { shownTab == .pullRequests }
    private var showingSessions: Bool { shownTab == .sessions }
    private var showingProjects: Bool { shownTab == .projects }

    /// The collapsed marks and the open header share the notch row and
    /// crossfade as the shape changes.
    private var notchRow: some View {
        let open = model.expanded
        return ZStack {
            compactRow
                .opacity(open ? 0 : 1)
                .accessibilityHidden(open)
            header(gap: model.notchWidth, height: model.notchHeight)
                .opacity(open ? 1 : 0)
                .allowsHitTesting(open)
                .accessibilityHidden(!open)
        }
        .animation(.easeInOut(duration: reduceMotion ? 0.15 : 0.2), value: open)
        .frame(maxWidth: .infinity)
        .frame(height: model.notchHeight)
    }

    /// When open, the notch row carries the tabs left of the camera and the
    /// panel's two buttons right of it.
    private func header(gap: CGFloat, height: CGFloat) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 0) {
                if availableTabs.count > 1 {
                    PanelTabs(tabs: availableTabs,
                              selection: Binding(get: { shownTab }, set: { pullRequests.tab = $0 }),
                              badged: sessions.enabled && sessions.needsYou ? .sessions : nil)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, NotchMetrics.panelPadding)
            .frame(maxWidth: .infinity)
            Color.clear.frame(width: gap)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                if model.terminalOpen { terminalButton }
                pinButton
                moreMenu
            }
            .padding(.trailing, NotchMetrics.panelPadding)
            .frame(maxWidth: .infinity)
        }
        .frame(width: NotchMetrics.expandedWidth, height: height)
    }

    /// `macwindow`, since `terminal` is already the Sessions tab's glyph.
    private var terminalButton: some View {
        Button {
            model.onSummonTerminal?()
        } label: {
            Image(systemName: "macwindow")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(model.terminalDropped ? Color.accentColor : Color.secondary)
                .glyphWell(active: model.terminalDropped)
        }
        .buttonStyle(.plain)
        .help(TerminalRules.summonTitle(dropped: model.terminalDropped))
        .accessibilityLabel(TerminalRules.summonTitle(dropped: model.terminalDropped))
    }

    private var pinButton: some View {
        Button {
            model.pinned.toggle()
        } label: {
            Image(systemName: model.pinned ? "pin.fill" : "pin")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(model.pinned ? Color.accentColor : Color.secondary)
                .glyphWell(active: model.pinned)
        }
        .buttonStyle(.plain)
        .help(model.pinned ? "Unpin popup" : "Keep popup open")
        .accessibilityLabel(model.pinned ? "Unpin popup" : "Keep popup open")
        .accessibilityValue(model.pinned ? "On" : "Off")
    }

    private var moreMenu: some View {
        Menu {
            Button("Settings…") { model.onSettings?() }
            ProviderQuickActions()
            Button("Usage History…") { model.onHistory?() }
            Divider()
            Button(model.claudeConnection.isConfigured ? "Claude Code Setup…" : "Connect Claude Code…") { model.onConnectClaude?() }
            Button("Choose Codex Executable…") { model.onChooseCodex?() }
            Divider()
            if !model.sampleOnly {
                Menu("Presentation Mode") {
                    Button("For 1 hour") { model.presentation = PresentationState(minutes: 60, from: Date()) }
                    Button("For 30 minutes") { model.presentation = PresentationState(minutes: 30, from: Date()) }
                    Button("Until I end it") { model.presentation = .untilEnded }
                }
            }
            Toggle("Keep Open", isOn: $model.pinned)
            if !model.sampleOnly {
                Toggle("Show Sample Data", isOn: Binding(get: { model.demo }, set: { _ in model.toggleDemo() }))
            }
            Button("Preview Appearance…") { model.onPreview?() }
            Divider()
            Button("Setup Guide") { model.onOpenGuide?() }
            Button("Quit Nocci") { model.onQuit?() }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .glyphWell(active: false)
        .help("More options")
        .accessibilityLabel("More options")
    }

    private var details: some View {
        VStack(spacing: NotchMetrics.sectionGap) {
            HStack(spacing: NotchMetrics.cardGap) {
                if showingPullRequests {
                    PullRequestListView(model: pullRequests, reviews: reviews, now: model.tick)
                }
                if showingSessions {
                    ClaudeSessionListView(model: sessions, now: model.tick)
                }
                if showingProjects {
                    ProjectListView(model: projects, now: model.tick, open: model.expanded)
                }
                if !showingPullRequests && !showingSessions && !showingProjects && model.preferences.showClaude {
                    ProviderCard(name: "Claude", icon: "claude",
                                 snapshot: model.claude, message: "", now: model.tick,
                                 isDemo: model.demo, refreshing: false,
                                 mode: model.preferences.percentages,
                                 pace: model.claudePace,
                                 marker: model.preferences.showPace,
                                 connectTitle: model.claudeConnection.isConfigured ? "Claude Code Setup…" : "Enable Usage Tracking…",
                                 emptyOverride: model.demo ? nil : model.claudeConnection.summary,
                                 statusOverride: model.demo ? nil : model.claudeConnection.shortStatus,
                                 connect: { model.onConnectClaude?() })
                }
                if !showingPullRequests && !showingSessions && !showingProjects && model.preferences.showCodex {
                    ProviderCard(name: "Codex", icon: "openai",
                                 snapshot: model.codex, message: model.codexMessage, now: model.tick,
                                 isDemo: model.demo, refreshing: model.refreshing,
                                 mode: model.preferences.percentages,
                                 pace: model.codexPace,
                                 marker: model.preferences.showPace,
                                 connectTitle: "Set Up Codex…",
                                 connect: { model.onChooseCodex?() })
                }
            }
            .frame(height: slotHeight)

            if showingPullRequests {
                PullRequestFooter(model: pullRequests, now: model.tick)
            } else if showingSessions {
                ClaudeSessionFooter(model: sessions)
            } else if showingProjects {
                ProjectFooter(model: projects)
            } else {
                HStack(spacing: 6) {
                    Text(model.preferences.caption).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if model.refreshing {
                        ProgressView().controlSize(.mini).scaleEffect(0.75).frame(width: 12, height: 12)
                        Text("Updating…").font(.caption).foregroundStyle(.secondary)
                    }
                    Button { model.refresh() } label: {
                        Label("Refresh", systemImage: "arrow.clockwise").font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .disabled(model.refreshing)
                    .help("Refresh subscription usage")
                }
                .frame(height: NotchMetrics.footerHeight)
            }
        }
        .padding(.top, NotchMetrics.detailsTopPadding)
        .padding([.horizontal, .bottom], NotchMetrics.panelPadding)
    }

    // With both providers visible each slot shows one provider's selected
    // window. With one provider the slots split its session and weekly
    // windows, which keeps the strip balanced around the camera housing at
    // the same width.
    @ViewBuilder private var compactLeft: some View {
        if model.preferences.showClaude {
            mini(icon: "claude", caption: nil, name: "Claude", snapshot: model.claude,
                 choice: model.preferences.claudeWindow,
                 kind: model.preferences.showCodex ? nil : .session, alignment: .trailing)
        } else {
            mini(icon: "openai", caption: nil, name: "Codex", snapshot: model.codex,
                 choice: model.preferences.codexWindow, kind: .session, alignment: .trailing)
        }
    }

    @ViewBuilder private var compactRight: some View {
        if model.preferences.showCodex {
            mini(icon: model.preferences.showClaude ? "openai" : nil,
                 caption: model.preferences.showClaude ? nil : weeklyLabel(model.codex),
                 name: "Codex", snapshot: model.codex, choice: model.preferences.codexWindow,
                 kind: model.preferences.showClaude ? nil : .weekly, alignment: .leading)
        } else {
            mini(icon: nil, caption: weeklyLabel(model.claude), name: "Claude",
                 snapshot: model.claude, choice: model.preferences.claudeWindow, kind: .weekly, alignment: .leading)
        }
    }

    /// The provider's own label for its weekly bucket. Codex derives labels
    /// from `windowDurationMins`, so this is not always "Weekly".
    private func weeklyLabel(_ snapshot: UsageSnapshot?) -> String {
        snapshot?.windows.first { $0.resolvedKind == .weekly }?.label ?? "Weekly"
    }

    private func mini(icon: String?, caption: String?, name: String,
                      snapshot: UsageSnapshot?, choice: CompactWindowChoice, kind: UsageWindow.Kind?,
                      alignment: Alignment) -> some View {
        let reading = model.preferences.reading(provider: name, choice: choice, kind: kind, snapshot: snapshot,
                                                now: model.tick)
        let noun = model.preferences.percentages == .used ? "used" : "remaining"
        // The left wing's mark carries the dot whichever provider it shows, so
        // hiding Claude never hides that a session needs you.
        let badge = icon != nil && alignment == .trailing && sessions.enabled && sessions.needsYou
        return HStack(spacing: 6) {
            if let icon {
                // Same 21-point frame as before, so the measured wing widths hold.
                ZStack {
                    UsageRing(fraction: reading.fraction, used: reading.used)
                        .frame(width: 20, height: 20)
                    BrandLogo(asset: icon, size: icon == "openai" ? 17 : 11)
                }
                .overlay(alignment: .topTrailing) {
                    if badge { ClaudeSessionBadge().offset(x: 3, y: -3) }
                }
                .frame(width: 21, height: 20)
            }
            if let caption {
                Text(caption).font(.system(size: 9)).foregroundStyle(.secondary)
            }
            Text(reading.value).font(.system(size: 11, weight: .medium)).monospacedDigit()
                .foregroundStyle(reading.stale && reading.value != "—" ? Color.orange : Color.white.opacity(0.9))
                .rollingNumber(reading.fraction ?? -1)
        }
        .frame(maxWidth: .infinity, alignment: alignment)
        .help(reading.explanation)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(reading.label)
        .accessibilityValue((reading.stale || reading.value == "—" ? reading.explanation : "\(reading.value) \(noun)")
            + (badge ? ". A session needs you" : ""))
    }
}

private extension NotchShape {
    func strokeBorderColor(_ opacity: Double) -> some View {
        stroke(.white.opacity(opacity), lineWidth: 0.5)
    }
}

extension View {
    /// Control Center frames every glyph in a circular well. Both header
    /// controls share one so a button and a menu read as a matched pair
    /// instead of two different kinds of control.
    func glyphWell(active: Bool) -> some View {
        frame(width: 22, height: 22)
            .background(Circle().fill(active ? Color.accentColor.opacity(0.22) : Color.white.opacity(0.10)))
    }

    /// The panel's tiles and Settings' sections share this one look.
    func notchTile() -> some View { modifier(NotchTile()) }

    /// A percentage rolls to its new value, digit by digit, as Control
    /// Center's do. `value` only needs to change with the number shown.
    func rollingNumber(_ value: Double) -> some View { modifier(RollingNumber(value: value)) }
}

/// macOS 14 and later; macOS 13 and Reduce Motion change the number at once.
struct RollingNumber: ViewModifier {
    let value: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if #available(macOS 14.0, *), !reduceMotion {
            content
                .contentTransition(.numericText(value: value))
                .animation(.spring(response: 0.35, dampingFraction: 0.9), value: value)
        } else {
            content
        }
    }
}

struct NotchTile: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content
            .background(.white.opacity(contrast == .increased ? 0.1 : 0.06),
                        in: RoundedRectangle(cornerRadius: NotchMetrics.cardRadius, style: .continuous))
            // A lit top edge fading to nothing at the bottom is what separates an
            // Apple tile from a rectangle with a border drawn round it.
            .overlay(
                RoundedRectangle(cornerRadius: NotchMetrics.cardRadius, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(contrast == .increased ? 0.35 : 0.16),
                                                          .white.opacity(contrast == .increased ? 0.25 : 0.04)],
                                                 startPoint: .top, endPoint: .bottom),
                                  lineWidth: 0.5)
            )
    }
}

struct ProviderCard: View {
    let name: String
    let icon: String
    let snapshot: UsageSnapshot?
    let message: String
    let now: Date
    let isDemo: Bool
    let refreshing: Bool
    let mode: PercentageMode
    var pace: PaceEstimate?
    /// Each bar marks how much of its window has gone; on with Pace.
    var marker = false
    var connectTitle: String = "Connect…"
    var emptyOverride: String?
    var statusOverride: String?
    let connect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: NotchMetrics.sectionGap) {
            HStack(spacing: 8) {
                // Scaled down to sit inside the well; the marks keep their own
                // proportions and OpenAI's supplied clear space.
                BrandLogo(asset: icon, size: icon == "openai" ? 19 : 13)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(.white.opacity(0.10)))
                Text(name).font(.subheadline.weight(.semibold))
                Text(status).font(.caption).foregroundStyle(isStale ? Color.orange : Color.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if !message.isEmpty, snapshot?.windows.isEmpty == false {
                    Image(systemName: "exclamationmark.circle")
                        .font(.system(size: 12)).foregroundStyle(.orange)
                        .help(message).accessibilityLabel("Couldn't update. \(message)")
                }
            }

            if let snapshot, !snapshot.windows.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    VStack(spacing: NotchMetrics.sectionGap) {
                        ForEach(Array(snapshot.windows.enumerated()), id: \.offset) { _, window in
                            UsageRow(window: window, mode: mode, now: now, marker: marker)
                        }
                    }
                    Spacer(minLength: 0)
                    if let pace {
                        // Deliberately quiet: an estimate from observed percentage
                        // points, never a countdown to exhaustion.
                        Text(pace.verdict.summary)
                            .font(.caption)
                            .foregroundStyle(pace.verdict.isWarning ? Color.orange : Color.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .help(paceDetail(pace))
                            .accessibilityLabel("\(name) pace estimate")
                            .accessibilityValue(paceDetail(pace))
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text(emptyMessage)
                        .font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineLimit(3)
                    if !refreshing {
                        Button(connectTitle, action: connect)
                            .buttonStyle(.bordered).controlSize(.small)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(NotchMetrics.cardPadding)
        // The panel reserves the slot; the tile fills it. Recomputing the
        // height here from whether this provider happens to have an estimate
        // made the two disagree whenever pace was on but no estimate existed.
        // `cardHeight` must stay at or above the tile's natural content height
        // or this fills nothing and the tile overflows its slot instead.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .notchTile()
        .accessibilityElement(children: .contain)
    }

    private func paceDetail(_ pace: PaceEstimate) -> String {
        guard pace.basisMinutes > 0 else { return "\(pace.verdict.summary). Estimate." }
        return "\(pace.verdict.summary). Estimate based on the last \(pace.basisMinutes) minutes of observed usage."
    }

    private var emptyMessage: String {
        if refreshing { return "Checking your subscription…" }
        if let emptyOverride { return emptyOverride }
        return message.isEmpty ? "Connect to see your subscription usage." : message
    }
    private var isStale: Bool {
        snapshot.map { Freshness.isStale($0.updated, at: now) } ?? false
    }
    private var status: String {
        guard let snapshot, !snapshot.windows.isEmpty else {
            if refreshing { return "Connecting…" }
            return statusOverride ?? "Not connected"
        }
        if isDemo { return "Sample data" }
        return Freshness.summary(snapshot.updated, at: now)
    }
}

struct UsageRow: View {
    let window: UsageWindow
    let mode: PercentageMode
    let now: Date
    var marker = false

    var body: some View {
        // The bar follows the displayed number so the two never disagree, but
        // the warning tint stays on the used share in both modes.
        let clamped = min(100, max(0, window.used))
        let shown = mode == .used ? Int(clamped.rounded()) : window.remaining
        let fraction = mode == .remaining ? 100 - clamped : clamped
        let noun = mode == .used ? "used" : "remaining"
        let expired = window.expired(at: now)
        // Where an even spend would have the bar by now, in the bar's own
        // direction: the remaining bar shrinks as the window goes.
        let elapsed = marker ? window.elapsed(at: now) : nil
        let evenPace = elapsed.map { mode == .used ? $0 : 1 - $0 }
        var spoken = expired ? "Awaiting new window" : "\(shown) percent \(noun)"
        var help = ""
        if let elapsed, !expired {
            let gone = Int((elapsed * 100).rounded())
            spoken += ", \(gone) percent of the window gone"
            help = "\(gone)% of this window has gone. The mark shows where an even spend would be."
        }
        return VStack(alignment: .leading, spacing: 4) {
            Text(window.label).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline) {
                Text(expired ? "—" : "\(shown)%")
                    .font(.title.weight(.semibold)).monospacedDigit()
                    .rollingNumber(expired ? -1 : Double(shown))
                Spacer(minLength: 8)
                Text(window.countdown(at: now)).font(.caption).foregroundStyle(.secondary)
                    .help(window.reset.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Reset time not available")
            }
            ProgressView(value: expired ? 0 : fraction, total: 100)
                .progressViewStyle(UsageProgressStyle(tint: Self.tint(used: clamped), marker: evenPace))
                .frame(height: 6)
                .accessibilityLabel("\(window.label) allowance")
                .accessibilityValue(spoken)
                .help(help)
        }
    }

    /// The tint always follows the **used** share, never the displayed number,
    /// so an exhausted allowance reads as a warning in both percentage modes.
    /// A per-provider tint could not do this: Claude's own orange was the
    /// warning colour, so its bar had no way to escalate.
    static func tint(used: Double) -> Color {
        if used >= 100 { return .red }
        if used >= 90 { return .orange }
        return .white.opacity(0.92)
    }
}

struct UsageProgressStyle: ProgressViewStyle {
    var tint: Color
    /// Where a small caret sits above the bar, 0 to 1, or nil for none. It
    /// is drawn outside the bar's frame, so the tile's layout is unchanged.
    var marker: Double? = nil
    func makeBody(configuration: Configuration) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.12))
                Capsule().fill(tint)
                    .frame(width: geometry.size.width * min(1, max(0, configuration.fractionCompleted ?? 0)))
                if let marker {
                    PaceCaret()
                        .fill(Color.white.opacity(0.6))
                        .frame(width: 7, height: 4)
                        .offset(x: geometry.size.width * min(1, max(0, marker)) - 3.5, y: -6)
                        .accessibilityHidden(true)
                }
            }
        }
    }
}

/// A small downward triangle.
struct PaceCaret: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// A thin ring around a compact mark, filled to the same share as the number
/// beside it. Decorative: the slot's label already carries the reading.
struct UsageRing: View {
    let fraction: Double?
    let used: Double?

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.12), lineWidth: 2)
            if let fraction, let used {
                Circle().trim(from: 0, to: min(1, max(0, fraction)))
                    .stroke(UsageRow.tint(used: used), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .accessibilityHidden(true)
    }
}
