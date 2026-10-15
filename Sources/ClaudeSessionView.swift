import SwiftUI

/// Fills the same slot as the provider cards, so switching tabs never changes
/// the panel's size or the hover rectangle derived from it.
struct ClaudeSessionListView: View {
    @ObservedObject var model: ClaudeSessionModel
    let now: Date
    private static let miniID = "session-mini-view"

    var body: some View {
        Group {
            if model.items.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("No session needs you.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            } else {
                let labels = model.labels
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(model.items) { item in
                                ClaudeSessionRow(item: item, label: labels[item.id] ?? ClaudeSessionRules.name(of: item),
                                                 now: now, enabled: !model.demo, hosted: model.isHosted(item),
                                                 inNotch: model.isInNotch(item),
                                                 answering: model.answering?.id == item.id,
                                                 action: { model.open(item) }, answer: { model.toggleAnswer(item) })
                                    .contextMenu {
                                        Button("Dismiss") { model.dismiss(item) }.disabled(model.demo)
                                        Button("Dismiss All") { model.dismissAll() }.disabled(model.demo)
                                    }
                                if model.answering?.id == item.id, let tab = item.record.tab {
                                    ClaudeSessionMiniHost(make: { model.hostedView?(tab) })
                                        .frame(height: TerminalMetrics.miniHeight)
                                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                        .id(Self.miniID)
                                        // Under a low row it would open below the tile's visible part.
                                        .onAppear { DispatchQueue.main.async { proxy.scrollTo(Self.miniID, anchor: .bottom) } }
                                }
                            }
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
}

struct ClaudeSessionRow: View {
    let item: ClaudeSessionItem
    /// The project, plus the app and start time when names clash.
    let label: String
    let now: Date
    let enabled: Bool
    /// Runs in a Nocci terminal tab: the row summons the window and the
    /// chevron opens a mini view.
    let hosted: Bool
    /// Its tab is in the Projects tile, so it has no mini view.
    let inNotch: Bool
    let answering: Bool
    let action: () -> Void
    let answer: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            Button(action: action) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    ClaudeSessionGlyph(state: item.record.state)
                    if hosted {
                        Image(systemName: "macwindow")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    Text(label).font(.body).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(item.record.state.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Text(PullRequestAge.short(item.record.since, at: now))
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            // Pressed feedback only, like pull request rows: nothing in the panel
            // depends on SwiftUI pointer tracking.
            .buttonStyle(PullRequestRowStyle())
            .disabled(!enabled)
            .help(hosted ? "Show its terminal"
                  : item.record.host == nil ? "The app running this session is unknown" : "Bring its app to the front")
            .accessibilityElement(children: .ignore)
            // Commas rather than the visible dots, so VoiceOver pauses instead of naming them.
            .accessibilityLabel("\(label.replacingOccurrences(of: " · ", with: ", ")), \(item.record.state.title)"
                                + (hosted ? ", in Nocci" : ""))
            .accessibilityValue(PullRequestAge.spoken(item.record.since, at: now)
                .replacingOccurrences(of: "updated", with: "started waiting"))
            .accessibilityHint(!enabled ? "Sample data" : hosted ? "Shows its terminal" : "Brings its app to the front")
            if hosted && !inNotch {
                Button(action: answer) {
                    Image(systemName: answering ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!enabled)
                .help(answering ? "Hide the session" : "Answer from here (experimental)")
                .accessibilityLabel(answering ? "Hide \(label)" : "Answer \(label) from here")
            }
        }
    }
}

/// Hosts one session's mini view inside the Sessions tile. The view takes the
/// keyboard itself once it joins the panel, which `AppDelegate` has made key.
struct ClaudeSessionMiniHost: NSViewRepresentable {
    let make: () -> NSView?

    func makeNSView(context: Context) -> NSView { make() ?? NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Shape carries the state as well as colour, so it is never colour alone.
struct ClaudeSessionGlyph: View {
    let state: ClaudeSessionState

    var body: some View {
        Group {
            switch state {
            case .permission: Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
            case .question: Image(systemName: "questionmark.bubble.fill").foregroundStyle(.blue)
            case .yourTurn: Image(systemName: "checkmark.bubble.fill").foregroundStyle(.green)
            case .waiting: Image(systemName: "exclamationmark.bubble.fill").foregroundStyle(.orange)
            case .working, .ended: Color.clear
            }
        }
        .font(.system(size: 11, weight: .semibold))
        .frame(width: 14, height: 14)
        .accessibilityHidden(true)
    }
}

struct ClaudeSessionFooter: View {
    @ObservedObject var model: ClaudeSessionModel

    var body: some View {
        HStack(spacing: 6) {
            Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
        }
        .frame(height: NotchMetrics.footerHeight)
    }

    private var summary: String {
        if model.demo { return "Sample data" }
        return model.items.isEmpty ? "All caught up" : "\(model.items.count) need\(model.items.count == 1 ? "s" : "") you"
    }
}

/// Sits on the corner of the compact Claude mark as an overlay, so the wing
/// widths measured in `NotchMetrics` never change. Red with a dark ring,
/// because the Claude mark is itself orange.
struct ClaudeSessionBadge: View {
    var body: some View {
        Circle().fill(Color.red)
            .frame(width: 6, height: 6)
            .overlay(Circle().strokeBorder(Color.black, lineWidth: 1))
            .accessibilityHidden(true)
    }
}
