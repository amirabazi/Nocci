import SwiftUI

/// Fills the same slot as the provider cards, so switching tabs never changes
/// the panel's size or the hover rectangle derived from it.
struct PullRequestListView: View {
    @ObservedObject var model: PullRequestModel
    let reviews: CodeReviewModel
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if PullRequestFilter.isAvailable(for: model.settings) {
                HStack {
                    Spacer()
                    PullRequestFilterPicker(selection: $model.filter)
                }
            }
            if model.visibleGroups.isEmpty {
                emptyState
            } else {
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(model.visibleGroups) { group in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(group.title)
                                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                                    .accessibilityAddTraits(.isHeader)
                                ForEach(group.items) { item in
                                    HStack(spacing: 2) {
                                        // A link on another host than the one asked is never opened, so
                                        // such a row does not look clickable either.
                                        PullRequestRow(item: item, now: now, enabled: model.canOpen(item),
                                                       sample: model.demo) { model.open(item) }
                                            .contextMenu { PullRequestMenu(model: model, item: item) }
                                        CodeReviewButton(model: reviews, item: item)
                                    }
                                }
                            }
                        }
                        if model.visibleTruncated {
                            Text("Only the \(PullRequestCommands.limit) most recent in each of Authored, Assigned and Review requested are shown.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(NotchMetrics.cardPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .notchTile()
        .accessibilityElement(children: .contain)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.isCheckingFirstTime {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Checking pull requests…")
                }
                .font(.subheadline).foregroundStyle(.secondary)
            } else {
                Text(emptyMessage)
                    .font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(3)
                if model.settings.targets.isEmpty || model.visibleTargets.contains(where: { model.failures[$0] != nil }) {
                    Button("Pull Request Settings…") { model.onSettings?() }
                        .buttonStyle(.bordered).controlSize(.small)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var emptyMessage: String {
        if model.settings.targets.isEmpty {
            return "Choose GitHub or a GitLab host in Settings to see pull requests here."
        }
        if let message = model.visibleTargets.lazy
            .compactMap({ target in model.failures[target]?.message(for: target) }).first {
            return message
        }
        if model.awaitingFirstAnswer { return "Waiting for the first refresh." }
        return model.activeFilter.emptyText
    }
}

/// Drawn in SwiftUI because AppKit's segmented control cannot show the brand
/// marks at icon size in their own colours.
struct PullRequestFilterPicker: View {
    @Binding var selection: PullRequestFilter

    var body: some View {
        HStack(spacing: 2) {
            ForEach(PullRequestFilter.allCases, id: \.self) { filter in
                Button { selection = filter } label: {
                    Group {
                        switch filter {
                        case .all: Text("All").font(.caption.weight(.medium))
                        case .github: BrandLogo(asset: "github", size: 14)
                        case .gitlab: BrandLogo(asset: "gitlab", size: 14)
                        }
                    }
                    .frame(width: 32, height: 18)
                    .background(Capsule().fill(.white.opacity(selection == filter ? 0.22 : 0)))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(filter.title)
                .accessibilityLabel(filter.title)
                .accessibilityAddTraits(selection == filter ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Capsule().fill(.white.opacity(0.10)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Show pull requests from")
    }
}

struct PullRequestRow: View {
    let item: PullRequest
    let now: Date
    let enabled: Bool
    var sample = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                CheckGlyph(state: item.checks)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(.body).lineLimit(1).truncationMode(.tail)
                    Text("\(item.reference) · \(item.roleText)")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(PullRequestAge.short(item.updated, at: now))
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PullRequestRowStyle())
        .disabled(!enabled)
        .help(item.url.absoluteString)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.title), \(item.repo) \(item.reference)")
        .accessibilityValue("\(item.roleText), \(PullRequestAge.spoken(item.updated, at: now)), \(CheckGlyph.description(item.checks))")
        .accessibilityHint(enabled ? "Opens in your browser" : sample ? "Sample data" : "Its link is on another host, so Nocci doesn’t open it")
        .accessibilityAddTraits(.isLink)
    }
}

/// A row's right-click menu. Clicking the row already opens the pull request,
/// so the menu offers only what a click cannot. Every page passes the same
/// same-host rule as the row itself, and nothing opens or copies from sample data.
struct PullRequestMenu: View {
    let model: PullRequestModel
    let item: PullRequest

    var body: some View {
        Button("Copy Link") { model.copyLink(item) }
            .disabled(model.demo)
        Divider()
        Button("Open Repository") { model.open(item, .repository) }
            .disabled(!model.canOpen(item, .repository))
        Button(item.ciTitle) { model.open(item, .ci) }
            .disabled(!model.canOpen(item, .ci))
    }
}

/// Starts a review of this row in a Nocci terminal tab. A sibling of the row's
/// own button, never inside it, so clicking the row still opens the browser.
struct CodeReviewButton: View {
    @ObservedObject var model: CodeReviewModel
    let item: PullRequest

    var body: some View {
        Button { model.review(item) } label: {
            Image(systemName: "text.magnifyingglass")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(PullRequestRowStyle())
        .disabled(!model.canReview)
        .help(model.help)
        .accessibilityLabel("Code review, \(item.reference), \(item.repo)")
        .accessibilityHint("Opens a Nocci terminal tab")
    }
}

/// Pressed feedback only. Rows have no hover highlight, so nothing in the
/// panel depends on SwiftUI pointer tracking.
struct PullRequestRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.vertical, 3).padding(.horizontal, 4)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.white.opacity(configuration.isPressed ? 0.12 : 0)))
    }
}

/// Shape carries the state as well as colour, so it is never colour alone.
struct CheckGlyph: View {
    let state: CheckState?

    var body: some View {
        Group {
            switch state {
            case .passing?: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .failing?: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            case .running?: Image(systemName: "clock.fill").foregroundStyle(.yellow)
            case .neutral?: Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
            case nil: Color.clear
            }
        }
        .font(.system(size: 11, weight: .semibold))
        .frame(width: 14, height: 14)
        .accessibilityHidden(true)
    }

    static func description(_ state: CheckState?) -> String {
        switch state {
        case .passing?: return "checks passing"
        case .failing?: return "checks failing"
        case .running?: return "checks running"
        case .neutral?: return "checks skipped or cancelled"
        case nil: return "no check status"
        }
    }
}

struct PullRequestFooter: View {
    @ObservedObject var model: PullRequestModel
    let now: Date

    var body: some View {
        HStack(spacing: 6) {
            Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            if let problem {
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 12)).foregroundStyle(.orange)
                    .help(problem).accessibilityLabel("Couldn’t update. \(problem)")
            }
            Spacer()
            if model.refreshing {
                ProgressView().controlSize(.mini).scaleEffect(0.75).frame(width: 12, height: 12)
                Text("Updating…").font(.caption).foregroundStyle(.secondary)
            }
            Button { model.refresh(reason: .manual) } label: {
                Label("Refresh", systemImage: "arrow.clockwise").font(.caption)
            }
            .buttonStyle(.borderless)
            .disabled(model.refreshing || model.demo)
            .help("Refresh pull requests")
        }
        .frame(height: NotchMetrics.footerHeight)
    }

    private var summary: String {
        if model.demo { return "Sample data" }
        guard let lastSuccess = model.visibleLastSuccess else { return "" }
        return "\(model.visibleCount) open · \(Freshness.summary(lastSuccess, at: now))"
    }

    /// Shown only beside rows; with no rows the tile already says what failed.
    private var problem: String? {
        let messages = model.visibleTargets.compactMap { target in model.failures[target]?.message(for: target) }
        return messages.isEmpty || model.visibleGroups.isEmpty ? nil : messages.joined(separator: "\n")
    }
}
