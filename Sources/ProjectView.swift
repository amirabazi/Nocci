import Combine
import SwiftUI

/// Fills the same slot as the provider cards, so switching tabs never changes
/// the panel's size or the hover rectangle derived from it.
struct ProjectListView: View {
    @ObservedObject var model: ProjectModel
    let now: Date
    /// False while the panel is closed; a notch terminal's AppKit view is
    /// hidden then.
    let open: Bool

    var body: some View {
        Group {
            if let project = model.selected {
                ProjectComposeView(model: model, project: project, label: model.labels[project.path] ?? project.name)
            } else if let tab = model.shownTab {
                NotchTerminalView(model: model, tab: tab, open: open)
            } else if model.projects.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text(model.emptyText).font(.subheadline).foregroundStyle(.secondary)
                    if model.settings.folders.isEmpty {
                        Button("Open Settings") { model.onSettings?() }
                    }
                    Spacer(minLength: 0)
                }
            } else {
                let labels = model.labels
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(model.projects) { project in
                            let session = model.notchSessions[project.path]
                            ProjectRow(project: project, label: labels[project.path] ?? project.name,
                                       now: now, enabled: !model.demo, session: session) { model.open(project) }
                                .contextMenu {
                                    if session != nil {
                                        Button("New Session…") { model.compose(project) }.disabled(model.demo)
                                    }
                                    Button("Reveal in Finder") { model.revealInFinder(project) }.disabled(model.demo)
                                    if let shell = model.shellTarget {
                                        Button("Open in \(model.targetNames[shell] ?? "Terminal")") { model.openShell(project) }
                                            .disabled(model.demo)
                                    }
                                    if model.installed.contains(.vscode) {
                                        Button("Open in \(model.targetNames[.vscode] ?? "VS Code")") { model.openInEditor(project) }
                                            .disabled(model.demo)
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

struct ProjectRow: View {
    let project: Project
    /// The name, plus the chosen folder when names clash.
    let label: String
    let now: Date
    let enabled: Bool
    /// Its notch session, when it has one.
    let session: NotchSession?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: project.isRepo ? "arrow.triangle.branch" : "folder")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 14)
                    .accessibilityHidden(true)
                Text(label).font(.body).lineLimit(1).truncationMode(.middle)
                if let session {
                    Image(systemName: "apple.terminal")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .overlay(alignment: .topTrailing) {
                            if session.waiting {
                                Circle().fill(Color.orange).frame(width: 6, height: 6).offset(x: 3, y: -3)
                            }
                        }
                        .accessibilityHidden(true)
                }
                Spacer(minLength: 8)
                if let activity = project.activity {
                    Text(PullRequestAge.short(activity, at: now))
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        // Pressed feedback only, like pull request rows: nothing in the panel
        // depends on SwiftUI pointer tracking.
        .buttonStyle(PullRequestRowStyle())
        .disabled(!enabled)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel)
        .accessibilityHint(!enabled ? "Sample data" : session != nil ? "Shows its terminal" : "Starts a new session")
    }

    private var spokenLabel: String {
        spokenProject + (session.map { $0.waiting ? ", waiting in the notch" : ", running in the notch" } ?? "")
    }

    /// Commas rather than the visible dots, so VoiceOver pauses instead of naming them.
    private var spokenProject: String {
        let name = label.replacingOccurrences(of: " · ", with: ", ")
        guard project.isRepo else { return "\(name), folder" }
        guard let activity = project.activity else { return "\(name), git repository" }
        return "\(name), git repository, " + PullRequestAge.spoken(activity, at: now).replacingOccurrences(of: "updated", with: "active")
    }
}

/// Replaces the list while a prompt is written. The panel takes the keyboard
/// only while this is shown.
struct ProjectComposeView: View {
    @ObservedObject var model: ProjectModel
    let project: Project
    let label: String
    @FocusState private var promptFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Button {
                    model.endCompose()
                } label: {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
                .help("Back to projects")
                .accessibilityLabel("Back to projects")
                Text(label).font(.headline).lineLimit(1).truncationMode(.middle)
            }
            HStack(spacing: 8) {
                Picker("Agent", selection: Binding(get: { model.settings.agent }, set: { model.choose(agent: $0) })) {
                    ForEach(ProjectAgent.allCases) { agent in Text(agent.title).tag(agent) }
                }
                .labelsHidden()
                .fixedSize()
                Picker("Open in", selection: Binding(get: { model.target },
                                                     set: { if let target = $0 { model.choose(target: target) } })) {
                    ForEach(model.targets) { target in
                        Text(model.targetNames[target] ?? target.rawValue).tag(Optional(target))
                    }
                }
                .fixedSize()
            }
            .controlSize(.small)
            TextField("What should it do? (optional)", text: $model.prompt, axis: .vertical)
                .lineLimit(3, reservesSpace: true)
                .textFieldStyle(.roundedBorder)
                .focused($promptFocused)
                .onSubmit { model.start() }
                .accessibilityLabel("Prompt for \(label)")
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let line = model.statusLine {
                    Text(line.text).font(.caption)
                        .foregroundStyle(line.isProblem ? Color.red : Color.secondary)
                        .lineLimit(1).truncationMode(.tail)
                        .help(line.text)
                }
                Spacer(minLength: 0)
                Button("Start") { model.start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canStart)
                    .controlSize(.small)
            }
        }
        .onAppear { promptFocused = true }
    }
}

/// Whether the shape's opening spring has settled, for `NotchTerminalView`.
/// A plain `@State` bool needs the SwiftUI macro plugin, which the CLT
/// toolchain this project builds with does not have, so this uses the
/// codebase's usual `ObservableObject` pattern instead, held with
/// `@StateObject` for identity across re-renders.
final class NotchTerminalSettled: ObservableObject {
    @Published var settled = false
}

/// A notch session in the Projects tile, under one header row.
/// Escape belongs to the terminal, so only the chevron goes back.
struct NotchTerminalView: View {
    @ObservedObject var model: ProjectModel
    let tab: UUID
    let open: Bool
    @StateObject private var settledState = NotchTerminalSettled()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Button {
                    model.backToList()
                } label: {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .help("Back to projects")
                .accessibilityLabel("Back to projects")
                Text(model.shownFolder.flatMap { model.notchSessions[$0]?.title } ?? "")
                    .font(.headline).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                Button {
                    model.moveShownToWindow()
                } label: {
                    Image(systemName: "macwindow").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .help("Open in window")
                .accessibilityLabel("Open in window")
                Button {
                    model.closeShown()
                } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .help("Close session")
                .accessibilityLabel("Close session")
            }
            NotchTerminalHost(model: model, tab: tab, view: model.sessionView?(tab), focus: model.typing,
                              visible: open && settledState.settled)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .task(id: open) {
            guard open else { return settledState.settled = false }
            // The shape's opening spring settles in about 0.35 s.
            try? await Task.sleep(nanoseconds: 350_000_000)
            if !Task.isCancelled { settledState.settled = true }
        }
    }
}

/// Puts a notch session's own view in the tile. `TerminalContainer` decides
/// when it may join, and never takes it back from the window.
struct NotchTerminalHost: NSViewRepresentable {
    let model: ProjectModel
    let tab: UUID
    let view: NSView?
    let focus: Bool
    let visible: Bool

    final class Coordinator {
        var tab: UUID
        var shown: AnyCancellable?

        init(tab: UUID) { self.tab = tab }
    }

    func makeCoordinator() -> Coordinator { Coordinator(tab: tab) }

    func makeNSView(context: Context) -> TerminalContainer {
        let container = TerminalContainer(frame: .zero)
        let coordinator = context.coordinator
        // A leaving tile stays on screen through its exit animation with no
        // update, and its clip never reaches this view, so it hides at once.
        let shownTab = model.$showingTerminal.combineLatest(model.$shownFolder, model.$notchSessions)
            .map { (showing: Bool, folder: String?, sessions: [String: NotchSession]) -> UUID? in
                showing ? folder.flatMap { sessions[$0]?.tab } : nil
            }
        coordinator.shown = shownTab.sink { [weak container, weak coordinator] shown in
            guard let coordinator, shown != coordinator.tab else { return }
            container?.isHidden = true
        }
        return container
    }

    func updateNSView(_ container: TerminalContainer, context: Context) {
        context.coordinator.tab = tab
        container.isHidden = !visible
        if container.session !== view { container.session = view }
        if container.focus != focus { container.focus = focus }
    }

    static func dismantleNSView(_ container: TerminalContainer, coordinator: Coordinator) {
        container.session = nil
    }
}

struct ProjectFooter: View {
    @ObservedObject var model: ProjectModel

    var body: some View {
        HStack(spacing: 6) {
            Text(model.footerText).font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
            Spacer()
        }
        .frame(height: NotchMetrics.footerHeight)
    }
}
