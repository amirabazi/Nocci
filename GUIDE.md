# Nocci setup guide

Nocci puts your Claude and Codex subscription usage beside the MacBook camera notch, and can list your pull requests, tell you when a Claude Code session needs you, and start coding agents in your projects. This guide covers installing it, connecting your accounts, and every feature. Everything except usage is off until you turn it on.

## Quick start

1. **Install.** Download the ZIP from [Releases](https://github.com/amirabazi/Nocci/releases), unzip it and drag **Nocci.app** into **Applications**. Open it from there; the first launch needs one approval in System Settings (see [Install](#install)).
2. **Claude.** Nocci opens **Settings › Providers** the first time. Choose **Enable Usage Tracking…**, read what it will change, and confirm. Your Claude usage appears after Claude Code next answers in a terminal session (Pro or Max plan, Claude Code 2.1.251 or later). The VS Code extension does not send usage; see [Claude shows a dash](#claude-shows-a-dash).
3. **Codex.** If you use Codex, sign in once with `codex login` in Terminal. Nocci finds the Codex app or CLI by itself; if it does not, choose it with **Set Up Codex…** on the Codex card. If you don't use Codex, hide it in **Settings › Appearance**.
4. **Hover the notch** to see your limits. Right-click it, or use the chart icon in the menu bar, for everything else.
5. **Optional:** turn on **Pull Requests**, **Sessions** or **Projects** in Settings when you want them. Each has its own section below.

Nocci has no server and no telemetry. Each person connects their own accounts; nothing leaves your Mac except what your own `claude`, `codex`, `gh` and `glab` send, and the update check.

## Install

### Download the app

1. Open [Releases](https://github.com/amirabazi/Nocci/releases).
2. Download the ZIP whose name ends in `macos-arm64.zip`, for an Apple Silicon Mac (M1 or newer).
3. Unzip it and drag **Nocci.app** into **Applications** before you open it. Opened straight from Downloads, macOS runs a temporary copy, and Nocci refuses to connect Claude Code from one, because that path disappears.
4. Open the app and connect your providers using the instructions below.

#### The first launch will be blocked, and that is expected

Nocci is not signed with an Apple Developer ID and is not notarized, so macOS will
refuse to open it the first time and say it cannot verify the developer. This is Gatekeeper
reacting to the absence of a paid Apple certificate, not to anything detected in the app.
To open it:

1. Try to open **Nocci.app** once and choose **Done** on the warning (not Move to Trash).
2. Open **System Settings > Privacy & Security** and scroll to **Security**.
3. Click **Open Anyway** next to the message about Nocci, confirm, and enter your password if asked.

You only do this once per installed copy. If you prefer not to bypass Gatekeeper, build
from source instead; a build you compile yourself runs without the warning.

The app is compiled with a macOS 13 minimum, but has only been runtime-tested on the
developer's newer Apple Silicon Mac. Intel Macs should build from source; an Intel release
has not been tested.

#### Updating

On its second launch Nocci asks whether it may check for updates automatically. When a new
version exists it shows what changed and installs it only after you approve. Replacing the
app by hand does not affect your settings, history or provider connections. See
[Updates](#updates).

### Build from source

Install Apple's Xcode Command Line Tools (`xcode-select --install`) if needed, then:

```bash
git clone https://github.com/amirabazi/Nocci.git
cd Nocci
./build.sh
open '../Nocci.app'
```

The first build downloads Sparkle and SwiftTerm, the app's two third-party dependencies, so it needs network access; later builds reuse the cached copies. The build produces an app for your Mac's processor architecture and writes it next to the clone, as `../Nocci.app`; set `NOCCI_APP_OUTPUT` to put it somewhere else. After building, run `./test.sh` to check the implementation (requires Python 3). It runs the app it finds at `../Nocci.app`.

## Connect Claude Code

Open **Settings › Providers** (or choose **Connect Claude Code…** from any menu) and select **Enable Usage Tracking…**.

Before anything is written, Nocci shows you the exact changes:

- the settings file it will edit: `~/.claude/settings.json`, or `$CLAUDE_CONFIG_DIR/settings.json` if Nocci itself sees that variable. An app opened from Finder does not read your shell's startup files, so a `CLAUDE_CONFIG_DIR` set only in `.zshrc` is not seen; set it with `launchctl setenv` or keep the default folder. If `settings.json` is a link, as dotfile managers make it, Nocci writes to the file it points to.
- the `statusLine` entry it will merge, leaving every other setting exactly as it is
- where it saves a backup of your current settings first, kept until you disconnect
- your existing status line, if you have one, and how it is kept
- anything that could stop Claude Code from running the status line

Choosing **Enable Usage Tracking** backs up your settings file, writes a small bridge script called `nocci-statusline.sh` next to it, and points `statusLine` at that script. Claude Code reloads settings on save, so the next status-line update runs the bridge. Nothing else in your settings is touched, and the app never reads or stores prompts, transcripts, session identifiers, or credentials.

**An existing status line keeps working.** The bridge sends the status-line payload to Nocci, then runs your previous command with the same payload and prints its output, so what you see in Claude Code stays the same. Your command is copied into the bridge exactly as you wrote it and is never executed during setup. Paths with spaces and quotes are handled.

**Setup is repeatable.** Pressing Enable again never nests bridges, never replaces the original backup, and rewrites the bridge if you move the app.

**Status is honest about what it knows:**

| Status | Meaning |
| --- | --- |
| Not connected | No configuration has been installed. |
| Configured, waiting for Claude Code | The status line is installed. No usage has arrived yet. |
| Connected, no usage limits reported yet | Claude Code ran the bridge but sent no `rate_limits`. |
| Receiving usage | Usage has arrived since setup. |
| Status line changed outside Nocci | Something else now owns your status line. Nothing is overwritten. |
| Nocci has moved | The status line still runs Nocci from its old place. Review Setup and choose Update Setup. |

Installing configuration never claims a live connection on its own.

**Disconnect** restores your previous status line, or removes the `statusLine` entry if you did not have one, and deletes the bridge script and any backup Nocci made of your settings. Settings you changed after setup are preserved. If your status line was replaced by something else in the meantime, Nocci does not overwrite it: it reports the conflict and lets you keep the current status line or put back the one you had before setup.

If setup cannot be done safely, nothing is written. That covers a settings file that is not valid JSON (including a trailing comma, which Claude Code also rejects), a `statusLine` this app cannot extend, a settings directory it cannot write to, a missing app executable, and a temporary copy of Nocci (opened from Downloads or a disk image).

`rate_limits` reaches the status line only for claude.ai Pro and Max subscriptions, or behind a Claude apps gateway with spend limits, and only after the first response in a session. Either window can be absent, and Claude Code drops a window once its reset time passes. Readings update when Claude Code sends status-line events, not by polling Claude's website; usage from the Claude desktop or web app does not refresh this snapshot. Model-specific limits, spend limits, and extra usage are not shown.

**Settings in a project can override yours.** Claude Code reads `statusLine` from `.claude/settings.local.json` and `.claude/settings.json` in a project before your user settings, and managed settings override everything. In a project that sets its own status line, usage will not update until that project's configuration also runs this bridge. `disableAllHooks` in your own settings, and `allowManagedHooksOnly` in managed settings, stop a user status line from running at all; the review sheet reports both when it finds them.

**How often usage updates.** Claude Code runs the status line on events, mainly when an assistant message arrives. A terminal session does that every few seconds while you work. The VSCode extension does not run status lines at all, so Nocci receives nothing while you work only there; open Claude Code in a terminal to see your Claude usage. Setup therefore also asks Claude Code to re-run the bridge every 60 seconds with `refreshInterval`, unless you already set your own value. That timer drives the same terminal status line, so it does not help in the extension either. The compact strip keeps readings older than five minutes visible in orange until the quota window expires; hover the percentage to see its original timestamp. Starting a new Claude Code session sends an event with no usage in it; the app keeps your last percentages in that case rather than clearing them, and still shows when they were read.

The usage-only snapshot is written atomically to `~/Library/Application Support/Nocci/claude.json` with owner-only permissions. The backup and the record of what was installed live beside it, in `backups/` and `claude-integration.json`, until you disconnect. Only you can open that folder. Moving the app later requires opening setup again so the bridge points at the new location.

## Connect Codex

The app finds Codex in standard locations: the Codex or ChatGPT app, Homebrew, `~/.local/bin`, an npm prefix in `~/.npm-global` and Volta. Choose a custom executable with **Set Up Codex…** or **Choose Codex Executable…** if needed; the picker can look inside an app. Sign into that CLI with your ChatGPT subscription first (`codex login`). A standalone CLI may not share the desktop app's sign-in. It calls `account/rateLimits/read` over the official `codex app-server` stdio interface every 60 seconds, with a 15-second timeout. It never starts a model turn, consumes a reset credit, or reads credentials itself. Codex handles its own authentication and network requests.

Only the `codex` bucket is shown when the server provides multiple buckets; other model/product buckets are not merged. Missing windows are omitted. API-key-only accounts may not have subscription quotas. Failures retain the last snapshot with an error; switching the configured executable clears the previous connection's quota. Demo and connection changes discard older in-flight results, and refresh requests never overlap within a model; readings older than five minutes are labelled stale and compact percentages remain visible in orange.

## Using the notch

Open **Nocci.app**. A bar-chart menu-bar icon provides settings, refresh, show/hide, keep open, sample data and setup options. Nocci has no Dock icon, except while its terminal has tabs. You can also right-click the notch for quick actions. **Preview Appearance…** opens a separate window with clearly labelled sample usage. To quit, use either menu. It prefers a notched screen and falls back to a small pill at the top centre of the screen with the menu bar.

Keep the app in one place before configuring Claude; the bridge it writes stores the executable path. If you move the app later, Settings says so and offers to update the setup.

### Keyboard shortcuts

In **Settings › General › Keyboard Shortcuts** you can record two shortcuts that work in any app. Both are off until you record one.

- **Open the notch** opens it from wherever you are, keeps it open for a few seconds or for as long as the pointer is on it, and closes it when pressed again (even when **Keep Open** is on).
- **Go to the session that needs you** does what clicking the first row of the Sessions tab does: it brings that session's app forward, or shows its Nocci terminal. With nothing waiting it beeps; when the session's app is unknown it opens the notch on the Sessions tab.

Click **Record Shortcut** and press the keys. A shortcut needs at least two modifier keys, such as Control-Option-N, unless it is a function key, so it never takes a key another app needs; shortcuts macOS uses itself are refused. While recording, **Delete** clears the shortcut and **Escape** cancels. If macOS or another app already uses the combination, Settings says so. Nocci registers only these combinations with macOS and sees no other typing, so no permission is needed.

### Quick actions

Right-click the notch or open its **More options** menu, then choose **Claude** or **Codex**. The menu-bar icon has the same actions under **Quick Actions**.

- **Open Claude / Open Codex** opens the installed desktop app. If it is missing, choose an app or open account usage in your browser instead.
- **Account Usage…** opens the provider's official usage page in your default browser. You may need to sign in there; Nocci does not read browser sessions.
- **Choose App…** saves a custom desktop app location and opens it. This is separate from the Codex executable used to read usage, and does not change Claude Code tracking.

Use the existing **Refresh Usage** action to refresh Codex and reread Claude's last snapshot. Claude updates still depend on Claude Code activity. Connection setup and status remain in **Settings › Providers**. These menus are available even when a provider is hidden from the notch.

## Pull requests

Nocci can list your open GitHub pull requests and GitLab merge requests in the expanded notch. It is **off by default**.

1. Install the GitHub CLI (`gh`) and run `gh auth login` in Terminal. For GitLab, install `glab` and run `glab auth login --hostname <host>` for each GitLab host you use.
2. Open **Settings › Pull Requests**, turn on **Show pull requests in the notch**, tick **github.com** and add your GitLab hosts.
3. Hover the notch and choose **Pull Requests** at the top of the panel. Nocci remembers the tab you used last.

The list shows pull requests you opened, are assigned to, or were asked to review directly, grouped by repository, with your role, how long ago each was updated and its CI status. Click one to open it in your browser. Nocci opens only links on the host it asked, so a row whose link points elsewhere is dimmed. When GitHub and a GitLab host are both on, the switch at the top of the list shows everything, only GitHub or only GitLab; Nocci remembers your choice.

Nocci asks `gh` and `glab` every two minutes and when you open the tab. It never sees your tokens and stores no pull request data on disk. GitHub Enterprise and team review requests are not included. If your organisation uses SAML single sign-on and your `gh` token is not authorised for it, that organisation's pull requests are missing without an error; authorise the token on GitHub to fix it.

**Notifications.** In **Settings › Pull Requests › Notifications** you can be told when someone asks for your review, and when checks pass or fail on a pull request you opened. Both are off by default. A notification names only the repository and number, such as `owner/app #42`, never the title, since macOS keeps delivered notifications. Clicking one opens the notch on the Pull Requests tab. Whatever is already open when Nocci starts, or when you add a host, is never announced, more than three changes at once arrive as one summary, and nothing is sent in Presentation Mode. Because Nocci asks every two minutes, a notification can arrive up to about two minutes after the change.

**Code review (experimental).** Each row has a Code Review button, a magnifier after the age. Clicking it opens a Nocci terminal tab and starts Claude Code or Codex on your review prompt, with whichever placeholders your prompt uses filled in from that row. Choose the agent and write the prompt in **Settings › Pull Requests › Code Review**; the placeholders are `{url}`, `{reference}`, `{number}`, `{repo}`, `{title}`, `{host}` and `{kind}`, and an empty prompt uses the default. The default asks the agent to read the diff with `gh` or `glab`, to treat the pull request's title, description, comments and code as untrusted, and not to check out its branch or change files.

Anyone who can open a pull request and ask for your review writes what the agent reads. A pull request can carry text that tries to steer the agent. Read what the agent asks to run before you allow it, and keep your own prompt as careful as the default.

While Projects is on and has folders, if one of the repositories there has that pull request's repository as any of its remotes (as `origin` or as `upstream`, for example), the review runs there, in your working copy. A prompt that asks the agent to check out the pull request's branch can switch branches over work you have not committed, so read what the agent asks to run. Otherwise, or with Projects off, the review runs in a folder of its own for that pull request under `~/Library/Application Support/Nocci/Reviews`, which Claude Code asks you to trust the first time; Nocci never deletes anything there.

The filled-in prompt goes to the agent you chose and so to its provider: the pull request's link always, and its title too if your prompt uses `{title}`. Nocci saves only your prompt and the agent, never the filled-in prompt.

Clicking a row's button again within a second of that same row's review starting is ignored, so a fast double-click never opens two tabs.

## Claude Code sessions

Nocci can show when a Claude Code session needs you: it asked for permission, asked you a question, or finished its turn. It works for sessions in the terminal and in editor extensions such as VS Code. Sessions running in Nocci's own terminal are listed as well. It is **off by default**.

1. Open **Settings › Sessions** and choose **Turn On…**. Nocci shows exactly which hooks it will add to your Claude settings file (`~/.claude/settings.json`, or the one in `CLAUDE_CONFIG_DIR`) and where it keeps a backup until you turn it off. Nothing is written until you choose **Turn On**. Your own hooks and every other setting are kept.
2. Start or continue a Claude Code session. When one needs you, a small red dot appears on the left mark in the notch, and the **Sessions** tab at the top of the panel lists it with its project folder, what it is waiting for, and for how long. When two waiting sessions share a folder, each row also names its app, and if the app is the same too, when the session started.
3. Click a session to bring its app (your terminal or editor) to the front. Right-click to dismiss it. A session leaves the list by itself when you answer it, and anything with no news for 12 hours drops off.

Turn on **Notify me when a session needs me** in the same tab for a macOS notification each time a session starts waiting. It is off by default and silent in Presentation Mode.

The hooks run Nocci in the background, so Claude Code never waits for it. Nocci keeps only each session's state, the time, its project folder's name and the app it runs in, in `~/Library/Application Support/Nocci/Sessions`. It never keeps your prompts, Claude's replies, tool details or transcripts, and nothing leaves your Mac. **Turn Off…** removes only Nocci's own hooks and deletes those files and any backup it made of your settings. If you move Nocci after turning it on, Settings asks you to reinstall so the hooks point at the new place.

## Projects

Nocci can list your projects and start a Claude Code or Codex session in one of them from the notch. It is **off by default**.

1. Open **Settings › Projects**, turn on **Show projects in the notch** and choose **Add Folder…** for each folder that holds your projects, such as a `Code` folder in your home folder.
2. Hover the notch and choose **Projects** at the top of the panel. Each folder inside the folders you added is a project; a folder that holds git repositories lists those repositories instead, as `Folder / repository`. Repositories you worked in most recently come first. If you add your home folder, its Desktop, Documents, Downloads, Library and media folders are skipped, so macOS never asks for access to them.
3. Click a project, choose Claude Code or Codex and where it should open, type what it should do (or leave it empty) and press Return. Press Escape to go back. Option-Return starts a new line.

Right-click a project to reveal it in Finder, or to open it in your terminal or VS Code without starting a session.

Sessions open in Terminal, iTerm2 or another terminal app you choose in Settings. Claude Code sessions can also open in VS Code with the Claude Code extension, and Codex sessions in the Codex app. In VS Code and the Codex app the prompt is filled in for you to send; VS Code only does this in a folder it trusts. In a terminal, Nocci runs `claude` or `codex` in the project folder and leaves you in a shell there when it exits; choose the program in Settings if Nocci cannot find it.

Nocci never runs an AI model itself and saves only your folders and choices. Your prompt goes straight to the app you chose: for a terminal, Nocci writes a short script only you can read, which deletes itself as it starts.

### Run a session in Nocci (experimental)

Nocci's own terminal, running a session in the notch, and answering a session from the notch are the newest parts of Nocci and the least tried, so the app marks them experimental. They work as described here, but expect rough edges, and use Terminal or iTerm2 when you need something you can rely on.

Choose **Nocci (experimental)** in the "Open in" menu to run the session right in the notch: the Projects tile turns into the live terminal and grows taller, so you read the answer where you typed the prompt. Click inside it to type; click anywhere else and the notch closes as usual while the session keeps running, and it is there again the next time you open Projects. The chevron goes back to your projects, where that project shows a small terminal glyph (with an orange dot while it waits for you). The window button next to it moves the session to the Nocci window, and the cross closes it. A second session in the same project opens in the Nocci window; right-click the project and choose **New Session…**. Each session is a tab. Click **+** or press Command-T to start another, from one of your projects or any folder. When Claude Code or Codex exits, the tab keeps your own shell in that folder. Command-W closes a tab and asks first while an agent, or anything you started from its shell, is still running; the window's close button closes every tab. Command-plus and Command-minus change the text size. The notch always uses a smaller fixed text size.

The window button in the open notch, or **Show Terminal** in the menu-bar and notch menus, drops the window down from the notch over whatever you are doing. Do it again, or switch to another app, and it tucks away with every session still running. Drag it by its title bar to keep it where you put it. The Dock icon brings it back where you keep it.

When a session in Nocci needs you, it appears in the **Sessions** tab like any other, with a small window glyph, and its tab in the window gets an orange dot. Click the row to drop the terminal on that tab, or click its chevron to see the bottom of that session right in the notch and type your answer there: yes, no, a number, Escape, whatever it asks for. Click outside, switch tabs or press the chevron again to put the keyboard back where it was. Codex sessions in Nocci show up here too, as *Needs you*, because Nocci turns on Codex's own terminal notification for that run without changing your Codex settings; Codex sessions in other apps do not. Both need **Settings › Sessions** turned on. A session running in the notch opens there when you click its row, and has no chevron.

Nocci shows a Dock icon and its terminal menus only while its terminal has tabs. Quitting Nocci ends every session in it, after asking. Your prompt is passed to the agent directly and is never written to disk, and nothing shown in the terminal is saved.

## Settings and launch at login

Open **Settings…** from the menu-bar menu or either notch menu. Press **Command-comma** while Nocci is active to open the same window.

- **General:** turn on **Launch at login** to start quietly at your next login, and record [keyboard shortcuts](#keyboard-shortcuts). The switch reflects macOS registration, including pending approval and errors. If approval is needed, use **Open Login Items Settings…**. Keep the app in a stable location before enabling it.
- **Providers:** enable or disconnect Claude Code usage tracking, and select the Codex executable. Nothing is written until you confirm the change Nocci shows you.
- **Providers → Connection Details…:** what the app can see about each provider - versions, paths, when each last reported, and an error category. It abbreviates your home folder and includes no account or provider content, so it is safe to paste into a bug report.
- **Appearance:** choose which providers appear, whether percentages count usage or what is left, and which window the compact notch shows for each provider.
- **Alerts:** get notified at provider-specific usage levels. Defaults to 80%, 90% and 100% used; alerts are off by default.
- **Appearance → Pace:** a quiet line estimating whether an allowance will last until it resets. Off by default, and an estimate rather than a prediction.
- **General → Updates:** shows the installed version and build number, whether Nocci checks automatically, and the channel. Builds you make yourself have no update feed, so this offers **Open Releases…** instead of checking for updates. See [Updates](#updates).

Launch at login is opt-in and is never enabled automatically on startup.

### Appearance

- **Providers.** Show Claude, Codex, or both. At least one stays visible; to hide the whole notch turn off **Show
  Notch** in the menu-bar menu. Hiding a provider also stops Nocci reading from it. It does not change your
  Claude Code configuration, and the Providers tab keeps working while a provider is hidden.
- **Percentages.** **Used** counts what you have consumed; **Remaining** counts what is left. The bars follow the
  numbers, so in Remaining mode they drain as you use your allowance. The underlying reading is the same either way.
- **Compact Notch.** Which window each provider's number beside the notch shows, chosen separately for Claude and
  for Codex. **Automatic** shows the session window and falls back to weekly when there is no session window.
  **Session** and **Weekly** show a dash rather than another window's figure when the provider did not report the
  one you picked.
- **Notch → Open on hover.** **Instantly**, **After a short pause** (the default) or **Click only**. A click on the
  notch always opens it at once. The pause keeps the panel closed when the pointer only crosses the notch on its way
  to the menu bar.
- **Notch → Hide in full screen:** off by default; slides the notch away while a full-screen app owns its display.

With one provider visible the notch splits its two windows instead, session on the left and weekly on the right, so
the compact window choice applies only when both providers are shown.

### Alerts

Off until you turn them on. Nocci asks macOS for notification permission the first
time you enable a provider, not at launch.

- Claude and Codex are enabled separately. Each five-hour and weekly window notifies once
  at each configured level, then stays quiet until that window resets.
- **Customize Thresholds…** accepts one or more whole percentages from 1-100 for each
  provider. Separate values with commas; duplicates are removed and the saved list is
  sorted. The defaults are 80, 90 and 100. Saving new levels establishes a fresh baseline,
  so current usage never causes an immediate retroactive alert.
- Turning a provider on while it is already past a threshold does **not** notify. It
  records where you are and tells you about the next crossing, so enabling alerts or
  relaunching the app never produces a notification about usage you could already see.
- Turning a provider off forgets what it had already notified, so turning it back on
  starts fresh.
- Readings older than five minutes, sample data, and providers hidden in the Appearance tab
  raise no alerts at all.
- Alerts always say how much you have **used**, even if the Appearance tab is set to show
  what is remaining.
- **Also tell me when an allowance resets** is a separate switch, also off. It tells you an allowance came back, but only for a window you were actually warned about, and only once the provider confirms the new period. A countdown reaching zero is not treated as proof.
- Sound is off by default.
- After permission is allowed, **Send Test Notification** verifies the real delivery path
  without waiting for quota usage to change. The test contains no usage or account data,
  follows the Sound switch, and does not change any alert baseline or threshold state.
  It is unavailable during Presentation Mode.
- Clicking a notification opens the notch for about eight seconds. It does not change your
  Keep Open setting.

If you deny permission, the Alerts tab says so and offers a button to Notification
Settings. Nocci will not ask again.

### Pace

Optional, off by default. When on, each provider card gains one line: "At this pace,
likely to last", "close to the limit", or "may run out before reset", and a small mark
above each bar shows how much of that window has already gone, so you can see at a glance
whether the bar is ahead of or behind an even spend. Hover the bar for the exact share.

It is an estimate from how fast your usage has been rising recently, in percentage points.
It knows nothing about tokens or what your plan actually contains, and it deliberately
declines to answer more often than it answers. It needs at least four readings spanning
thirty minutes, ignores gaps longer than fifteen minutes, and starts over when an
allowance resets. Because Claude Code only reports when it is active, pace is often
unavailable for Claude, which is better than a confident wrong answer.

If one of a provider's windows cannot be estimated, the card says so rather than telling
you the provider is fine. A label needs two consecutive readings to change between calm
and warning, so it will not flicker.

Samples are kept in memory only, so pace does not require history recording, and it needs
roughly half an hour after launch before it can say anything.

### Presentation mode

For screen sharing. Choose **Presentation Mode** from the menu-bar menu or either notch
menu, for one hour, thirty minutes, or until you end it.

While it is on, Nocci hides the notch, puts away the Usage History and Appearance
Preview windows, clears its own delivered notifications, and delivers no new ones. The
menu-bar icon changes to a crossed-out eye and its menu offers **End Presentation Mode**
with the time remaining. Settings stays open if you had it open.

Usage keeps being collected and recorded the whole time. Alerts that would have fired are
discarded, not saved up, so ending presentation mode never produces a flurry of catch-up
notifications. You will still be told about the next threshold you cross afterwards.

The expiry is absolute: quit and reopen during a session and it resumes, but if the
session ended while the app was closed, everything is back to normal on launch. Ending it
restores the notch only if it was showing beforehand.

This hides Nocci's own surfaces. It does not detect meetings, and it does not stop
anything else on your Mac appearing on a shared screen.

**Screen sharing and recording show the notch.** Zoom, Meet, Teams, QuickTime and similar
apps capture it like any other part of the screen, and macOS gives apps no way to hide
from them. The compact strip shows only percentages, but the expanded panel shows your pull
request titles and repository names, your project folders and the folders of waiting
Claude Code sessions. Turn on Presentation Mode before you share if any of those are
private.

## Local usage history

Open **Usage History…** from the notch or menu-bar menu. Recording is **off by default**. Turn on **Record history** to save future fresh readings on this Mac; existing usage is not imported.

Choose Claude or Codex, Session or Weekly, and the last 24 hours, 7 days, 30 days or 90 days (the longer ranges appear when you keep that much). Past a week the chart shows each quarter hour's lowest and highest reading rather than every minute, so it stays quick; the summary says when it is simplified. The chart always shows **percentage used**, independently of the notch's Used/Remaining setting. It is sampled subscription utilization, not exact tokens, cost or total daily consumption. Lines break at resets, connection changes, missing reset metadata, large usage decreases and gaps longer than 15 minutes.

- Keep observations for **7, 30 or 90 days** (default 30). Reducing retention removes older observations. Expired history is pruned at startup and during recording, at most daily.
- Turn recording off to pause new observations; existing history remains until retention removes it or you clear it.
- **Export CSV…** saves every sample Nocci keeps, for both providers and both quotas, to a file you choose: provider, quota, capture time, percentage used and reset time, with times in UTC. Nothing else goes in it.
- **Clear History…** asks for confirmation before permanently deleting history for both providers. It does not delete the Claude usage snapshot or change provider connections.
- History lives in `~/Library/Application Support/Nocci/History/history.sqlite`, with owner-only permissions. Nothing is uploaded by this feature. Demo data is excluded.

Claude history follows Claude Code's event-driven updates; an old snapshot does not create repeated observations. Account switching outside Nocci cannot always be detected. Explicit reconnects, relaunches and recording pauses start separate chart segments. A history error leaves live usage working and offers Retry or a confirmed Clear History recovery.

## Updates

Nocci uses [Sparkle](https://sparkle-project.org/), the standard macOS updater. Once a
release is published, the app checks for new versions and offers them to you, so you do not
have to come back here and download anything by hand.

- **You are always asked.** Nothing installs silently. When a new version is found, Sparkle's
  own window shows the version and release notes, and you choose whether to install.
- **Nocci asks once**, on its second launch, whether it may check automatically. Change your
  answer any time in **Settings › General › Updates**, and check on demand from the menu bar.
- Update checks send no account or usage data.
- Checks pause during Presentation Mode, and the app never relaunches itself while you are
  presenting. Manual checks still work.
- Updates are verified with an EdDSA signature before installing, so a tampered or corrupted
  download is rejected.

A copy you build yourself has no feed embedded: the button reads **Open Releases…** and opens
the releases page instead.

## Troubleshooting

### Claude shows a dash

The compact notch keeps the last known percentage visible after five minutes, colored orange to indicate it is outdated. Missing or expired quota windows still show a dash. Hover the percentage to see its original reading time; the expanded card retains the last reading and its age. Settings distinguishes an out-of-date reading from active usage delivery. Refresh rereads the local file; it cannot force Claude to fetch quotas.

Check `claude --version` in the Terminal session you actually use: status-line quota reporting requires 2.1.251 or later. If you have multiple installations, `which -a claude` reveals them. A newer native installation is commonly at `~/.local/bin/claude`; verify its version before using it. Let a normal interactive Claude Code response finish, then allow a few seconds for Nocci to read its status-line event. The VS Code extension never runs status lines, so quota updates arrive only from a terminal session. Terminal and VS Code installations may also differ in executable and version. See [Claude's status-line documentation](https://code.claude.com/docs/en/statusline).

### Codex shows an error

- **Codex wasn't found:** install the Codex app or CLI, or choose its location with **Set Up Codex…**. If you don't use Codex, hide it in **Settings › Appearance**.
- **Codex stopped answering:** run `codex login` in Terminal and check that `codex` starts there. A standalone CLI may not share the Codex app's sign-in.
- **Usage unavailable:** the account answered without subscription limits; API-key-only accounts have none.

### Something else

**Settings › Providers › Connection Details…** lists what Nocci can see, with your home folder abbreviated and no account content, so it is safe to paste into a bug report.

## Uninstall

Turn Nocci's Claude Code integrations off before you delete the app. Claude Code keeps
running whatever its settings point at, and the session hooks hand every prompt and every
tool's input and output to that path. With the app gone they fail silently, but a
different program saved at the same path later would receive all of it.

1. **Settings › Sessions › Turn Off…** removes Nocci's hooks from your Claude settings.
2. **Settings › Providers › Disconnect…** restores your previous status line and removes the bridge script.
3. Turn off **Launch at login** in **Settings › General**.
4. Quit Nocci and move it to the Trash.

Both steps also delete Nocci's backups of your Claude settings. To remove the rest of what
Nocci kept, delete `~/Library/Application Support/Nocci` (the usage snapshot, usage history
and session files) and run `defaults delete com.github.amirabazi.nocci` in Terminal to
clear its preferences.

## For developers

### Build and verify

```bash
./build.sh
./test.sh
'../Nocci.app/Contents/MacOS/Nocci' --demo --expanded
```

Version numbers come from `Config/Version.env`; bump `BUILD_NUMBER` for every published build. `Scripts/release.sh` produces a checksummed archive: notarized when a Developer ID identity is set, otherwise ad-hoc signed, in which case the first launch meets the Gatekeeper prompt described above. `Scripts/generate-appcast.sh` produces the update feed with Sparkle's `generate_appcast`, which signs it with the project's EdDSA update key, embeds the release notes and creates no delta files. `release.sh` needs `NOCCI_UPDATE_FEED_URL` and `NOCCI_UPDATE_PUBLIC_KEY`, release notes for the version in `ReleaseNotes/`, and a clean working tree; a fork that publishes its own builds needs its own feed and Sparkle key.

Developer commands: `--check-codex` reads live limits; `--render /absolute/path.png` renders the demo view. `NOCCI_DATA_DIR` redirects Claude snapshots for tests; `NOCCI_CODEX_PATH` overrides saved preferences and CLI discovery. An invalid explicit path fails without falling back to another CLI, keeping fixture tests isolated from live accounts.

### Known limits

The physical camera housing cannot display pixels. This app draws beside and below it. The panel uses public screen geometry and window APIs. Full-screen app behavior, menu crowding, display scaling, sleep/wake, and multi-display changes need broader hardware testing. Releases are not notarized, so the first launch needs the approval described in [Install](#install). No account-switcher yet. All Claude Code sessions currently feed one local account snapshot; simultaneous sessions signed into different accounts are not distinguished.

### Provider logos

The compact notch and provider cards use the official Claude mark and OpenAI Blossom, and the pull request filter uses the official GitHub Invertocat and GitLab tanuki. Original SVG artwork is preserved in `Assets/`, with vector PDF versions bundled for native Retina rendering. Colors and proportions are retained; assets load locally. Source links and attribution are in `Assets/SOURCES.md`.

### What belongs in GitHub

The repository contains source, vector assets, tests, build scripts, and documentation. Generated `.build/` caches, local settings, usage snapshots, credentials, and app bundles do not belong in Git history. Downloadable app ZIPs belong in **Releases**.

### License

Apache License 2.0. See [LICENSE](LICENSE).

The Claude, OpenAI, GitHub and GitLab marks in `Assets/` are the trademarks of Anthropic,
OpenAI, GitHub and GitLab respectively. They identify the services Nocci works with and are
not covered by this project's license. See `Assets/SOURCES.md` for provenance and terms.
Nocci is not affiliated with, nor endorsed by, any of these companies.

Sparkle and SwiftTerm are used under their own licences; see
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

### References

- [Codex app-server: account limits](https://learn.chatgpt.com/docs/app-server)
- [Claude Code status-line fields](https://code.claude.com/docs/en/statusline)
- [Claude Code settings files and precedence](https://code.claude.com/docs/en/settings)
- [Apple NSScreen safe areas](https://developer.apple.com/documentation/appkit/nsscreen/safeareainsets)
