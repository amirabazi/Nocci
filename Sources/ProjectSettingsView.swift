import SwiftUI

/// Settings › Projects. No folder is read until the feature is on.
struct ProjectSettingsForm: View {
    @ObservedObject var model: ProjectModel
    @ObservedObject var settingsState: SettingsState

    var body: some View {
        SettingsPage {
            SettingsTile("Projects", glyph: .symbol("folder"),
                         footer: "Adds a Projects tab to the expanded notch listing the folders inside the folders you choose. Pick one to start a Claude Code or Codex session there, with an optional first prompt. Nocci saves only these settings and never runs an AI model itself.") {
                SettingsToggle("Show projects in the notch", isOn: $model.settings.enabled)
            }
            SettingsTile("Folders", glyph: .symbol("folder.badge.plus"),
                         footer: "Each folder inside these is a project. A folder that holds git repositories lists those repositories instead.") {
                ForEach(model.settings.folders, id: \.self) { folder in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ProjectRules.abbreviate(folder, home: model.home))
                            if model.folderStates[folder] == .notAvailable {
                                Text("Not available").font(.callout).foregroundStyle(.orange)
                            }
                        }
                        Spacer()
                        Button {
                            model.removeFolder(folder)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove \(ProjectRules.abbreviate(folder, home: model.home))")
                        .accessibilityLabel("Remove \(ProjectRules.abbreviate(folder, home: model.home))")
                    }
                    Hairline()
                }
                Button("Add Folder…") { model.onAddFolder?() }
                if let notice = settingsState.projectFolderNotice {
                    Text(notice).font(.callout).foregroundStyle(.red)
                }
            }
            SettingsTile("Programs", glyph: .symbol("chevron.left.forwardslash.chevron.right"),
                         footer: "Used when a session opens in a terminal. VS Code and the Codex app bring their own.") {
                SettingsValue("Claude Code", model.claudePath.map { ProjectRules.abbreviate($0, home: model.home) } ?? "Not found")
                Button("Choose claude Executable…") { model.onChooseClaude?() }
                if ProcessInfo.processInfo.environment[ClaudeProgram.overrideKey] != nil {
                    Text("An environment override controls this executable for the current launch.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Hairline()
                SettingsValue("Codex", model.codexPath.map { ProjectRules.abbreviate($0, home: model.home) } ?? "Not found")
                Text("Change the Codex executable in Settings › Providers.").font(.callout).foregroundStyle(.secondary)
            }
            SettingsTile("Terminal", glyph: .symbol("terminal"),
                         footer: "Terminal and iTerm2 are found automatically. Choose another terminal app, such as Ghostty or Warp, to offer it too.") {
                SettingsValue("Other terminal", model.targetNames[.otherTerminal] ?? "None", path: false)
                HStack {
                    Button("Choose Terminal App…") { model.onChooseTerminal?() }
                    if model.installed.contains(.otherTerminal) {
                        Button("Remove") { model.clearOtherTerminal() }
                    }
                }
            }
        }
        .onAppear { model.refreshAvailability() }
    }
}
