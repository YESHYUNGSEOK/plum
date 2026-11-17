# Plum

English · [한국어](README.ko.md)

A macOS app for running AI coding agents side by side. Add a project (a git repository), add a workspace, and Plum makes a git worktree for it and opens a terminal there, all in one window. It keeps the core of Orca and leaves the rest, as a light native app.

Status: **0.1 (first public release)**. The design (in Korean) is in [`docs/superpowers/specs/2026-11-16-plum-design.md`](docs/superpowers/specs/2026-11-16-plum-design.md). The UI is in English and Korean, following the system language.

## Install

Download `Plum-<version>-arm64.zip` from the releases page, unzip it and move `Plum.app` to Applications. It runs on Apple Silicon Macs with macOS 14 or later.

The app isn't signed with an Apple Developer ID or notarized yet, so macOS blocks it the first time. Control-click Plum in Finder and choose Open, or run once:

```sh
xattr -dr com.apple.quarantine /Applications/Plum.app
```

## Build and run

You need macOS 14 or later and Xcode. Builds are checked on an Apple Silicon Mac with Xcode 16.4.

```sh
./scripts/build-vt.sh   # once: downloads Zig 0.17.0 and libghostty-vt 1.0.1 and builds it (needs the network)
./scripts/bundle.sh     # makes build/Plum.app (release build, ad-hoc signature)
open build/Plum.app
swift test              # automated tests
./scripts/release.sh    # build/Plum-<version>-<arch>.zip and its SHA-256
```

`build-vt.sh` checks the Zig archive's SHA-256 and keeps what it downloads in `.tools/` (nothing is installed system-wide).

To ship a build macOS opens directly, `release.sh` signs with the hardened runtime and notarizes when given `PLUM_SIGN_IDENTITY="Developer ID Application: …"` and `PLUM_NOTARY_PROFILE=<notarytool profile>`.

## Using it

1. **Add a project** (⌘O): choose a git repository folder. The sidebar shows the project and `main`, its original checkout.
2. **Project settings** (the ⋯ next to a project name): what happens when a workspace is made.
   - Files to copy: files outside git (one glob per line, e.g. `.env*`) copied from the main checkout into each new worktree.
   - Setup command, e.g. `pnpm install`.
   - Agent command, e.g. `claude --settings "$PLUM_CLAUDE_SETTINGS"` (the "Use Claude Code Command" button).
3. **Add a workspace** (⌘N or the + next to a project): type a name in the palette and press Return. Plum makes a worktree and a branch at `<workspace location>/<project>/<name>`, copies the files, and runs `setup command && agent command` in the first terminal tab.
   - A name, folder or branch that's taken is reported while the palette is still open.
   - While it's being made, a row shows in the sidebar and the panel lists the steps (fetch, worktree, copy files). You can keep working in other workspaces meanwhile.
4. **Clean up** (right-click a workspace):
   - Archive: removes the worktree folder and keeps the branch, so it can be restored later.
   - Delete: removes the worktree folder and the local branch.
   - Uncommitted changes, commits on no remote and programs that would be ended are listed first. Return means Cancel there.
5. **Ending things asks first**: closing a tab with a program running in it (⌘W), and quitting (⌘Q or closing the window). A tab at a shell prompt closes right away.
6. **Links**: ⌘-click an http(s) address in the terminal to open it.

### Keyboard

Every command for moving between workspaces and tabs is in the Go menu. The keys follow [cmux](https://cmux.com/docs/keyboard-shortcuts); Orca's keys, where they differ, do the same thing.

| Command | Key | Orca key |
|---|---|---|
| Go to Workspace… (type to find, ↑↓ to pick, Return to go) | ⌘P | ⌘J |
| Next / previous workspace | ⌃⌘] / ⌃⌘[ | ⇧⌘↓ / ⇧⌘↑ |
| Workspace 1–8 / last workspace | ⌘1–8 / ⌘9 | |
| Back / forward (through workspaces and tabs visited) | ⌘[ / ⌘] | ⌥⌘← / ⌥⌘→ |
| Last place (switch between two) | in the menu | |
| Go to Needs Attention (waiting first; again for the next) | ⇧⌘U | |
| Pick in Sidebar (↑↓ or j k; Return or Esc back to the terminal) | ⌃⌘E | ⇧⌘0 |
| Next / previous tab | ⇧⌘] / ⇧⌘[ | ⌥⌘] / ⌥⌘[, ⌃PageDown / ⌃PageUp |
| Previously used tab | ⌃Tab | ⌃Tab |
| Tab 1–8 / last tab | ⌃1–8 / ⌃9 | |
| Move workspace up / down | ⌃⌥⌘[ / ⌃⌥⌘] | |
| Move tab left / right | ⌥⇧⌘[ / ⌥⇧⌘] | |

Changed since before 0.1: ⌘1–9 picks a workspace, not a tab (as in cmux and Orca). Tabs are ⌃1–9.

Also: new workspace ⌘N, new tab ⌘T, close tab ⌘W, add project ⌘O, text size ⌘+ ⌘- ⌘0, show/hide sidebar ⌃⌘S; in the terminal, start/end of line ⌘← ⌘→, word left/right ⌥← ⌥→, delete line ⌘⌫. In dialogs Return is the default button and Esc cancels; while a dialog is open, menu shortcuts don't reach the terminal behind it.

### Settings (⌘,)

- Font: picked from the installed fixed-width fonts, with a preview that mixes Korean and Latin text.
- Font size: 8 to 40.
- Workspace location: `~/plum/workspaces` by default. "Choose…" picks a folder; only full paths starting with `/` or `~` are taken.
- Branch prefix: e.g. `dev/`, checked against git's branch-name rules when saved.

The workspace selected last is selected again at the next launch.

## Agent status

Tabs and the sidebar show each agent's state by color and shape: working is a turning arc (blue), waiting for input a pulsing dot (orange), done a check (green). The shapes tell them apart without color, and they stop moving with Reduce Motion on. Workspaces that are waiting or done gather at the top of the sidebar under "Needs attention", whatever their project. When a tab you aren't looking at starts waiting or finishes, the Dock icon shows a count and bounces once.

The state comes in three ways:

| Way | Setup | Notes |
|---|---|---|
| Claude Code hooks | run `claude --settings "$PLUM_CLAUDE_SETTINGS"` | reports working, waiting and done. `~/.claude/settings.json` is left alone |
| OSC 7501 (program state) | none | any program that sends it |
| OSC 9 / OSC 777 notifications, bell | none | shown as "waiting" only for tabs you aren't looking at |

Plum sets `PLUM_SOCKET`, `PLUM_TAB_ID` and `PLUM_CLAUDE_SETTINGS` in every terminal. A hook sends one line, `<tab id> <working|waiting|done|idle>`, to the socket with macOS's own `nc`. Any other agent can do the same.

## Where things are kept

- App state: `~/Library/Application Support/dev.plum.Plum/state.json`
- Hook settings and socket: `claude-hooks.json` and `plum.sock` in the same folder
- Worktrees: under the workspace location set in Settings

## What has been checked, and what hasn't

The details, with dates and numbers, are in the [Korean README](README.ko.md#확인한-것과-확인하지-못한-것). In short:

- **Checked by running it**: worktree creation, file copying, archive/restore/delete with the data-loss checks (automated tests); rendering of styles, colors, Korean and emoji, vim and Claude Code screens; key encoding; agent status from hooks, OSC 7501 and the bell; drawing only while visible; every dialog, the quit and paste confirmations, links, and every shortcut in the table above, sent through the app's real event path; the English UI; a hardened-runtime build.
- **Dialogs no longer stall the app**: macOS sheets held the main thread about 0.3 s on every open and close (terminal output froze meanwhile). Dialogs are now drawn in the window and animated by Core Animation: the longest stall went from 354 ms to 52 ms (new workspace palette), 331 → 40 ms (settings) and 316 → 18 ms (delete confirmation), measured under a tab title changing ten times a second.
- **Also checked**: the Korean input-method path (the calls an input method makes while composing and committing), double/triple click, drag selection, wheel scrolling, the screen right after switching workspaces (70 captures), and the Dock badge standing in for refused notifications.
- **Not checked yet**: typing Korean through the real macOS input method (Return while composing in particular), a real trackpad and mouse (all checks used synthesized events), macOS notifications (refused for ad-hoc signed builds), Developer ID signing and notarization (no certificate here), Codex integration.

## Performance

Measured against Ghostty 1.3.1 on the same Mac (M4 Pro, built-in 120 Hz display), alternating runs; medians. Method, sample sizes and limits: [`docs/benchmarks/2026-11-16.md`](docs/benchmarks/2026-11-16.md).

| | Plum | Ghostty | Samples |
|---|---|---|---|
| App size | 2.1 MB | 62 MB | |
| Launch → window | 286 ms | 342 ms | 15 each |
| Launch → shell started | 253 ms | 239 ms | 15 each |
| Output throughput (7 kinds) | 1.11–2.26× Ghostty | | 10 each |
| Key press → on screen | 16.2 ms, 17.0 ms | 23.5 ms, 28.2 ms | 2 sessions, 300–400 each |
| Memory, 1 terminal, idle | 52 MB | 181 MB | 4 each |
| Memory, 10 terminals | 59 MB | 566 MB | 5 each |
| Idle CPU (30 s) | 1–4 ms | about 290–340 ms | |

The comparison is with the Ghostty 1.3.1 that was installed, not 1.4.0; Plum uses the newer engine (libghostty-vt), so the gaps in throughput and per-tab memory are likely smaller against the latest Ghostty. Latency excludes keyboard and panel response.

## Not there yet

Search in the terminal, mouse reporting (clicks in vim or htop) and wheel scrolling in full-screen programs, a pointer change over links, a light theme, UI languages other than English and Korean, restoring tabs after a restart, split panes, importing existing worktrees, sessions that outlive the app, signed and notarized releases (`release.sh` is ready) and auto-update, an Intel build. Why, and in what order: chapter 14 of the design document.

## Code

```
Sources/CPty/                  pty creation (forkpty + execve)
Sources/PlumKit/Terminal/      TerminalSession (pty, VT state), TerminalRenderer and GlyphAtlas (Metal), TerminalView (input), KeyMap
Sources/PlumKit/Model/         Models and Store, Git, WorkspaceService, StatusServer, AppModel, DebugCommands
Sources/PlumKit/UI/            App (menus, notifications, quitting), MainWindow (window, tab bar, dialogs), Sidebar,
                               Sheets (dialog content), AppActions (actions that ask first), Controls, Theme
Resources/                     app icon, en.lproj and ko.lproj UI strings
Vendor/                        libghostty-vt xcframework (made by build-vt.sh, not in git)
```

Terminal emulation is [libghostty-vt](https://libghostty.tip.ghostty.org/) 1.0.1 (MIT); the renderer, fonts, input and pty are Plum's own. That is the only dependency.

UI strings: the Korean in the source is the key, and English is in `Resources/en.lproj/Localizable.strings`. The compiler lists the keys: `swift build -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc <folder>`.

### Driving the app from a script

Started with `PLUM_DEBUG=1`, the status socket also takes `debug …` commands; `PLUM_STATE_DIR` points it at a state folder of its own.

```sh
PLUM_DEBUG=1 PLUM_STATE_DIR=/tmp/plum-dev build/Plum.app/Contents/MacOS/Plum &
printf 'debug state\n' | nc -w 3 -U /tmp/plum-dev/plum.sock
```

The commands are in `Sources/PlumKit/Model/DebugCommands.swift`. Useful for UI work: `debug hitches start` / `stop` (main-thread stalls over one 120 Hz frame), `debug sheet …` (open and close dialogs), `debug keywin <key code>|<characters>[|<modifier flags>]` (a key press through the real path), `debug click <column>|<row>[|<flags>]`, `debug paste <text>` (uses a private pasteboard), `debug responder`. Quitting doesn't ask in debug runs unless `PLUM_DEBUG_ASK_QUIT=1` is set. A scripted instance keeps its window in the back and never activates itself, so it doesn't disturb someone working on the same Mac.

## Contributing

Please open an issue for bugs and ideas. Before a pull request, run `swift test`, and if you changed the UI, run the app as above and look. The design's direction, including what Plum deliberately leaves out, is in chapters 3 and 4 of the design document.

## License

MIT, see [`LICENSE`](LICENSE). libghostty-vt is MIT too; its notice is in [`Vendor/LICENSE-ghostty`](Vendor/LICENSE-ghostty) and inside the app at `Contents/Resources/LICENSE-ghostty.txt`.
