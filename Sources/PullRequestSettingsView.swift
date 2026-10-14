import SwiftUI

/// Settings › Pull Requests. Account status is checked when the tab appears
/// and after a change here, never on a timer, and only while the feature is on.
struct PullRequestSettingsForm: View {
    @ObservedObject var model: PullRequestModel
    @ObservedObject var reviews: CodeReviewModel
    @ObservedObject var settingsState: SettingsState
    @ObservedObject var notifications: NotificationService

    var body: some View {
        SettingsPage {
            SettingsTile("Pull Requests", glyph: .symbol("arrow.triangle.pull"),
                         footer: "Adds a Pull Requests tab to the expanded notch with the open pull requests and merge requests you opened, are assigned to, or were asked to review directly. Nocci asks gh and glab every two minutes, never sees your tokens, and saves only these settings.") {
                SettingsToggle("Show pull requests in the notch", isOn: $model.settings.enabled)
            }
            if model.settings.enabled {
                SettingsTile("Notifications", glyph: .symbol("bell.badge"),
                             footer: "A notification names only the repository and number, never the title. What is already open when Nocci starts, or when a host is added, is never announced. Nothing is sent in Presentation Mode, and the sound follows Settings › Alerts.") {
                    SettingsToggle("When someone asks for my review", isOn: notifyBinding(\.reviews))
                    Hairline()
                    SettingsToggle("When checks pass or fail on my pull requests", isOn: notifyBinding(\.checks))
                    if (model.notify.reviews || model.notify.checks) && notifications.status == .denied {
                        Text(notifications.statusMessage).font(.callout).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Open Notification Settings…") { notifications.openSystemSettings() }
                    }
                }
            }
            SettingsTile("GitHub", glyph: .mark("github"),
                         footer: "Sign in with gh auth login in Terminal. Private and organisation repositories need a token that can read them.") {
                SettingsToggle("github.com", isOn: $model.settings.github)
                if model.settings.enabled, model.settings.github { status(.github) }
                Hairline()
                executable(.github)
            }
            SettingsTile("GitLab", glyph: .mark("gitlab"),
                         footer: "Add each GitLab host you use, such as gitlab.com, then sign in with glab auth login --hostname followed by that host in Terminal.") {
                ForEach(model.settings.gitlabHosts, id: \.self) { host in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(host)
                            if model.settings.enabled { status(PullRequestTarget(forge: .gitlab, host: host)) }
                        }
                        Spacer()
                        Button {
                            model.settings.gitlabHosts.removeAll { $0 == host }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove \(host)")
                        .accessibilityLabel("Remove \(host)")
                    }
                    Hairline()
                }
                HStack {
                    TextField("GitLab host", text: $settingsState.gitlabHostDraft, prompt: Text("gitlab.example.com"))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addHost)
                        .accessibilityLabel("GitLab host")
                    Button("Add", action: addHost).disabled(!canAdd)
                }
                if !settingsState.gitlabHostDraft.isEmpty {
                    if let host = GitLabHost.normalize(settingsState.gitlabHostDraft) {
                        if model.settings.gitlabHosts.contains(host) {
                            Text("\(host) is already in the list.")
                                .font(.callout).foregroundStyle(.red)
                        }
                    } else {
                        Text("Enter a host name such as gitlab.example.com.")
                            .font(.callout).foregroundStyle(.red)
                    }
                }
                Hairline()
                executable(.gitlab)
            }
            if model.settings.enabled {
                SettingsTile("Code Review", glyph: .symbol("text.magnifyingglass"),
                             footer: "Experimental: not yet tried widely. Each pull request row gets a Code Review button. While Projects is on, it opens a Nocci terminal tab in your clone of that repository when your Projects folders hold one, otherwise in Nocci's review folder, and starts the agent on this prompt with whichever placeholders it uses filled in from that row. Placeholders: \(CodeReviewRules.placeholders.map { "{\($0)}" }.joined(separator: " ")). An empty prompt uses the default.") {
                    SettingsRow("Agent") {
                        Picker("Agent", selection: $reviews.settings.agent) {
                            ForEach(ProjectAgent.allCases) { agent in Text(agent.title).tag(agent) }
                        }
                        .pickerStyle(.segmented)
                    }
                    Hairline()
                    TextEditor(text: $reviews.settings.prompt)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .frame(height: 96)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(0.06)))
                        .accessibilityLabel("Review prompt")
                    Button("Reset to Default") { reviews.settings.prompt = ReviewSettings.defaultPrompt }
                        .disabled(reviews.settings.prompt == ReviewSettings.defaultPrompt)
                }
            }
        }
        .onAppear { model.checkAccounts() }
    }

    @ViewBuilder private func status(_ target: PullRequestTarget) -> some View {
        switch model.accounts[target] {
        case .checking?:
            Text("Checking…").font(.callout).foregroundStyle(.secondary)
        case .signedIn(let name)?:
            Text("Signed in as \(name)").font(.callout).foregroundStyle(.secondary)
        case .failed(let failure)?:
            Text(failure.message(for: target)).font(.callout).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        case nil:
            EmptyView()
        }
    }

    @ViewBuilder private func executable(_ forge: Forge) -> some View {
        SettingsValue("Executable", model.executables[forge] ?? "Not found")
        Button("Choose \(forge.cli) Executable…") { model.onChooseExecutable?(forge) }
        if ProcessInfo.processInfo.environment[ForgeCLI.overrideKey(forge)] != nil {
            Text("An environment override controls this executable for the current launch.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    /// Permission is asked for only when a switch is turned on.
    private func notifyBinding(_ key: WritableKeyPath<PullRequestNotifications, Bool>) -> Binding<Bool> {
        Binding(get: { model.notify[keyPath: key] }, set: { value in
            model.notify[keyPath: key] = value
            if value { notifications.requestAuthorization() }
        })
    }

    private var canAdd: Bool {
        guard let host = GitLabHost.normalize(settingsState.gitlabHostDraft) else { return false }
        return !model.settings.gitlabHosts.contains(host)
    }

    private func addHost() {
        var settings = model.settings
        guard settings.addGitLabHost(settingsState.gitlabHostDraft) else { return }
        model.settings = settings
        settingsState.gitlabHostDraft = ""
    }
}
