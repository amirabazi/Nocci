#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p .build/module-cache
SWIFTTERM="$(Scripts/build-swiftterm.sh)"
# A module built by another compiler cannot be imported, so the folder names the compiler.
[[ "$SWIFTTERM" =~ ^\.build/swiftterm/[0-9.]+-[a-z0-9_]+-[0-9a-f]{8}$ ]] || { echo "FAIL: SwiftTerm's build folder does not name the compiler" >&2; exit 1; }
swiftc -swift-version 5 -module-cache-path .build/module-cache Sources/Hover.swift Tests/HoverTests.swift -o .build/hover-tests
.build/hover-tests
swiftc -swift-version 5 -module-cache-path .build/module-cache Sources/FullScreen.swift Tests/FullScreenTests.swift -o .build/full-screen-tests
.build/full-screen-tests
swiftc -swift-version 5 -module-cache-path .build/module-cache Sources/Freshness.swift Tests/FreshnessTests.swift -o .build/freshness-tests
.build/freshness-tests
swiftc -swift-version 5 -module-cache-path .build/module-cache Sources/Freshness.swift Sources/Usage.swift Sources/Diagnostics.swift Tests/DiagnosticsTests.swift -o .build/diagnostics-tests
.build/diagnostics-tests
swiftc -swift-version 5 -module-cache-path .build/module-cache Sources/Freshness.swift Sources/Pace.swift Tests/PaceTests.swift -o .build/pace-tests
.build/pace-tests
swiftc -swift-version 5 -module-cache-path .build/module-cache Sources/Presentation.swift Tests/PresentationTests.swift -o .build/presentation-tests
.build/presentation-tests
swiftc -swift-version 5 -module-cache-path .build/module-cache Sources/UpdatePolicy.swift Tests/UpdatePolicyTests.swift -o .build/update-policy-tests
.build/update-policy-tests
swiftc -swift-version 5 -module-cache-path .build/module-cache Sources/Shortcuts.swift Sources/HotKeyService.swift Tests/ShortcutTests.swift -o .build/shortcut-tests
.build/shortcut-tests
swiftc -swift-version 5 -module-cache-path .build/module-cache Sources/Freshness.swift Sources/Usage.swift Sources/Alerts.swift Tests/AlertTests.swift -o .build/alert-tests
.build/alert-tests
swiftc -swift-version 5 -module-cache-path .build/module-cache Sources/Freshness.swift Sources/Usage.swift Sources/Alerts.swift Sources/Pace.swift Sources/Presentation.swift Sources/ClaudeIntegration.swift Sources/UsageModel.swift Tests/UsageModelTests.swift -o .build/usage-model-tests
.build/usage-model-tests
swiftc -swift-version 5 -module-cache-path .build/module-cache Sources/Freshness.swift Sources/ClaudeIntegration.swift Tests/ClaudeIntegrationTests.swift -o .build/claude-integration-tests
.build/claude-integration-tests
swiftc -swift-version 5 -module-cache-path .build/module-cache Sources/LoginItemService.swift Tests/LoginItemTests.swift -framework ServiceManagement -o .build/login-item-tests
.build/login-item-tests
swiftc -swift-version 5 -module-cache-path .build/module-cache Sources/ProviderActions.swift Tests/ProviderActionsTests.swift -framework AppKit -framework SwiftUI -o .build/provider-actions-tests
.build/provider-actions-tests
swiftc -swift-version 5 -module-cache-path .build/module-cache Sources/PullRequests.swift Tests/PullRequestTests.swift -o .build/pull-request-tests
.build/pull-request-tests
swiftc -swift-version 5 -module-cache-path .build/module-cache Sources/Freshness.swift Sources/Usage.swift Sources/PullRequests.swift Sources/PullRequestReader.swift Tests/PullRequestReaderTests.swift -o .build/pull-request-reader-tests
.build/pull-request-reader-tests
swiftc -swift-version 5 -module-cache-path .build/module-cache Sources/Freshness.swift Sources/Usage.swift Sources/Alerts.swift Sources/Pace.swift Sources/Presentation.swift Sources/ClaudeIntegration.swift Sources/UsageModel.swift Sources/PullRequests.swift Sources/PullRequestReader.swift Sources/PullRequestModel.swift Sources/PullRequestEvents.swift Tests/PullRequestModelTests.swift -framework AppKit -o .build/pull-request-model-tests
.build/pull-request-model-tests
swiftc -swift-version 5 -module-cache-path .build/module-cache Sources/ClaudeSessions.swift Tests/ClaudeSessionsTests.swift -o .build/claude-sessions-tests
.build/claude-sessions-tests
swiftc -swift-version 5 -module-cache-path .build/module-cache Sources/Freshness.swift Sources/Usage.swift Sources/ClaudeSessions.swift Sources/ClaudeSessionStore.swift Tests/ClaudeSessionStoreTests.swift -o .build/claude-session-store-tests
.build/claude-session-store-tests
swiftc -swift-version 5 -module-cache-path .build/module-cache Sources/Freshness.swift Sources/ClaudeIntegration.swift Sources/ClaudeHooks.swift Tests/ClaudeHooksTests.swift -o .build/claude-hooks-tests
.build/claude-hooks-tests
swiftc -swift-version 5 -module-cache-path .build/module-cache Sources/Freshness.swift Sources/Usage.swift Sources/Alerts.swift Sources/Pace.swift Sources/Presentation.swift Sources/ClaudeIntegration.swift Sources/UsageModel.swift Sources/ClaudeSessions.swift Sources/ClaudeSessionStore.swift Sources/ClaudeHooks.swift Sources/ClaudeSessionModel.swift Tests/ClaudeSessionModelTests.swift -framework AppKit -o .build/claude-session-model-tests
.build/claude-session-model-tests
swiftc -swift-version 5 -module-cache-path .build/module-cache Sources/Freshness.swift Sources/ClaudeIntegration.swift Sources/Projects.swift Tests/ProjectsTests.swift -o .build/projects-tests
.build/projects-tests
swiftc -swift-version 5 -module-cache-path .build/module-cache Sources/Freshness.swift Sources/ClaudeIntegration.swift Sources/Projects.swift Sources/ProjectScanner.swift Tests/ProjectScannerTests.swift -o .build/project-scanner-tests
.build/project-scanner-tests
swiftc -swift-version 5 -module-cache-path .build/module-cache Sources/Freshness.swift Sources/Usage.swift Sources/ClaudeIntegration.swift Sources/ProviderActions.swift Sources/Projects.swift Sources/ProjectLauncher.swift Tests/ProjectLauncherTests.swift -framework AppKit -framework SwiftUI -o .build/project-launcher-tests
.build/project-launcher-tests
swiftc -swift-version 5 -module-cache-path .build/module-cache Sources/Freshness.swift Sources/Usage.swift Sources/Alerts.swift Sources/Pace.swift Sources/Presentation.swift Sources/ClaudeIntegration.swift Sources/UsageModel.swift Sources/PullRequests.swift Sources/PullRequestReader.swift Sources/PullRequestModel.swift Sources/PullRequestEvents.swift Sources/ProviderActions.swift Sources/Projects.swift Sources/ProjectScanner.swift Sources/ProjectLauncher.swift Sources/ProjectModel.swift Sources/Terminals.swift Tests/ProjectModelTests.swift -framework AppKit -framework SwiftUI -o .build/project-model-tests
.build/project-model-tests
swiftc -swift-version 5 -module-cache-path .build/module-cache Sources/Freshness.swift Sources/ClaudeIntegration.swift Sources/Projects.swift Sources/Terminals.swift Tests/TerminalsTests.swift -o .build/terminals-tests
.build/terminals-tests
swiftc -swift-version 5 -module-cache-path .build/module-cache Sources/Freshness.swift Sources/ClaudeIntegration.swift Sources/Projects.swift Sources/Terminals.swift Sources/TerminalModel.swift Tests/TerminalModelTests.swift -framework AppKit -o .build/terminal-model-tests
.build/terminal-model-tests
swiftc -swift-version 5 -module-cache-path .build/module-cache -I "$SWIFTTERM" -L "$SWIFTTERM" -lSwiftTerm Sources/Freshness.swift Sources/Usage.swift Sources/ClaudeIntegration.swift Sources/Projects.swift Sources/Terminals.swift Sources/TerminalModel.swift Sources/TerminalSession.swift Sources/TerminalMiniView.swift Tests/TerminalSessionTests.swift -framework AppKit -o .build/terminal-session-tests
.build/terminal-session-tests
swiftc -swift-version 5 -module-cache-path .build/module-cache Sources/Freshness.swift Sources/ClaudeIntegration.swift Sources/Projects.swift Sources/PullRequests.swift Sources/CodeReview.swift Tests/CodeReviewTests.swift -o .build/code-review-tests
.build/code-review-tests
swiftc -swift-version 5 -module-cache-path .build/module-cache Sources/Freshness.swift Sources/Usage.swift Sources/Alerts.swift Sources/Pace.swift Sources/Presentation.swift Sources/ClaudeIntegration.swift Sources/UsageModel.swift Sources/PullRequests.swift Sources/PullRequestReader.swift Sources/PullRequestModel.swift Sources/PullRequestEvents.swift Sources/ProviderActions.swift Sources/Projects.swift Sources/ProjectScanner.swift Sources/ProjectLauncher.swift Sources/ProjectModel.swift Sources/Terminals.swift Sources/CodeReview.swift Sources/CodeReviewModel.swift Tests/CodeReviewReaderTests.swift -framework AppKit -framework SwiftUI -o .build/code-review-reader-tests
.build/code-review-reader-tests
swiftc -swift-version 5 -module-cache-path .build/module-cache Sources/Freshness.swift Sources/Usage.swift Sources/Alerts.swift Sources/Pace.swift Sources/Presentation.swift Sources/ClaudeIntegration.swift Sources/UsageModel.swift Sources/PullRequests.swift Sources/PullRequestReader.swift Sources/PullRequestModel.swift Sources/PullRequestEvents.swift Sources/ProviderActions.swift Sources/Projects.swift Sources/ProjectScanner.swift Sources/ProjectLauncher.swift Sources/ProjectModel.swift Sources/Terminals.swift Sources/CodeReview.swift Sources/CodeReviewModel.swift Tests/CodeReviewModelTests.swift -framework AppKit -framework SwiftUI -o .build/code-review-model-tests
.build/code-review-model-tests
swiftc -swift-version 5 -O -module-cache-path .build/module-cache Sources/Freshness.swift Sources/Usage.swift Sources/Alerts.swift Sources/Pace.swift Sources/Presentation.swift Sources/ClaudeIntegration.swift Sources/UsageModel.swift Sources/HistoryStore.swift Sources/HistoryView.swift Tests/HistoryTests.swift -framework AppKit -framework SwiftUI -framework Charts -lsqlite3 -o .build/history-tests
.build/history-tests
'../Nocci.app/Contents/MacOS/Nocci' --self-test
python3 Tests/integration.py
