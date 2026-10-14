import AppKit
import Combine
import SwiftUI

/// The window's close button closes every tab; Close in the Window menu
/// (Command-W) closes only the selected one. Both arrive
/// here as `performClose`, told apart by their sender.
final class TerminalWindow: NSWindow {
    var onCloseTab: (() -> Void)?
    /// True while a drop or tuck slides behind the menu bar, where AppKit
    /// would otherwise push a titled window back down.
    var unconstrained = false

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        unconstrained ? frameRect : super.constrainFrameRect(frameRect, to: screen)
    }

    override func performClose(_ sender: Any?) {
        if let button = sender as? NSButton, button === standardWindowButton(.closeButton) {
            super.performClose(sender)
        } else {
            onCloseTab?()
        }
    }
}

final class TerminalWindowController: NSObject, NSWindowDelegate {
    let window: TerminalWindow
    private let model: TerminalModel
    private let container = NSView()
    private let startPage: NSView
    private var cancellables = Set<AnyCancellable>()
    private(set) var placement = TerminalPlacement.hidden {
        didSet {
            guard placement != oldValue else { return }
            ordinaryFrame = TerminalRules.ordinaryFrame(ordinaryFrame, leaving: oldValue, current: window.frame)
            window.setFrameAutosaveName(TerminalRules.savesFrame(placement) ? TerminalMetrics.frameName : "")
            // Dropped, it follows the user onto any Space, full-screen ones included.
            window.collectionBehavior = placement == .dropped ? [.canJoinAllSpaces, .fullScreenAuxiliary] : []
            onPlacementChange?(placement)
        }
    }
    var onPlacementChange: ((TerminalPlacement) -> Void)?
    /// The frame the user chose; a drop never changes it.
    private var ordinaryFrame = NSRect.zero
    private var animating = false
    private var showAfterAnimation = false
    private var resignObserver: NSObjectProtocol?

    init(model: TerminalModel, projects: ProjectModel, screen: NSScreen?) {
        self.model = model
        window = TerminalWindow(contentRect: NSRect(origin: .zero, size: TerminalMetrics.defaultSize),
                                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                backing: .buffered, defer: false)
        let page = NSHostingView(rootView: TerminalStartPage(model: model, projects: projects))
        page.sizingOptions = []
        startPage = page
        super.init()
        window.title = "Nocci"
        window.isReleasedWhenClosed = false
        // The same title row as Settings: an empty unified toolbar gives it 52
        // points, and the tabs sit in it inside a control AppKit can see.
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.toolbar = NSToolbar(identifier: "terminal")
        window.toolbarStyle = .unified
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .black
        window.minSize = TerminalMetrics.minimumSize
        window.delegate = self
        window.onCloseTab = { [weak model] in model?.closeSelected() }

        let content = NSView(frame: NSRect(origin: .zero, size: TerminalMetrics.defaultSize))
        container.frame = NSRect(x: 0, y: 0, width: content.bounds.width, height: content.bounds.height - SettingsMetrics.barHeight)
        container.autoresizingMask = [.width, .height]
        content.addSubview(container)
        let control = TitlebarControl(frame: NSRect(
            x: TerminalMetrics.stripLeading,
            y: content.bounds.height - (SettingsMetrics.barHeight + TerminalMetrics.stripHeight) / 2,
            width: content.bounds.width - TerminalMetrics.stripLeading - 12, height: TerminalMetrics.stripHeight))
        control.autoresizingMask = [.width, .minYMargin]
        let strip = TitlebarHost(rootView: TerminalTabStrip(model: model))
        strip.sizingOptions = []
        strip.frame = control.bounds
        strip.autoresizingMask = [.width, .height]
        control.addSubview(strip)
        content.addSubview(control)
        window.contentView = content
        // Adding the toolbar grew the window by its height; set it back.
        window.setContentSize(TerminalMetrics.defaultSize)
        if !window.setFrameUsingName(TerminalMetrics.frameName) { center(on: screen) }
        window.setFrameAutosaveName(TerminalMetrics.frameName)

        // @Published sends before the value changes, so the view is chosen on
        // the next turn of the main queue.
        model.$selection.map { _ in () }.merge(with: model.$tabs.map { _ in () })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.showSelected() }
            .store(in: &cancellables)
        ordinaryFrame = window.frame
        resignObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            self?.resigned()
        }
    }

    deinit {
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
    }

    /// The Dock, Cmd-Tab and a new session: the window where the user keeps
    /// it, or where it already hangs from the notch.
    func show() {
        // A code review or a Sessions row can land during a tuck; it is shown
        // once the tuck ends rather than lost.
        guard !animating else { showAfterAnimation = true; return }
        let next = TerminalRules.placement(after: .show, from: placement)
        if next == .ordinary && placement != .ordinary {
            window.alphaValue = 1
            // The display it was on may have gone since.
            var frame = ordinaryFrame
            if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }), let visible = NSScreen.main?.visibleFrame {
                frame.origin = NSPoint(x: visible.midX - frame.width / 2, y: visible.midY - frame.height / 2)
            }
            window.setFrame(frame, display: false)
        }
        placement = next
        window.deminiaturize(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide() {
        window.orderOut(nil)
        window.alphaValue = 1
        placement = TerminalRules.placement(after: .empty, from: placement)
    }

    /// Drops the window from the notch, or tucks it back when it hangs there.
    func summon(anchor: CGRect?, screen: NSScreen?) {
        guard !animating else { return }
        if TerminalRules.placement(after: .summon, from: placement) == .dropped {
            drop(anchor: anchor, screen: screen)
        } else {
            tuck(returningFocus: true)
        }
    }

    private func drop(anchor: CGRect?, screen: NSScreen?) {
        guard let visible = (screen ?? window.screen ?? NSScreen.main)?.visibleFrame else { return }
        placement = .dropped
        let target = TerminalRules.droppedFrame(size: ordinaryFrame.size, visible: visible,
                                                anchor: anchor ?? CGRect(x: visible.midX, y: visible.maxY, width: 0, height: 0))
        let wasVisible = window.isVisible
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        animating = true
        if !wasVisible {
            window.alphaValue = 0
            window.unconstrained = !reduceMotion
            window.setFrame(reduceMotion ? target : TerminalRules.dropStart(target), display: false)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        animate(to: target, alpha: 1, duration: reduceMotion ? 0.15 : 0.3, timing: .easeOut)
    }

    /// Slides the window back behind the menu bar and orders it out. Sessions
    /// keep running.
    private func tuck(returningFocus: Bool) {
        let frame = window.frame
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        placement = TerminalRules.placement(after: returningFocus ? .summon : .resign, from: placement)
        animating = true
        window.unconstrained = !reduceMotion
        animate(to: reduceMotion ? frame : TerminalRules.dropStart(frame), alpha: 0,
                duration: reduceMotion ? 0.15 : 0.25, timing: .easeIn) { [weak self] in
            guard let self else { return }
            self.window.orderOut(nil)
            self.window.alphaValue = 1
            self.window.setFrame(frame, display: false)
            // Give the keyboard back to the app the user came from, unless
            // another Nocci window, such as Settings, is still up.
            if returningFocus, NSApp.isActive, !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) {
                NSApp.deactivate()
            }
        }
    }

    private func animate(to frame: NSRect, alpha: CGFloat, duration: TimeInterval,
                         timing: CAMediaTimingFunctionName, completion: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: timing)
            window.animator().setFrame(frame, display: true)
            window.animator().alphaValue = alpha
        }, completionHandler: { [weak self] in
            guard let self else { return }
            completion?()
            self.window.unconstrained = false
            self.animating = false
            if self.showAfterAnimation {
                self.showAfterAnimation = false
                self.show()
            }
        })
    }

    private func resigned() {
        guard placement == .dropped, !animating else { return }
        tuck(returningFocus: false)
    }

    /// Only a move the user makes with the mouse counts; Nocci's own frame
    /// changes never make the window ordinary.
    func windowDidMove(_ notification: Notification) {
        guard !animating, NSEvent.pressedMouseButtons & 1 == 1 else { return }
        let next = TerminalRules.placement(after: .drag, from: placement)
        guard next != placement else { return }
        placement = next
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { model.closeAll() }

    private func showSelected() {
        guard let tab = model.selectedTab else { return container.subviews.forEach { $0.removeFromSuperview() } }
        let shown = tab.start == nil ? startPage : model.session(for: tab.id)?.view ?? startPage
        guard container.subviews != [shown] else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        shown.frame = container.bounds
        shown.autoresizingMask = [.width, .height]
        container.addSubview(shown)
        if shown !== startPage { window.makeFirstResponder(shown) }
    }

    private func center(on screen: NSScreen?) {
        guard let visible = (screen ?? NSScreen.main)?.visibleFrame else { return window.center() }
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2))
    }
}

/// The tabs in the title row: one capsule per tab, its close button, and New Tab.
struct TerminalTabStrip: View {
    @ObservedObject var model: TerminalModel

    var body: some View {
        HStack(spacing: 4) {
            ForEach(model.windowTabs) { tab in
                TerminalTabButton(title: model.title(for: tab), selected: model.selection == tab.id, waiting: model.waiting(tab),
                                  select: { model.selection = tab.id }, close: { _ = model.close(tab.id) })
            }
            Button {
                model.newTab()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("New Tab")
            .accessibilityLabel("New Tab")
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Terminal tabs")
    }
}

private struct TerminalTabButton: View {
    let title: String
    let selected: Bool
    /// The same wait the Sessions list shows.
    let waiting: Bool
    let select: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: select) {
                HStack(spacing: 5) {
                    if waiting {
                        Circle().fill(Color.orange).frame(width: 6, height: 6).accessibilityHidden(true)
                    }
                    Text(title)
                        .font(.callout.weight(selected ? .semibold : .regular))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 180)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(waiting ? "\(title), needs you" : title)
            .accessibilityAddTraits(selected ? .isSelected : [])
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .help("Close Tab")
            .accessibilityLabel("Close \(title)")
        }
        .foregroundStyle(selected ? Color.white : Color.secondary)
        .padding(.horizontal, 10)
        .frame(minHeight: 24)
        .background {
            if selected { Capsule().fill(Color.white.opacity(0.12)) }
        }
    }
}

/// A new tab before it starts: project or folder, agent and an optional
/// prompt, with the compose view's keys.
struct TerminalStartPage: View {
    @ObservedObject var model: TerminalModel
    @ObservedObject var projects: ProjectModel
    @FocusState private var promptFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("New session").font(.title3.weight(.semibold))
                Text("Experimental").font(.callout).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                if projects.settings.enabled && !projects.projects.isEmpty {
                    Picker("Project", selection: Binding(get: { model.draftFolder }, set: { path in
                        guard let path else { return }
                        model.chooseDraft(folder: path, label: projects.labels[path] ?? (path as NSString).lastPathComponent)
                    })) {
                        if let folder = model.draftFolder, !projects.projects.contains(where: { $0.path == folder }) {
                            Text(model.draftLabel).tag(Optional(folder))
                        }
                        ForEach(projects.projects, id: \.path) { project in
                            Text(projects.labels[project.path] ?? project.name).tag(Optional(project.path))
                        }
                    }
                    .fixedSize()
                } else {
                    Text(model.draftFolder == nil ? "No folder chosen" : model.draftLabel)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Button("Choose Folder…") { model.onChooseFolder?() }
                Picker("Agent", selection: $model.draftAgent) {
                    ForEach(ProjectAgent.allCases) { agent in Text(agent.title).tag(agent) }
                }
                .labelsHidden()
                .fixedSize()
            }
            TextField("What should it do? (optional)", text: $model.draftPrompt, axis: .vertical)
                .lineLimit(3, reservesSpace: true)
                .textFieldStyle(.roundedBorder)
                .focused($promptFocused)
                .onSubmit { model.startDraft() }
                .accessibilityLabel("Prompt")
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let status = model.draftStatus {
                    Text(status).font(.caption).foregroundStyle(.red).lineLimit(2)
                }
                Spacer(minLength: 0)
                Button("Cancel") { model.closeSelected() }
                    .keyboardShortcut(.cancelAction)
                Button("Start") { model.startDraft() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(maxWidth: 520)
        .notchTile()
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .onAppear {
            promptFocused = true
            projects.scan(force: false)
            if model.draftFolder == nil, projects.settings.enabled, let first = projects.projects.first {
                model.chooseDraft(folder: first.path, label: projects.labels[first.path] ?? first.name)
            }
        }
    }
}
