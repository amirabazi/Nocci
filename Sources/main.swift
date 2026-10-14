import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

final class NotchPanel: NSPanel {
    /// True only while the Projects compose view, a session's mini view or,
    /// with the panel open, a notch terminal is shown, the only times the
    /// notch takes the keyboard.
    var acceptsKeyboard = false
    /// True while a notch terminal is shown without the keyboard: then only a
    /// click inside the session's view makes the panel key.
    var keyOnlyInTerminal = false
    private var clickInTerminal = false
    override var canBecomeKey: Bool { acceptsKeyboard && (!keyOnlyInTerminal || clickInTerminal) }
    override var canBecomeMain: Bool { false }

    /// A click makes the panel key inside `super.sendEvent`, so the hit is
    /// recorded only for that call. `hitTest` takes a point in the content
    /// view's superview's coordinates.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, let content = contentView {
            let point = content.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
            clickInTerminal = content.hitTest(point).map {
                sequence(first: $0, next: \.superview).contains { $0 is TerminalContainer }
            } ?? false
        }
        super.sendEvent(event)
        clickInTerminal = false
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    /// Created in demo mode for `--demo`, so the models that follow it never
    /// start live work before demo begins.
    let model = UsageModel(demo: CommandLine.arguments.contains("--demo"))
    var panel: NotchPanel!
    var statusItem: NSStatusItem!
    var screenObserver: NSObjectProtocol?
    private var hoverTimer: Timer?
    private var hoverInterval: TimeInterval = 0
    private var hoverState = NotchHoverState()
    private var geometry: NotchGeometry?
    private var menuObservers: [NSObjectProtocol] = []
    private var menuTrackingDepth = 0
    private var previewWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private let loginItem = LoginItemService()
    private let settingsState = SettingsState()
    private let claudeState = ClaudeIntegrationState()
    private lazy var history = HistoryModel(usage: model)
    private lazy var pullRequests = PullRequestModel(usage: model, delivery: notifications)
    private lazy var sessions = ClaudeSessionModel(usage: model, delivery: notifications)
    private lazy var projects = ProjectModel(usage: model, tab: pullRequests.$tab.eraseToAnyPublisher())
    private lazy var terminal = TerminalModel(makeSession: TerminalSession.live,
                                              confirm: { [weak self] question, action in self?.confirm(question, action: action) ?? true },
                                              findProgram: { ProjectModel.liveProgram($0) },
                                              folderExists: ProjectModel.liveFolderExists)
    private lazy var reviews = CodeReviewModel(usage: model, pullRequests: pullRequests,
                                               projects: { [weak self] in self?.projects.settings ?? ProjectSettings() })
    private var terminalWindow: TerminalWindowController?
    private var terminalMenuItems: [NSMenuItem] = []
    private let notifications = NotificationService()
    private lazy var updates = UpdateService { [weak self] in
        guard let self else { return false }
        return self.model.presentation.isActive(at: self.model.tick)
    }
    private let hotKeys = HotKeyService()
    private lazy var shortcutRecorder = ShortcutRecorder(hotKeys: hotKeys)
    private var holdUntil: TimeInterval?
    private var bounceUntil: TimeInterval = 0
    private var layoutScreen: NSScreen?
    private var workspaceObservers: [NSObjectProtocol] = []
    /// The notch state to return to, so presentation mode does not overwrite
    /// a panel the user had already hidden themselves.
    private var notchVisibleBeforePresentation = true
    private var statusMenu: NSMenu!
    private var cancellables = Set<AnyCancellable>()
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        panel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.isOpaque = false; panel.backgroundColor = .clear
        // The shape draws its own shadow inside the fixed canvas. The canvas
        // is mostly transparent, so it takes the mouse only over the shape
        // (see updateHover).
        panel.level = .statusBar; panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        let hostingView = NSHostingView(rootView: NotchView(model: model, pullRequests: pullRequests, sessions: sessions,
                                                            projects: projects, reviews: reviews))
        hostingView.sizingOptions = []
        panel.contentView = hostingView
        model.onLayout = { [weak self] in self?.layout(resetHover: false) }
        model.onConnectClaude = { [weak self] in self?.claudeSetup() }
        model.onChooseCodex = { [weak self] in self?.chooseCodex() }
        model.onOpenGuide = { [weak self] in self?.guide() }
        model.onQuit = { [weak self] in self?.quit() }
        model.onPreview = { [weak self] in self?.preview() }
        model.onSettings = { [weak self] in self?.showSettings() }
        model.onPresentationChanged = { [weak self] in self?.applyPresentation() }
        model.onHistory = { [weak self] in self?.showHistory() }
        model.onUserOpen = { [weak self] in
            guard let self, !self.model.expanded else { return }
            self.hoverState.clearCloseUntilPointerLeaves()
            self.hapticTick()
            self.model.expand(true)
        }
        pullRequests.onSettings = { [weak self] in self?.showPullRequestSettings() }
        pullRequests.onChooseExecutable = { [weak self] forge in self?.chooseForgeCLI(forge) }
        projects.onSettings = { [weak self] in self?.showProjectSettings() }
        projects.onAddFolder = { [weak self] in self?.addProjectFolder() }
        projects.onChooseClaude = { [weak self] in self?.chooseClaude() }
        projects.onChooseTerminal = { [weak self] in self?.chooseTerminal() }
        projects.onStartInNocci = { [weak self] start, place in self?.terminal.start(start, place: place) }
        projects.onMoveToWindow = { [weak self] tab in self?.moveToWindow(tab) }
        // The Close question activates Nocci. Give activation back after it,
        // as a tuck does, so the keyboard returns to the user's app.
        projects.onCloseSession = { [weak self] tab in
            guard let self else { return true }
            let closed = self.terminal.close(tab)
            if NSApp.isActive, !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) { NSApp.deactivate() }
            return closed
        }
        projects.sessionView = { [weak self] tab in self?.terminal.session(for: tab)?.view }
        reviews.onStart = { [weak self] start in _ = self?.terminal.start(start) }
        reviews.onProblem = { [weak self] message in self?.reviewProblem(message) }
        terminal.onShow = { [weak self] in self?.showTerminal() }
        terminal.onActivationChange = { [weak self] active in self?.terminalActive(active) }
        terminal.onChooseFolder = { [weak self] in self?.chooseTerminalFolder() }
        model.onSummonTerminal = { [weak self] in self?.summonTerminal() }
        sessions.onSummon = { [weak self] tab in self?.openSessionTab(tab) }
        sessions.onClearWait = { [weak self] tab in self?.terminal.clearWait(tab) }
        sessions.hostedView = { [weak self] tab in self?.terminal.session(for: tab)?.miniView() }
        // @Published sends before the value changes, so the hosting value is
        // built from the values handed over, on the next turn of the main queue.
        Publishers.CombineLatest3(terminal.$tabs, terminal.$closedTabs, terminal.$waits)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tabs, closed, waits in
                self?.sessions.setHosting(ClaudeSessionHosting(
                    live: Set(tabs.filter { $0.start != nil }.map(\.id)), closed: closed,
                    waits: waits.map { HostedWait(tab: $0.tab, project: $0.label, since: $0.since) },
                    notch: Set(tabs.filter { $0.place == .notch }.map(\.id))))
            }
            .store(in: &cancellables)
        // Read back once each change has landed, so a start's own tab is never
        // missing from a value built before it.
        Publishers.Merge4(terminal.$tabs.map { _ in () }, terminal.$waits.map { _ in () },
                          terminal.$revision.map { _ in () }, sessions.$items.map { _ in () })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.publishNotchSessions() }
            .store(in: &cancellables)
        // A terminal that never ran its script leaves it behind; clear those.
        DispatchQueue.global(qos: .utility).async { ProjectLauncher().removeLeftovers() }
        // Setup in earlier versions left Nocci's own folders readable by others.
        DispatchQueue.global(qos: .utility).async { try? ClaudePaths.resolve().secureOwnFolders() }
        let keyboardInputs = Publishers.CombineLatest4(projects.$selected.map { $0 != nil }, sessions.$answering.map { $0 != nil },
                                                        projects.$showingTerminal, projects.$typing)
        let keyboardAndPanel = keyboardInputs.combineLatest(model.$expanded)
        let keyboardState: AnyPublisher<(accepts: Bool, takes: Bool, terminalOnly: Bool), Never> = keyboardAndPanel
            .map { (inputs: (Bool, Bool, Bool, Bool), expanded: Bool) -> (accepts: Bool, takes: Bool, terminalOnly: Bool) in
                let (composing, answering, showing, typing) = inputs
                return (accepts: composing || answering || (showing && expanded), takes: composing || answering || typing,
                        terminalOnly: showing && !composing && !answering && !typing)
            }
            .eraseToAnyPublisher()
        keyboardState
            .removeDuplicates { $0.accepts == $1.accepts && $0.takes == $1.takes && $0.terminalOnly == $1.terminalOnly }
            .sink { [weak self] in self?.setKeyboard(accepts: $0.accepts, takes: $0.takes, terminalOnly: $0.terminalOnly) }
            .store(in: &cancellables)
        // Switching tabs closes a mini view, as it ends compose.
        pullRequests.$tab.removeDuplicates().dropFirst()
            .sink { [weak self] _ in self?.sessions.endAnswer() }
            .store(in: &cancellables)
        // A tab switch, or a feature turned on or off, changes the shown
        // tab's height. @Published sends before the value changes, so the
        // layout runs on the next turn of the main queue.
        Publishers.Merge4(pullRequests.$tab.map { _ in () }, pullRequests.$settings.map { _ in () },
                          sessions.$status.map { _ in () }, projects.$settings.map { _ in () })
            .merge(with: projects.$showingTerminal.removeDuplicates().map { _ in () },
                   projects.$notchSessions.map(\.isEmpty).removeDuplicates().map { _ in () })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.layout(resetHover: false) }
            .store(in: &cancellables)
        sessions.$waitCount.dropFirst()
            .sink { [weak self] _ in self?.bounce() }
            .store(in: &cancellables)
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            workspaceObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.checkFullScreen()
                // The window list settles once the Space animation ends.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self?.checkFullScreen() }
            })
        }
        model.$tick.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.checkFullScreen() }
            .store(in: &cancellables)
        model.$preferences.map(\.hideInFullScreen).removeDuplicates().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.checkFullScreen() }
            .store(in: &cancellables)
        _ = history
        updates.start()
        model.attachDelivery(notifications)
        notifications.refresh()
        // A click holds the panel open on a deadline rather than pinning it,
        // so normal hover resumes afterwards. The tab it opens is kept, as a
        // click on that tab would be, but only while its feature is on: a
        // stale notification must not store a tab the panel cannot show.
        notifications.onOpenRequested = { [weak self] identifier in
            guard let self, self.panel.isVisible else { return }
            // A pull request or session notification opens the tab it is about.
            if let tab = PanelTab.opened(byNotification: identifier),
               PanelTab.available(pullRequests: self.pullRequests.settings.enabled, sessions: self.sessions.enabled,
                                  projects: self.projects.settings.enabled).contains(tab) {
                self.pullRequests.tab = tab
            }
            self.holdUntil = ProcessInfo.processInfo.systemUptime + 8
            self.model.expand(true)
        }
        hotKeys.onPress = { [weak self] action in
            switch action {
            case .glance: self?.glance()
            case .session: self?.goToWaitingSession()
            }
        }
        menuObservers = [
            NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                self?.menuTrackingDepth += 1
            },
            NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.menuTrackingDepth = max(0, self.menuTrackingDepth - 1)
                self.hoverState.reset()
            },
            // Clicking anywhere else ends composing, with the draft kept, and
            // closes a mini view.
            NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
                self?.projects.endCompose()
                self?.projects.endTyping()
                self?.sessions.endAnswer()
            },
            // A click inside a shown notch terminal made the panel key.
            NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: panel, queue: .main) { [weak self] _ in
                self?.projects.beganTyping()
            }
        ]
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "chart.bar.xaxis", accessibilityDescription: "Nocci")
        statusMenu = NSMenu()
        statusMenu.delegate = self
        populate(statusMenu)
        statusItem.menu = statusMenu
        installMainMenu()
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.layout() }
        model.start(demo: CommandLine.arguments.contains("--demo"))
        model.expanded = CommandLine.arguments.contains("--expanded")
        layout(); panel.orderFrontRegardless()
        applyPresentation()
        // NSEvent.mouseLocation works over the camera housing and across apps;
        // no global event tap or Accessibility permission is required.
        scheduleHover(HoverPolling.fast)
        // Whatever opens the panel (a shortcut, a notification, a click) puts
        // the poll back to full speed at once, not on its next slow tick.
        model.$expanded.removeDuplicates().filter { $0 }
            .sink { [weak self] _ in self?.scheduleHover(HoverPolling.fast) }
            .store(in: &cancellables)
        // A first launch shows nothing but an empty strip, so Settings opens
        // once on Providers, where Claude Code and Codex are connected. An
        // install from before this existed, which has something set up, and a
        // launch into Presentation Mode are left alone.
        if !model.demo, !UserDefaults.standard.bool(forKey: "app.welcomed") {
            UserDefaults.standard.set(true, forKey: "app.welcomed")
            let existing = model.claudeConnection.isConfigured || pullRequests.settings.enabled || sessions.enabled
                || projects.settings.enabled || UserDefaults.standard.string(forKey: "codexPath") != nil
            if !existing, !model.presentation.isActive(at: Date()) { claudeSetup() }
        }
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === statusMenu else { return }
        populate(menu)
    }

    func applicationWillTerminate(_ notification: Notification) {
        menuObservers.forEach { NotificationCenter.default.removeObserver($0) }
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        hoverTimer?.invalidate()
        model.timer?.invalidate()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        terminal.closeAllNow()
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        loginItem.refresh()
        // Cmd-Tab sends no reopen event; once this activation has settled, bring
        // back a tucked terminal unless another Nocci window took the keyboard.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.terminal.windowTabs.isEmpty, NSApp.keyWindow == nil,
                  self.terminalWindow?.placement == .hidden else { return }
            self.showTerminal()
        }
    }

    /// The Dock icon, while the terminal window has tabs.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !terminal.windowTabs.isEmpty else { return true }
        showTerminal()
        return false
    }

    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Nocci")
        let updateItem = NSMenuItem(title: updates.actionTitle, action: #selector(updateAction), keyEquivalent: "")
        updateItem.target = self
        appMenu.addItem(updateItem)
        appMenu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit Nocci", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        appMenu.addItem(quitItem)
        appItem.submenu = appMenu
        main.addItem(appItem)
        // Without these, Command-V and the other editing shortcuts do nothing
        // in the prompt field and in Settings' text fields.
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z").keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
    }

    @objc func showHistory() { history.show() }

    private func terminalController() -> TerminalWindowController {
        if let terminalWindow { return terminalWindow }
        let controller = TerminalWindowController(model: terminal, projects: projects, screen: layoutScreen)
        controller.onPlacementChange = { [weak self] placement in self?.model.terminalDropped = placement == .dropped }
        terminalWindow = controller
        return controller
    }

    private func showTerminal() { terminalController().show() }

    /// The notch button and Show Terminal / Hide Terminal in both menus. The
    /// panel closes, unless pinned, and stays closed until the pointer leaves
    /// the strip, so it never covers the dropped window.
    @objc func summonTerminal() {
        if !model.pinned { model.expand(false) }
        hoverState.closeUntilPointerLeaves()
        if terminal.windowTabs.isEmpty { terminal.newTab(show: false) }
        terminalController().summon(anchor: geometry?.compact, screen: layoutScreen)
    }

    /// A Nocci-hosted row: that tab, in the window dropped from the notch, or
    /// just brought forward when it already hangs there.
    private func summonTerminalTab(_ tab: UUID) {
        sessions.endAnswer()
        terminal.selection = tab
        if let controller = terminalWindow, controller.placement == .dropped {
            controller.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            summonTerminal()
        }
    }

    /// A Sessions row: a notch tab opens in the Projects tile with the
    /// keyboard, a window tab in the window.
    private func openSessionTab(_ tab: UUID) {
        guard terminal.tabs.first(where: { $0.id == tab })?.place == .notch else { return summonTerminalTab(tab) }
        sessions.endAnswer()
        pullRequests.tab = .projects
        projects.showTerminal(tab: tab)
    }

    /// Open in window, or a notch session whose project has left the list.
    /// The panel closes, as for a summon, so it never covers the window.
    private func moveToWindow(_ tab: UUID) {
        if !model.pinned { model.expand(false) }
        hoverState.closeUntilPointerLeaves()
        terminal.moveToWindow(tab)
    }

    /// The notch tabs by project folder, read from the terminal as it is now,
    /// each waiting on a Codex wait or a Sessions row carrying its tab.
    private func publishNotchSessions() {
        var notch: [String: NotchSession] = [:]
        for tab in terminal.tabs where tab.place == .notch {
            guard let start = tab.start else { continue }
            let waiting = terminal.waits.contains { $0.tab == tab.id } || sessions.items.contains { $0.record.tab == tab.id }
            notch[start.folder] = NotchSession(tab: tab.id, title: terminal.title(for: tab), waiting: waiting)
        }
        projects.setNotchSessions(notch)
    }

    /// Nocci has a Dock icon, Cmd-Tab and the terminal's menus only while the
    /// terminal has a tab.
    private func terminalActive(_ active: Bool) {
        model.terminalOpen = active
        NSApp.setActivationPolicy(active ? .regular : .accessory)
        setTerminalMenus(active)
        if !active { terminalWindow?.hide() }
    }

    private func setTerminalMenus(_ shown: Bool) {
        for item in terminalMenuItems { item.menu?.removeItem(item) }
        terminalMenuItems = []
        guard shown, let main = NSApp.mainMenu, let windowMenu = NSApp.windowsMenu else { return }
        func item(_ title: String, _ action: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.target = self
            return item
        }
        let shell = NSMenuItem()
        shell.submenu = NSMenu(title: "Shell")
        shell.submenu?.addItem(item("New Tab", #selector(newTerminalTab), "t"))
        let view = NSMenuItem()
        view.submenu = NSMenu(title: "View")
        view.submenu?.addItem(item("Bigger", #selector(biggerTerminalFont), "+"))
        view.submenu?.addItem(item("Smaller", #selector(smallerTerminalFont), "-"))
        view.submenu?.addItem(item("Actual Size", #selector(actualTerminalFont), "0"))
        main.insertItem(shell, at: 1)
        main.insertItem(view, at: 3)
        let next = item("Select Next Tab", #selector(nextTerminalTab), "]", [.command, .shift])
        let previous = item("Select Previous Tab", #selector(previousTerminalTab), "[", [.command, .shift])
        let separator = NSMenuItem.separator()
        windowMenu.addItem(separator)
        windowMenu.addItem(next)
        windowMenu.addItem(previous)
        terminalMenuItems = [shell, view, separator, next, previous]
    }

    @objc private func newTerminalTab() { terminal.newTab() }
    @objc private func biggerTerminalFont() { terminal.biggerFont() }
    @objc private func smallerTerminalFont() { terminal.smallerFont() }
    @objc private func actualTerminalFont() { terminal.actualSizeFont() }
    @objc private func nextTerminalTab() { terminal.selectNext() }
    @objc private func previousTerminalTab() { terminal.selectPrevious() }

    private func chooseTerminalFolder() {
        let picker = NSOpenPanel()
        picker.title = "Choose a folder for the session"
        picker.canChooseDirectories = true
        picker.canChooseFiles = false
        picker.allowsMultipleSelection = false
        guard picker.runModal() == .OK, let url = picker.url else { return }
        terminal.chooseDraft(folder: url.path, label: url.lastPathComponent)
    }

    /// Cancel is the default, so Return never ends a running session.
    private func confirm(_ question: String, action: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = question
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: action).hasDestructiveAction = true
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertSecondButtonReturn
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        terminal.canQuit() ? .terminateNow : .terminateCancel
    }
    @objc func showSettings() {
        loginItem.refresh()
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: SettingsMetrics.width, height: SettingsMetrics.windowHeight),
                                  styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = "Nocci Settings"
            window.isReleasedWhenClosed = false
            // The tabs are drawn in the title bar row. An empty unified toolbar
            // gives that row its 52 points with the traffic lights centred;
            // hosting the tabs in a toolbar item instead would put them inside
            // the system's glass container.
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.toolbar = NSToolbar(identifier: "settings")
            window.toolbarStyle = .unified
            // Always black, like the notch, so controls, sheets and alerts are dark too.
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = .black
            window.contentView = SettingsWindowContent(page: SettingsView(model: model, loginItem: loginItem,
                                                                          settingsState: settingsState,
                                                                          claudeState: claudeState,
                                                                          notifications: notifications,
                                                                          updates: updates,
                                                                          pullRequests: pullRequests,
                                                                          sessions: sessions,
                                                                          projects: projects,
                                                                          reviews: reviews,
                                                                          hotKeys: hotKeys,
                                                                          shortcutRecorder: shortcutRecorder),
                                                       tabs: SettingsTabBar(state: settingsState))
            // Adding the toolbar grew the window by its height; set it back.
            window.setContentSize(NSSize(width: SettingsMetrics.width, height: SettingsMetrics.windowHeight))
            window.center()
            settingsWindow = window
        }
        settingsWindow?.deminiaturize(nil)
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    /// Builds the menu each time it opens, so the remaining time and every
    /// checkmark stay honest.
    private func populate(_ menu: NSMenu) {
        menu.removeAllItems()
        let now = Date()
        let presenting = model.presentation.isActive(at: now)
        func add(_ title: String, _ action: Selector, _ key: String = "", on: Bool? = nil, enabled: Bool = true) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self
            item.isEnabled = enabled
            if let on { item.state = on ? .on : .off }
            menu.addItem(item)
        }
        add("Settings…", #selector(showSettings), ",")
        add("Usage History…", #selector(showHistory), enabled: !presenting)
        add(TerminalRules.summonTitle(dropped: model.terminalDropped), #selector(summonTerminal))
        menu.addItem(ProviderActions.shared.menuItem())
        menu.addItem(.separator())
        if presenting {
            add("End Presentation Mode", #selector(endPresentation))
            let status = NSMenuItem(title: model.presentation.menuDescription(at: now), action: nil, keyEquivalent: "")
            status.isEnabled = false
            menu.addItem(status)
        } else {
            let parent = NSMenuItem(title: "Presentation Mode", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for (title, minutes) in [("For 1 hour", 60), ("For 30 minutes", 30)] {
                let item = NSMenuItem(title: title, action: #selector(startTimedPresentation(_:)), keyEquivalent: "")
                item.target = self
                item.tag = minutes
                submenu.addItem(item)
            }
            let open = NSMenuItem(title: "Until I end it", action: #selector(startOpenPresentation), keyEquivalent: "")
            open.target = self
            submenu.addItem(open)
            parent.submenu = submenu
            menu.addItem(parent)
        }
        add("Show Notch", #selector(toggle), on: panel.isVisible)
        add("Keep Open", #selector(pin), on: model.pinned)
        add("Refresh Usage", #selector(refresh), "r")
        menu.addItem(.separator())
        add(model.claudeConnection.isConfigured ? "Claude Code Setup…" : "Connect Claude Code…", #selector(claudeSetup))
        add("Choose Codex Executable…", #selector(chooseCodex))
        add(updates.actionTitle, #selector(updateAction))
        add("Setup Guide", #selector(guide))
        menu.addItem(.separator())
        add("Show Sample Data", #selector(demo), on: model.demo)
        add("Preview Appearance…", #selector(preview), enabled: !presenting)
        menu.addItem(.separator())
        add("Quit Nocci", #selector(quit), "q")
    }

    @objc func startTimedPresentation(_ sender: NSMenuItem) {
        model.presentation = PresentationState(minutes: sender.tag, from: Date())
    }
    @objc func startOpenPresentation() { model.presentation = .untilEnded }
    @objc func endPresentation() { model.presentation = PresentationState() }

    /// Suppression is applied here and nowhere else, so the notch's own hidden
    /// and pinned state is never rewritten by it.
    private func applyPresentation() {
        let active = model.presentation.isActive(at: Date())
        statusItem.button?.image = NSImage(systemSymbolName: active ? "eye.slash" : "chart.bar.xaxis",
                                           accessibilityDescription: active ? "Nocci, presenting" : "Nocci")
        if active {
            projects.endCompose()
            projects.endTyping()
            sessions.endAnswer()
            notchVisibleBeforePresentation = panel.isVisible
            hoverState.reset()
            panel.orderOut(nil)
            history.hide()
            previewWindow?.orderOut(nil)
            // Only this app's own notifications are cleared.
            notifications.clearDelivered()
        } else if notchVisibleBeforePresentation, !panel.isVisible {
            panel.orderFrontRegardless()
            layout()
        }
        if !active { updates.presentationDidEnd() }
    }

    private func updateHover() {
        guard let geometry, menuTrackingDepth == 0, NSApp.modalWindow == nil else { return }
        let pointer = NSEvent.mouseLocation
        let visible = panel.isVisible && !model.fullScreenHidden
        let now = ProcessInfo.processInfo.systemUptime
        let held = holdUntil.map { now < $0 } ?? false
        if let expanded = hoverState.update(pointer: pointer,
                                             geometry: geometry,
                                             expanded: model.expanded,
                                             pinned: model.pinned,
                                             visible: visible,
                                             now: now,
                                             holdUntil: holdUntil,
                                             composing: projects.composing || sessions.answering != nil || projects.typing,
                                             openDelay: model.preferences.hoverOpen.delay) {
            // Only an open the pointer caused gets the tick; pinning, a
            // notification, composing and answering open the panel without one.
            if expanded && !model.pinned && !held && !projects.composing && sessions.answering == nil && !projects.typing { hapticTick() }
            model.expand(expanded)
        }
        let peeking = visible && !model.expanded && geometry.contains(pointer, expanded: false)
        if model.peeking != peeking { model.peeking = peeking }
        // The fixed window covers far more than the shape it draws. Take the
        // mouse only over the shape, so the menu bar and the windows under the
        // transparent part keep their clicks.
        let bouncing = !model.expanded && now < bounceUntil
        let ignore = !(visible && geometry.accepts(pointer, expanded: model.expanded, peeking: peeking,
                                                           bouncing: bouncing))
        if panel.ignoresMouseEvents != ignore { panel.ignoresMouseEvents = ignore }
        let busy = model.expanded || model.pinned || held || model.peeking || bouncing
            || projects.composing || sessions.answering != nil || projects.typing
        scheduleHover(HoverPolling.interval(pointer: pointer, canvas: geometry.canvas, visible: visible, busy: busy))
    }

    /// Replaces the poll's timer only when its rate changes, which happens as
    /// the pointer crosses the margin, not on every tick.
    private func scheduleHover(_ interval: TimeInterval) {
        guard interval != hoverInterval else { return }
        hoverTimer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.updateHover()
        }
        // The saving of the slow poll is in wakeups, not tolerance: a looser
        // slow timer would let a flick cross the margin before its next sample.
        timer.tolerance = 0.005
        RunLoop.main.add(timer, forMode: .common)
        hoverTimer = timer
        hoverInterval = interval
    }
    /// The Open the notch shortcut. It opens the notch with the same hold a
    /// notification click uses, so the ordinary hover rules take over once it
    /// lapses, or closes it, pin included, since the user asked. A notch that
    /// is hidden, presenting or out of the way of a full-screen app stays so.
    private func glance() {
        guard panel.isVisible, !model.fullScreenHidden else { return NSSound.beep() }
        if model.expanded {
            projects.endCompose()
            projects.endTyping()
            sessions.endAnswer()
            holdUntil = nil
            model.pinned = false
            model.expand(false)
            // Otherwise a pointer resting on the strip would open it again.
            hoverState.closeUntilPointerLeaves()
        } else {
            hoverState.clearCloseUntilPointerLeaves()
            holdUntil = ProcessInfo.processInfo.systemUptime + 8
            model.expand(true)
        }
    }

    /// The Go to the session shortcut: the first Sessions row, as if it were
    /// clicked. A session whose app is unknown opens the notch on the list
    /// instead; with nothing waiting, Sessions off, or sample rows showing
    /// (which have nowhere to go), it only beeps.
    private func goToWaitingSession() {
        guard sessions.enabled, !sessions.demo, !model.presentation.isActive(at: Date()), let first = sessions.items.first else {
            return NSSound.beep()
        }
        let notchVisible = panel.isVisible && !model.fullScreenHidden
        if sessions.isInNotch(first) && !notchVisible { return NSSound.beep() }
        if sessions.open(first) { return }
        guard notchVisible else { return NSSound.beep() }
        pullRequests.tab = .sessions
        hoverState.clearCloseUntilPointerLeaves()
        holdUntil = ProcessInfo.processInfo.systemUptime + 8
        model.expand(true)
    }

    /// A new wait nudges the collapsed strip once: never while open, never
    /// under Reduce Motion. Clicks are taken over the wider strip for as long
    /// as the spring takes to settle.
    private func bounce() {
        guard !model.expanded, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        bounceUntil = ProcessInfo.processInfo.systemUptime + 0.5
        model.bouncing = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.model.bouncing = false }
    }
    /// Steps the notch aside while a full-screen app owns its display, when
    /// the user asked for that. A separate flag, like presentation mode, so
    /// the user's own show/hide and pin are never rewritten.
    private func checkFullScreen() {
        var hide = false
        if model.preferences.hideInFullScreen, let screen = layoutScreen,
           let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            hide = FullScreenRule.covers(windows: WindowRecord.onScreen(),
                                         display: CGDisplayBounds(CGDirectDisplayID(number.uint32Value)),
                                         safeTop: screen.safeAreaInsets.top,
                                         ownPID: ProcessInfo.processInfo.processIdentifier)
        }
        guard hide != model.fullScreenHidden else { return }
        model.fullScreenHidden = hide
        hoverState.reset()
        if hide {
            projects.endCompose()
            projects.endTyping()
            sessions.endAnswer()
        }
    }
    /// Felt only on a Force Touch trackpad; harmless elsewhere.
    private func hapticTick() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
    /// Measures the notch and sets the panel to its fixed canvas. The frame
    /// changes only when the measurements do; opening and closing animate the
    /// shape inside it, never the window. `resetHover` is false when a
    /// measurement changes while the pointer may be over the panel.
    func layout(resetHover: Bool = true) {
        // Without a notch, the display with the menu bar (the first). NSScreen.main
        // follows keyboard focus, so the pill would jump to whichever display
        // holds the active window, even between opening and closing.
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.screens.first else { return }
        layoutScreen = screen
        let inset = screen.safeAreaInsets.top
        let style: NotchStyle = inset > 0 ? .notch : .floating
        model.floating = style == .floating
        if style == .notch {
            // One point past the measured inset. The half-point border stroke sits on
            // the shell's bottom edge, so at the bare inset the last half point reads
            // grey against the notch's black. Stays relative to the measured value, so
            // a Mac with a different notch still gets its own height.
            model.notchHeight = inset + 1
            if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
                model.notchWidth = max(140, right.minX - left.maxX)
            }
        } else {
            model.notchHeight = NotchMetrics.pillHeight(menuBar: screen.frame.maxY - screen.visibleFrame.maxY)
            model.notchWidth = 0
        }
        // A single visible provider puts its window label in the right wing, which
        // needs more room than a logo does.
        let captions = !(model.preferences.showClaude && model.preferences.showCodex)
        // Each tab has its own height; the canvas fits the tallest enabled
        // one, so switching tabs only animates the shape.
        let tabs = PanelTab.available(pullRequests: pullRequests.settings.enabled, sessions: sessions.enabled,
                                      projects: projects.settings.enabled)
        let shown = PanelTab.shown(stored: pullRequests.tab, available: tabs)
        let pace = model.preferences.showPace
        let above = style == .notch ? model.notchHeight
                                    : model.notchHeight + NotchMetrics.floatingGap + NotchMetrics.floatingHeaderHeight
        let terminalSlot = NotchMetrics.terminalSlot(screenHeight: screen.frame.height, above: above)
        if model.terminalSlot != terminalSlot { model.terminalSlot = terminalSlot }
        // While a notch session exists the canvas fits the terminal as well.
        let slots = NotchMetrics.slots(tabs: tabs.map { NotchMetrics.slotHeight(list: $0 != .usage, pace: pace) },
                                       shown: NotchMetrics.slotHeight(list: shown != .usage, pace: pace),
                                       terminal: projects.settings.enabled && !projects.notchSessions.isEmpty ? terminalSlot : nil,
                                       showingTerminal: shown == .projects && projects.showingTerminal)
        let geometry = NotchGeometry(screen: screen.frame, notchWidth: model.notchWidth,
                                     notchHeight: model.notchHeight,
                                     details: NotchMetrics.detailsHeight(slot: slots.shown),
                                     tallestDetails: NotchMetrics.detailsHeight(slot: slots.tallest),
                                     wingWidth: NotchMetrics.compactWing(caption: captions), style: style)
        self.geometry = geometry
        if resetHover { hoverState.reset() }
        if panel.frame != geometry.canvas { panel.setFrame(geometry.canvas, display: true) }
    }
    @objc func toggle() {
        hoverState.reset()
        if panel.isVisible {
            projects.endCompose()
            projects.endTyping()
            sessions.endAnswer()
            panel.orderOut(nil)
        } else {
            panel.orderFrontRegardless()
        }
    }
    @objc func pin() { model.pinned.toggle(); model.expand(model.pinned) }
    @objc func refresh() { model.refresh() }
    @objc func updateAction() { updates.performPrimaryAction() }
    @objc func demo() { model.toggleDemo() }
    /// Command-Q typed while the notch has the keyboard was meant for the app
    /// whose menu bar is showing; Nocci is not even the active app then.
    @objc func quit() {
        if let event = NSApp.currentEvent, event.type == .keyDown, event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers == "q", panel.isKeyWindow, !NSApp.isActive { return }
        NSApp.terminate(nil)
    }
    @objc func chooseCodex() {
        let picker = NSOpenPanel(); picker.title = "Choose the codex executable"; picker.canChooseDirectories = false
        // Codex ships inside Codex.app, so the picker must be able to look inside it.
        picker.treatsFilePackagesAsDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        if picker.runModal() == .OK, let url = picker.url {
            guard FileManager.default.isRunnableFile(atPath: url.path) else {
                return refuseNonExecutable(url, program: "codex", example: "/Applications/Codex.app/Contents/Resources/codex")
            }
            UserDefaults.standard.set(url.path, forKey: "codexPath"); model.codexConnectionChanged()
            reviews.checkProgram()
        }
    }
    /// A chosen file that cannot run is refused out loud rather than ignored.
    private func refuseNonExecutable(_ url: URL, program: String, example: String) {
        let alert = NSAlert()
        alert.messageText = "\(url.lastPathComponent) isn't an executable"
        alert.informativeText = "Choose the \(program) program itself, for example \(example)."
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
    /// A review that could not start. The modal pauses hover like every other
    /// alert. `finish` calls this from inside a `DispatchQueue.main.async`
    /// block, so the alert is deferred to a fresh run loop turn rather than
    /// run modally right there, or that block's caller would stall behind it.
    private func reviewProblem(_ message: String) {
        RunLoop.main.perform {
            let alert = NSAlert()
            alert.messageText = "Couldn't start the code review"
            alert.informativeText = message
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }
    @objc func showPullRequestSettings() {
        settingsState.tab = .pullRequests
        showSettings()
    }
    /// The panel takes the keyboard only while a prompt is written, a session
    /// is answered, or a notch terminal has it, and accepts the keyboard from
    /// a click inside the terminal while the open panel shows one. It stays
    /// non-activating, so the app the user was in remains the active app.
    private func setKeyboard(accepts: Bool, takes: Bool, terminalOnly: Bool) {
        panel.keyOnlyInTerminal = terminalOnly
        if takes {
            // A start's hand-over is over once the panel takes the keyboard
            // again; left set, it would keep the keyboard in the panel later.
            projects.endedByLaunch = false
            panel.acceptsKeyboard = true
            if !panel.isKeyWindow { panel.makeKey() }
        } else {
            let wasKey = panel.isKeyWindow
            panel.acceptsKeyboard = accepts
            // After a start the session's app is coming forward, and after a
            // row click or Open in window the terminal window is; handing the
            // keyboard back would put the old app over either.
            if wasKey && !projects.endedByLaunch && !(terminalWindow?.window.isKeyWindow ?? false) { handKeyboardBack() }
        }
    }
    /// Found by experiment: ordering the panel out makes the window server give
    /// keyboard focus back to the active app's window.
    private func handKeyboardBack() {
        panel.orderOut(nil)
        panel.orderFrontRegardless()
    }
    @objc func showProjectSettings() {
        settingsState.tab = .projects
        showSettings()
    }
    /// Several folders can be added at once; one already listed is named rather than added twice.
    func addProjectFolder() {
        let picker = NSOpenPanel()
        picker.title = "Choose folders that hold your projects"
        picker.prompt = "Add"
        picker.canChooseFiles = false
        picker.canChooseDirectories = true
        picker.allowsMultipleSelection = true
        NSApp.activate(ignoringOtherApps: true)
        guard picker.runModal() == .OK else { return }
        let repeated = picker.urls.filter { !projects.addFolder($0.path) }
        settingsState.projectFolderNotice = repeated.first.map {
            "\(ProjectRules.abbreviate($0.path, home: projects.home)) is already in the list."
        }
    }
    /// Same flow as Codex and the forge CLIs.
    func chooseClaude() {
        let picker = NSOpenPanel(); picker.title = "Choose the claude executable"; picker.canChooseDirectories = false
        NSApp.activate(ignoringOtherApps: true)
        if picker.runModal() == .OK, let url = picker.url {
            guard FileManager.default.isRunnableFile(atPath: url.path) else {
                return refuseNonExecutable(url, program: "claude", example: "~/.local/bin/claude")
            }
            projects.setClaudePath(url.path)
            reviews.checkProgram()
        }
    }
    func chooseTerminal() {
        let picker = NSOpenPanel()
        picker.title = "Choose a terminal app"
        picker.allowedContentTypes = [.application]
        picker.canChooseDirectories = false
        picker.directoryURL = URL(fileURLWithPath: "/Applications")
        NSApp.activate(ignoringOtherApps: true)
        if picker.runModal() == .OK, let url = picker.url {
            guard ProviderActionService.isApplicationBundle(url) else {
                let alert = NSAlert()
                alert.messageText = "\(url.lastPathComponent) isn't an app"
                alert.informativeText = "Choose a terminal app, for example Ghostty or Warp."
                alert.runModal()
                return
            }
            guard projects.setOtherTerminal(url.path) else {
                let alert = NSAlert()
                alert.messageText = "\(ProjectLauncher.liveAppName(url)) is already offered"
                alert.informativeText = "Nocci finds Terminal and iTerm2 by itself. Choose it from the Open in menu when you start a session."
                alert.runModal()
                return
            }
        }
    }
    /// Same flow as Codex. A new executable is a new connection for that forge.
    func chooseForgeCLI(_ forge: Forge) {
        let picker = NSOpenPanel(); picker.title = "Choose the \(forge.cli) executable"; picker.canChooseDirectories = false
        NSApp.activate(ignoringOtherApps: true)
        if picker.runModal() == .OK, let url = picker.url {
            guard FileManager.default.isRunnableFile(atPath: url.path) else {
                return refuseNonExecutable(url, program: forge.cli, example: "/opt/homebrew/bin/\(forge.cli)")
            }
            UserDefaults.standard.set(url.path, forKey: ForgeCLI.preferenceKey(forge))
            pullRequests.executableChanged(forge)
        }
    }
    @objc func preview() {
        if let previewWindow { previewWindow.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let sample = UsageModel(demo: true, sampleOnly: true)
        sample.expanded = true; sample.pinned = true
        sample.refresh()
        sample.onConnectClaude = model.onConnectClaude
        sample.onChooseCodex = model.onChooseCodex
        sample.onOpenGuide = model.onOpenGuide
        sample.onQuit = model.onQuit
        sample.onSettings = model.onSettings
        sample.onHistory = model.onHistory
        let samplePullRequests = PullRequestModel(usage: sample, saves: false)
        samplePullRequests.onSettings = pullRequests.onSettings
        let sampleSessions = ClaudeSessionModel(usage: sample, watch: false)
        let sampleProjects = ProjectModel(usage: sample, tab: samplePullRequests.$tab.eraseToAnyPublisher(), saves: false)
        let sampleReviews = CodeReviewModel(usage: sample, pullRequests: samplePullRequests, saves: false)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: NotchMetrics.expandedWidth, height: sample.notchHeight + max(NotchMetrics.detailsHeight(list: false, pace: sample.preferences.showPace),
                                 NotchMetrics.detailsHeight(list: true, pace: sample.preferences.showPace))), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Appearance Preview"
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        let host = NSHostingView(rootView: NotchView(model: sample, pullRequests: samplePullRequests, sessions: sampleSessions,
                                                     projects: sampleProjects, reviews: sampleReviews))
        host.sizingOptions = []
        window.contentView = host
        window.center(); window.makeKeyAndOrderFront(nil)
        previewWindow = window
        // The countdown and the elapsed mark read the model's tick, which only
        // the live model's refresh loop advances; the sample needs its own.
        sample.timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak sample, weak window] _ in
            guard let sample, window?.isVisible == true else { return }
            sample.tick = Date()
        }
        NSApp.activate(ignoringOtherApps: true)
    }
    /// A released build (one with an update feed) comes from the public
    /// repository, where the guide reads as a page; the bundled Markdown file
    /// would open in whatever app handles .md, often as raw text.
    @objc func guide() {
        if updates.configured, let page = URL(string: "https://github.com/amirabazi/Nocci/blob/main/GUIDE.md") {
            NSWorkspace.shared.open(page)
        } else if let url = Bundle.main.url(forResource: "GUIDE", withExtension: "md") {
            NSWorkspace.shared.open(url)
        }
    }
    @objc func claudeSetup() {
        // Setup is a native flow in Settings; nothing is written until the user
        // reviews the planned changes and chooses to enable them.
        settingsState.tab = .providers
        claudeState.refresh(snapshot: model.claudeSnapshot)
        showSettings()
    }
}

func selfTest() {
    func check(_ condition: @autoclosure () -> Bool, _ name: String) { if !condition() { fputs("FAIL: \(name)\n", stderr); exit(1) } }
    let expiry = Date().addingTimeInterval(5000).timeIntervalSince1970
    let codex = UsageParser.codex(["rateLimitsByLimitId": ["codex": ["primary": ["usedPercent": 31.0, "windowDurationMins": 300, "resetsAt": expiry]]]])
    check(codex.windows.first?.remaining == 69, "Codex percentage semantics")
    check(codex.windows.first?.label == "5-hour", "Window duration")
    check(UsageParser.codex(["rateLimitsByLimitId": ["other": ["primary": ["usedPercent": 99.0]]]]).windows.isEmpty, "Do not substitute another bucket")
    check(UsageParser.codex(["rateLimits": ["primary": ["usedPercent": 0.0]]]).windows.first?.used == 0, "Real zero")
    check(UsageParser.claude([:]).windows.isEmpty, "Missing is not zero")
    let claude = UsageParser.claude(["rate_limits": ["seven_day": ["used_percentage": 82.0, "resets_at": expiry]]])
    check(claude.windows.count == 1 && claude.windows[0].label == "Weekly", "Independent missing windows")
    check(!claude.windows[0].expired(at: Date()), "Future reset")
    check(UsageWindow(label: "x", used: 20, reset: Date(timeIntervalSince1970: 1)).expired(at: Date()), "Expired quota")
    check(UsageWindow(label: "x", used: 20, reset: nil).countdown(at: Date()) == "Reset unavailable", "Null reset")
    let clock = Date(timeIntervalSince1970: 1_800_000_000)
    func countdown(_ seconds: TimeInterval) -> String {
        UsageWindow(label: "x", used: 20, reset: clock.addingTimeInterval(seconds)).countdown(at: clock)
    }
    check(countdown(30) == "Resets in 1m" && countdown(61) == "Resets in 2m", "Minutes round up, never to zero")
    check(countdown(3 * 3600) == "Resets in 3h 0m" && countdown(2 * 86400 + 3 * 3600 + 59) == "Resets in 2d 3h",
          "Hours and days")
    check(countdown(0) == "Awaiting new window" && countdown(-5) == "Awaiting new window",
          "A passed reset waits for the new window at the given time, not the wall clock's")
    check(UsageParser.window(["usedPercent": 120.0], label: "x", kind: .session)?.used == 100, "Clamped bar")
    check(codex.windows.first?.kind == .session, "Codex primary is the session window")
    check(claude.windows[0].kind == .weekly, "Claude seven_day is the weekly window")
    check(CompactWindowChoice.automatic.window(in: claude.windows)?.kind == .weekly, "Automatic falls back to the weekly window")
    check(CompactWindowChoice.session.window(in: claude.windows) == nil, "An explicit selection never substitutes another quota")
    check(DisplayPreferences().percent(UsageWindow(label: "x", used: 38.5, reset: nil)) == 39
            && DisplayPreferences.load(from: UserDefaults(suiteName: "nocci-selftest")!).percentages == .used,
          "Percentage rendering and defaults")
    UserDefaults().removePersistentDomain(forName: "nocci-selftest")
    print("18 usage-model checks passed")
}

// Run by Claude Code hooks. It records the event before anything else and
// always exits quietly, whatever the input.
if CommandLine.arguments.contains("--claude-hook") {
    let now = Date()
    ClaudeSessionStore.receiveHook(input: ClaudeSessionStore.readInput(),
                                   environment: ProcessInfo.processInfo.environment, now: now)
    exit(0)
}
if CommandLine.arguments.contains("--self-test") { selfTest(); exit(0) }
if CommandLine.arguments.contains("--claude-statusline") {
    do { try Storage.receiveClaude() } catch { fputs("Nocci: unable to update local usage snapshot.\n", stderr); exit(1) }
    exit(0)
}
if CommandLine.arguments.contains("--check-codex") {
    do { let value = try CodexReader.read(); print(String(data: try JSONEncoder().encode(value), encoding: .utf8)!) } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
    exit(0)
}
if let index = CommandLine.arguments.firstIndex(of: "--render"), CommandLine.arguments.count > index + 1 {
    let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
    let model = UsageModel(demo: true); model.refresh(); model.expanded = true
    // --floating draws the pill and card; --tab picks the tab without saving it.
    if CommandLine.arguments.contains("--floating") { model.floating = true; model.notchHeight = 24; model.notchWidth = 0 }
    let pullRequests = PullRequestModel(usage: model, saves: false)
    if let tab = CommandLine.arguments.firstIndex(of: "--tab").flatMap({ CommandLine.arguments.indices.contains($0 + 1)
            ? PanelTab(rawValue: CommandLine.arguments[$0 + 1]) : nil }) {
        pullRequests.tab = tab
    }
    let view = NSHostingView(rootView: NotchView(model: model, pullRequests: pullRequests,
                                                 sessions: ClaudeSessionModel(usage: model, watch: false),
                                                 projects: ProjectModel(usage: model, tab: pullRequests.$tab.eraseToAnyPublisher(),
                                                                        saves: false),
                                                 reviews: CodeReviewModel(usage: model, pullRequests: pullRequests, saves: false)))
    view.frame = NSRect(x: 0, y: 0, width: NotchMetrics.expandedWidth, height: model.notchHeight + max(NotchMetrics.detailsHeight(list: false, pace: model.preferences.showPace),
                                 NotchMetrics.detailsHeight(list: true, pace: model.preferences.showPace))
                                 + (model.floating ? NotchMetrics.floatingGap + NotchMetrics.floatingHeaderHeight : 0))
    let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.backgroundColor = .clear; window.isOpaque = false; window.contentView = view
    view.layoutSubtreeIfNeeded()
    if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let png = bitmap.representation(using: .png, properties: [:]) { try png.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1])) }
    }
    exit(0)
}
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
