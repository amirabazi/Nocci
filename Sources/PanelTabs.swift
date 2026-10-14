import SwiftUI

extension PanelTab {
    var title: String {
        switch self {
        case .usage: return "Usage"
        case .pullRequests: return "Pull Requests"
        case .sessions: return "Sessions"
        case .projects: return "Projects"
        }
    }

    /// SF Symbols that exist on macOS 13, the deployment floor.
    var symbol: String {
        switch self {
        case .usage: return "gauge"
        case .pullRequests: return "arrow.triangle.pull"
        case .sessions: return "terminal"
        case .projects: return "folder"
        }
    }
}

/// The panel's tabs as icons beside the camera. The selection capsule slides
/// between them; each name is the tooltip and the VoiceOver label.
struct PanelTabs: View {
    let tabs: [PanelTab]
    @Binding var selection: PanelTab
    /// The tab that carries the red "needs you" dot, if any.
    var badged: PanelTab?
    @Namespace private var namespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs, id: \.self) { tab in
                Button {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85)) {
                        selection = tab
                    }
                } label: {
                    Image(systemName: tab.symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(selection == tab ? Color.white : Color.secondary)
                        .frame(width: 32, height: 24)
                        .background {
                            if selection == tab {
                                Capsule().fill(Color.white.opacity(0.12))
                                    .matchedGeometryEffect(id: "selection", in: namespace)
                            }
                        }
                        .overlay(alignment: .topTrailing) {
                            if badged == tab { ClaudeSessionBadge().offset(x: -6, y: 4) }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(tab.title)
                .accessibilityLabel(tab.title)
                .accessibilityValue(badged == tab ? "Needs you" : "")
                .accessibilityAddTraits(selection == tab ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Choose what the panel shows")
    }
}
