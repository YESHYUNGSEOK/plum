# Plum design document

Written: 2026-11-16
Status: settled. The user delegated "finishing the design and building a prototype". The author (Claude) decided the open questions, with reasons, and collected them in chapter 15. The user can overturn any of them at any time.

Notation: **[Decision]** = decided by the user, **[Proposal]** = filled in by the author, **[Builder]** = decided during implementation.

---

## 1. Intent and reasons

The user runs several AI coding agents (Claude Code, Codex) in parallel per repository, one per worktree, with Orca (1.4.259, Electron, a 726 MB app). Orca carries plugins, automation, SSH, VMs, accounts, artifacts and Linear integration, and it is heavy.

Plum is a native macOS app that keeps only Orca's core.

- Add a project (a local git repository).
- Add a workspace to a project, and the app makes a git worktree, runs the setup, and opens a terminal at that path.
- Run agents in the app's terminals, and show each agent's state (working, waiting for input, done) in the sidebar and in notifications.
- As light as Ghostty (62 MB, native), and faster where possible.

## 2. Goals

1. **[Decision]** Adding a workspace to a project makes the worktree automatically.
2. **[Decision]** When a workspace is made, the app runs the setup itself (6.3).
3. **[Decision]** The terminal is built into the app. No external terminal app is launched.
4. **[Decision]** The app shows agents' state.
5. **[Decision]** Archiving or deleting a workspace removes its worktree automatically. The user decides when to clean up.
6. **[Decision]** macOS only.
7. **[Decision]** Works without the Ghostty app installed.
8. **[Proposal]** Korean input (including what's shown while the IME composes) and the widths of Korean and emoji are right.
9. **[Proposal]** Performance: no worse than Ghostty on the measures in chapter 9 (the baseline). Faster is the aim. The user's words were "as light as Ghostty" and "faster would be even better".

## 3. Non-goals (not in v1)

**[Proposal]** The things that would make it as heavy as Orca the moment they go in.

- Plugins, automation/schedules, SSH and remote hosts, VM environments, agent account management, artifacts, Linear/GitHub issue integration
- Automatic cleanup such as detecting merged PRs (**[Decision]** the user explicitly turned it down)
- Cloning from a remote URL to add a project (adding a local folder only)
- Importing existing worktrees (ones Orca made, for instance) (15-3)
- Split panes. Tabs only
- ~~Keeping terminal sessions after the app quits (15-1)~~ added 2026-11-19 (15-1)
- Compatibility with Ghostty's config file (`~/.config/ghostty/config`)
- Windows/Linux
- Image protocols (Kitty graphics, Sixel), ligatures

## 4. Anti-goals (failures even if they technically work)

- Uncommitted changes or unpushed commits disappear without a warning.
- On the same machine, input responds slower than Ghostty, or ten terminals use more memory.
- Korean input breaks, or the characters being composed don't show.
- Features keep piling on until it's a smaller Orca.
- The user's global config files are changed without consent.

## 5. Approach

| Approach | What it is | Why dropped / why chosen |
|---|---|---|
| Electron | Same family as Orca | The opposite of the goal |
| Tauri + xterm.js | Rust + the system web view | Terminals run inside a web view, a handicap for memory and input latency with many terminals |
| Swift + SwiftTerm | A pure Swift terminal package | Easy to wire up, but not as proven as Ghostty's engine |
| Swift + libghostty (internal embedder API, `ghostty.h`) | The whole engine the Ghostty app uses | An API Ghostty says isn't for outside use. Pinned versions and manual work on every update |
| An engine entirely our own | Parser, state and renderer all written here | Most of the time would go to the long tail of compatibility, not to speed |
| **Swift + libghostty-vt 1.0 + our own Metal renderer** | The official library for VT parsing and screen state; rendering, fonts, input and the PTY written here | **[Decision] chosen** |

Why:
- libghostty-vt 1.0 (released 2026-11-06, 1.0.1 in use) officially guarantees C ABI stability, has no dependencies beyond libc, and is MIT licensed.
- The easiest part to get wrong (control sequence compatibility) is left to proven code.
- The parts where Ghostty can be beaten (a renderer simplified for the Mac only, launch time, memory per terminal) are written here.
- The renderer must be our own (**[Decision]**). The Swift Metal renderer package Ghostty has announced, if it ships, is only a point of comparison for performance.

Facts checked in the source (tag `vt-1.0.1`):
- Build: Zig 0.17.0, `zig build -Demit-lib-vt -Demit-xcframework=true -Doptimize=ReleaseFast` → `ghostty-vt.xcframework` (macOS arm64+x86_64), Swift module name `GhosttyVt`.
- API for renderers (`render.h`): frame snapshots (render state), per-row dirty tracking, cursor, colors and selection. Supports a two-step update that splits the IO thread from the render thread.
- Input API: key encoder (Kitty keyboard protocol included), mouse encoder, paste (bracketed paste handling included).
- Callbacks: writing PTY replies, bell, title, cwd (OSC 7), desktop notifications (OSC 9/777), progress (OSC 9;4), clipboard (OSC 52), synchronized output (mode 2026), **program state (OSC 7501: idle/working/done/blocked/error)**.

## 6. Features

### 6.1 Projects

- Add one by choosing a local git repository folder. A folder that isn't a git repository is refused. **[Decision, 2026-11-23]** No longer refused: as in Orca 1.4.271, after "Open as Folder" it becomes a folder project (feedback from a colleague who keeps every repository in one folder and runs agents there). Its workspaces are named sets of tabs in that same folder, with no worktree or branch; deleting one removes only Plum's record. Git and gh are never run for it (git would answer for a repository above the folder), and the git-only parts are hidden: changes, Show Changes, pull requests, archive, Import Existing Worktrees, the base branch and files to copy.
- Per-project settings: default base branch, setup (6.3).
- The project's original checkout (the main folder) also shows in the sidebar as the "main" workspace and can open terminals. The main workspace can't be archived or deleted. **[Proposal]**
- Removing a project only clears the app's record. The repository and worktrees are left alone. **[Proposal]**

### 6.2 Making a workspace

- Input: a name, and one of
  - New branch: made from the base (default: the project's default base; if unset, `origin/HEAD`; failing that, the current branch) with `--no-track`. The branch name defaults to `<branch prefix><name>` with spaces turned into `-`. Korean names are allowed (the user's existing branches look like `<user name>/<name in Korean>`).
  - Existing branch: pick a local or remote branch and check it out. **[Proposal]**
- Try `git fetch` before making it. On failure, go on with local refs. `GIT_TERMINAL_PROMPT=0` and a time limit keep it from hanging on an authentication prompt. **[Proposal]**
- Default worktree location: `~/plum/workspaces/<project>/<workspace>`. Can be changed in Settings. **[Proposal]** Matches the `~/orca/workspaces/<project>/<name>` layout of the Orca the user had been using.
- Name collisions (the branch exists, the folder exists) are stopped before making anything, with the reason shown.

### 6.3 Setup **[Decision: the app does it / details proposed]**

Set per project.

1. **Files to copy**: a list of globs relative to the main checkout (e.g. `.env*`). Copied to the same relative path in the new worktree. Files already there aren't overwritten. Patterns that point outside the repository (`..`, absolute paths) are refused.
2. **Setup command**: e.g. `pnpm install`.
3. **Agent start command**: e.g. `claude`. Can be left empty.

How it runs: the app copies the files itself. The setup command and the agent command are typed into the workspace's first terminal tab as `setup command && agent command`, and the user's login shell runs them. **[Decision, 11/17]** The agent isn't a project setting; it's picked each time a new workspace or a new tab opens (Terminal/Claude/Codex, as in Orca). The palette remembers the last choice (**[Decision, 2026-11-23]** no longer: it starts on Terminal every time, at the user's request), the + at the end of the tabs shows the same menu, and ⌘T is a terminal. The Claude and Codex commands live in the global settings, and the old per-project agent commands move there on the first launch. Progress is visible on screen as it happens, and if the setup command fails the agent doesn't start.

**[Decision, 2026-11-19]** Starting agents follows Orca exactly (the user's request). What was checked in Orca 1.x's code:
- Three permission choices, "Full Access" by default (Orca `agentPermissionDefault: 'full-access'`). The flags added are the same as Orca's table: Full Access, Claude `--dangerously-skip-permissions`, Codex `--dangerously-bypass-approvals-and-sandbox`; Auto-Approve `--permission-mode auto`, `--approve-for-me`; Agent's Own Settings adds nothing. If the command already has a permission argument, nothing is added (as Orca keeps the user's arguments).
- Trusted folders (Orca `agentWorkspaceTrustEnabled: true`): before an agent opens, its folder is written into Claude's settings (`projects[<path>].hasTrustDialogAccepted`, for both the given path and the real path) and Codex's `config.toml` (`[projects."<real path>"] trust_level = "trusted"`). On Claude's side, as Orca does, Plum takes Claude's lock directory, reads the file again, and swaps in a temporary file. If the file is missing or unreadable, or the lock can't be taken, nothing is written. **[Builder]** Codex was first given `-c projects={…}` on every run, but that made the typed command long, and Orca writes the file too, so it was switched to writing the file.
- Why (the reason Orca adds the flags): the flow is several agents running per worktree with a person looking only at the results, so a confirmation for every command leaves the agent stuck at "waiting for input". The price is that the agent runs anything with that user's permissions. A worktree separates files; it isn't a sandbox (Codex's help, too, says "only inside an external sandbox"). So Settings can switch to Auto-Approve or Agent's Own Settings, and the settings screen shows exactly what is added.

Settings are stored only on the app's side. **[Proposal]**

### 6.4 Archive / delete / restore **[Decision: the user does it, the worktree is removed automatically / details proposed]**

- **Archive**: removes the worktree folder (`git worktree remove`). The branch and the workspace record are kept.
- **Restore**: makes the worktree again from the kept branch and runs the setup again.
- **Delete**: removes the worktree, the workspace record and the local branch. **[Decision, 2026-11-23]** As in Orca (checked in Orca 1.4.271's code), the branch goes only if its work is already in a target: `branch.<name>.base`, `origin/HEAD` (fetched first) or `HEAD`, by `git branch -d`, then a merge that would change nothing (`merge-tree`), a squash commit with the same patch (`patch-id`), or every commit already there (`cherry`). An unmerged branch is kept, and the app offers to delete it anyway; that deletes it only if it still points at the commit it pointed at. Worktrees inside the folder are listed in the confirmation and removed first, deepest first, each with the same branch rule; if git's list changed since the confirmation, nothing is removed.
- **Preventing data loss (required)**:
  - Before archiving or deleting, check `git status --porcelain` (untracked files included). If there are changes, list the files and force the removal only after an extra confirmation.
  - Before deleting a kept branch anyway, list its commits on no remote.
  - The confirmation says that the workspace's terminals end with it.
  - Only remove what actually shows in `git worktree list`, isn't the main worktree, and matches the path in the app's record.
- When a worktree folder disappeared outside the app: the sidebar shows "Folder missing". On archive or delete, `git worktree remove` cleans up only that entry (`git worktree prune`, which acts on the whole repository, isn't used, since Orca may be managing the same repository).

### 6.5 Terminal

- Several terminal tabs per workspace. A new tab starts a login shell at that worktree's path.
- Switching workspaces keeps the other workspaces' terminals running. Terminals not on screen aren't drawn; only their VT state is updated.
- Supported: 256 colors and true color, bold/italic/faint/inverse/underline/strikethrough, the alternate screen, bracketed paste, synchronized output (mode 2026), OSC 7 (cwd), OSC 9/777 (notifications), OSC 7501 (state), OSC 52 (clipboard writes), the Kitty keyboard protocol (the library's encoder).
- Scrollback, mouse drag selection (double click for a word, triple click for a line), copy/paste. A risky paste (contains a newline + bracketed paste off) asks first.
- Korean IME: implements `NSTextInputClient`, and shows the characters being composed at the cursor.
- Fonts: the fixed-width font the user picks + CoreText fallback (Korean, emoji).
- `TERM=xterm-256color`, `COLORTERM=truecolor`, `TERM_PROGRAM=Plum`. **[Proposal]** Shipping our own terminfo would break on the far server over SSH.
- For what's in v1 scope but put off in the prototype, see chapter 14.

### 6.6 Agent state **[Decision: show it / how it's detected proposed]**

**[Decision, 2026-11-19]** The display is a single ring (option 1 of the mock-up "10 state indicators"; option 5, a pixel cat, was turned down): none is a faint ring, working a ring with a turning gap, waiting for input a thick breathing ring, done a filled disc with a check cut in. The user asked for "monitoring", as in Orca, so a fifth state was added. Orca treats Claude as working in "monitoring" mode when its turn is over but background work it started is still alive. Plum takes the Stop hook's input as is (`background_tasks` and `session_crons` in the official docs): working if a subagent is running, monitoring if a command, Monitor, workflow or scheduled wakeup remains (a faint teal ring with a pulse line drawn and wiped inside, option 9 of 10 icons), otherwise done. Monitoring has nothing to do, so it isn't put under "Needs attention" or in notifications. The count next to "Needs attention" shows waiting and done as separate chips (option 4 of 5 badges).

States: `idle` (nothing shown), `working`, `waiting` (waiting for input or permission), `done` (turn over).

Signals:
1. **OSC 7501 program state**: a standard the program sends itself. Works with no setup. Shown as `blocked`→waiting, `error`→done.
2. **Agent hooks → Unix socket**: the app puts `PLUM_SOCKET`, `PLUM_TAB_ID` and `PLUM_CLAUDE_SETTINGS` in each PTY's environment. A hook sends one line, `<tab ID> <state>`, with macOS's own `nc -U` (no separate executable).
   - Claude Code: the app writes a hook settings file, which applies when run as `claude --settings "$PLUM_CLAUDE_SETTINGS"`. **The global `~/.claude/settings.json` is left alone.** Mapping: `UserPromptSubmit` and `PostToolUse`→working, `Notification(permission_prompt|elicitation_dialog)`→waiting, `Stop`→done, `SessionEnd`→idle.
   - Codex: done at the end of a turn through the `notify` setting. (Not verified in the prototype)
3. **OSC 9/777 notifications** → waiting. **BEL** → waiting, only in tabs that had no hook/7501 signal.

Socket input is outside input, so it's validated: only known tab IDs and state values are taken, and messages are length-limited and stripped of control characters. The socket file's permissions are 0600.

Display:
- A state dot per tab. A workspace in the sidebar shows the most pressing state of its tabs (waiting > done > working > idle).
- When a tab turns waiting or done while it isn't on screen or the app isn't active, a macOS notification. Clicking the notification goes to that tab.
- The Dock icon shows the number of waiting/done tabs as a badge and bounces once. It needs no permission, so it works even where notifications are refused. **[Builder]** Added after seeing macOS refuse notifications for a local build (ad-hoc signature).
- done clears when the tab is looked at. waiting clears too when the user types in that tab.

### 6.7 Layout

- Left sidebar: projects → workspaces (name, state dot) → archived items. It sits directly on the window background, with no divider.
  - Drag its edge to set the width between 180 and 420 pt; it's saved. Double-click the edge for the default 236 pt.
  - Workspace right-click menu: Rename, Archive (Restore for archived ones), Delete Worktree (red), Show in Finder, Copy (path, branch). For the main checkout, the delete item is disabled with the reason in two lines, and "Remove Project from Plum" is offered (modeled on Orca's menu). **[Decision, 2026-11-19]** Right-click menus aren't system menus; they open as Plum's dropdown (the same panel as the program picker). Submenus open in place and work from the keyboard too (↑↓, Return, →←, Esc). A Control-click opens the same menu.
  - **[Decision]** 2026-11-19, the user asked for "the detailed parts … modeled on Orca": workspaces show as cards. Under the name, the branch, the uncommitted changed lines and the PR (from `gh` every 3 minutes, with a state color and a checks dot), and under that a line per tab (icon, title, state, agent time, ports). A tab line goes to that tab; ports and the PR open in the browser. Cards are dragged to reorder within a project (`main` moves too; it was first pinned to the top, but in a project with only one workspace dragging then did nothing, and the user said "it doesn't work"), and projects fold. The menus gained Mark as Read, Close All Tabs, Open In and Open PR, plus a menu on the project name and a tab menu (rename, Close Other Tabs, Close Tabs to the Right).
  - **[Builder]** Changed-line counts are recounted every 30 seconds, only for workspaces whose tabs had output in between (quiet workspaces don't run git). Ports come from reading, every 4 seconds, the TCP LISTEN sockets of the processes under a tab's shell. To leave out the ports Claude Code opens for its own use, the agent process's own sockets are excluded.
  - **[Builder]** Dragging tabs to reorder them was left out. The tab bar is in the window's drag area (the title bar), so dragging with a real mouse may move the window, and synthesized events can't check it. Renaming a tab was at first only in the right-click menu for the same reason, but at the user's request (2026-11-19) a double click on the tab title works too. The tab button takes the click, so it doesn't pass through to zooming the window (checked only with synthesized events, that the window's size and place stay the same). Order is changed with ⌥⌘{ }.
  - **[Decision]** Rename changes only the name in the sidebar. Changing the folder and branch too would bring a worktree move and a branch rename with it, which is risky. Double-clicking the name edits it in place too (Return confirms, Esc cancels, a click elsewhere confirms).
- Right: a rounded terminal panel floating above the background. At the top of the panel, the tabs and the branch name; under them, the terminal.
- **[Decision]** The shape follows the layout of mock-up "09 Float", the colors "03 Graphite" (two tones of dark gray + one plum accent). The user picked them from 10 mock-ups. The color values are in `Sources/PlumKit/UI/Theme.swift` and `TerminalTheme`.
- **[Decision]** Details picked from the 2026-11-17 UI mock-ups (layout and colors as above):
  - Sidebar: "Needs attention" at the top gathers workspaces waiting for input or done, whatever their project.
  - State indicators: told apart by shape, not only color (working = a turning arc, waiting for input = a pulsing dot, done = a check). They can be told apart in black and white.
  - Tab bar: Chrome style, where the active tab on a dark strip becomes the same surface as the terminal below and joins it with a concave curve. The branch is a chip on the right. (Underline B was applied first, but after using it, F was picked from five second-round mock-ups.)
  - New workspace: a palette. Type the name and ↵. Collisions are reported with the palette still open; once it passes, the palette closes and the panel shows the steps.
  - Sheets (Settings, Project Settings) and the archive and delete confirmations: the same dark style instead of system Forms and alerts. The confirmation lists the changes and commits that would be lost separately, and Return is still "Cancel".
  - **[Builder]** Dialogs are drawn as overlays in the window, not as system sheets. A system sheet held the main thread about 0.3 s on every open and close, and the terminal froze (measured in [Verification](../../verification.md), "2026-11-17 UI overhaul"). Core Animation does the transitions. The quit, multi-line paste and project removal confirmations moved to the same overlay too, so no system alerts are left in the app.
  - **[Decision]** 2026-11-17: the commands for moving between workspaces and tabs follow cmux's keys and also take Orca's (the full table is under "Keyboard" in README.md). ⌘1–9 are workspaces, ⌃1–9 tabs. The user asked to "implement them all … modeled on Orca and cmux".
  - **[Builder]** Closing a tab with a program running and quitting the app show that program's name and ask (preventing "disappear without a warning" from chapter 4).
  - Empty screen: the app icon and the main shortcuts. Errors: a toast that doesn't block work (bottom right of the panel).
- Shortcuts: new tab Cmd+T, close tab Cmd+W, switch tabs Ctrl+1..9 and Cmd+Shift+[ ] (on 2026-11-17 Cmd+1..9 became workspaces), new workspace Cmd+N, copy/paste Cmd+C/V, font size Cmd+±/0.

## 7. Architecture

- **Language/UI**: Swift (a SwiftPM package). AppKit for the window and splits, SwiftUI (`NSHostingView`) for the sidebar, tab bar and dialogs. The terminal view is an `NSView` + `CAMetalLayer` and isn't put in the SwiftUI view tree (avoiding SwiftUI recreating a live terminal).
- **One terminal view per window**: switching tabs keeps the view and changes only the session it shows. A Metal layer holds two window-sized buffers (about 22 MB at this window size), so a view per tab would multiply that by the number of tabs. The prototype's measurements showed it, and it was changed.
- **VT layer**: libghostty-vt 1.0.1 static library (xcframework, SwiftPM binaryTarget). `scripts/build-vt.sh` downloads Zig 0.17.0 (checksum verified) and the `vt-1.0.1` source and builds it here. No binaries prebuilt by a third party.
- **Threads**: per terminal, an IO thread reads the PTY and writes to the VT. The main thread draws. The terminal state is guarded by a lock and the render state by a separate lock (lock order: terminal → render state). Render frames use the two-step update to keep the terminal lock held as briefly as possible.
- **Renderer**: our own Metal. A single instanced-quad pipeline (background rectangles/glyph masks/color glyphs), a glyph atlas, a per-row cache (only dirty rows are recomputed), drawing in step with vertical sync through a display link, and the link stopped when nothing changes. Synchronized output keeps the frame from when the span started, with a 1 s time limit.
- **Fonts**: CoreText for glyph lookup and rasterization, a fallback chain.
- **PTY**: `forkpty` + `execve` in a small C target.
- **git**: calls the system `/usr/bin/git` CLI. No libgit2.
- **Storage**: `~/Library/Application Support/dev.plum.Plum/state.json`. Atomic writes. (A folder named `Plum` already holds another program's files on this Mac, so the bundle ID is used as the name.)
- **IPC**: one Unix domain socket for the state hooks.
- libghostty-vt is the only outside dependency.

## 8. Constraints

- macOS 14 or later (for the display link API). **[Builder]**
- The prototype is built for the user's Mac (Apple Silicon). The library is built universal, so a release can become a universal app. (15-6)
- License: includes libghostty-vt's MIT notice. No code is copied from other apps such as cmux (GPL).

## 9. Performance goals and measurement **[Proposal]**

Compared with Ghostty 1.3.1 on the same machine under the same conditions. At least as good as Ghostty is the baseline; faster is the aim.

| Measure | How | Baseline |
|---|---|---|
| App size | `du -sh` of the bundle | Ghostty (62 MB) or less |
| Cold start → first frame | from process start to the first terminal frame | Ghostty or less |
| Memory | 1/10 terminals idle | Ghostty or less |
| Throughput | time to `cat` a large file | 90% of Ghostty or more |
| Input latency | key press → screen (needs a measuring tool) | Ghostty or less |

"Faster" is claimed only from measurements. The prototype's results, method and limits are in `docs/benchmarks/2026-11-16.md`. In short: Plum is better at showing the window, output throughput, key latency and memory; Ghostty starts the shell about 14 ms sooner.

## 10. Verification

- Automated tests: the git worktree life cycle (temporary repositories), state protocol parsing, branch name conversion, file copy globs.
- Rendering: feed known input and check with window screenshots (colors, Korean and emoji widths, cursor, selection).
- Real use: no broken screens in Claude Code, vim, htop and the like.
- State detection: socket message → sidebar display, a real Claude Code hook checked once.
- Korean IME: needs real key presses, so it's for the user to check.

## 11. Distribution **[Proposal]**

v1 is for the user alone (a local build, ad-hoc signature). To give it to others, add Developer ID signing, notarization and Sparkle auto-updates.

## 12. What the implementer decided **[Builder]**

- A SwiftPM package + `scripts/bundle.sh` makes the `.app` (no Xcode project file).
- Metal shaders are compiled from source at launch (a simpler build).
- State hooks send with a one-line `nc -U` (no separate CLI).
- Added a branch prefix setting (matching the user's existing branch convention, `<user name>/…`).

## 13. Prototype scope

In: all of 6.1–6.4, the terminal core of 6.5 (rendering, input, IME, scrollback, selection, copy/paste, tabs), state detection and display from 6.6, minimal settings (font, size, workspace location, branch prefix), saving state.

## 14. Put off in the prototype (needed before v1)

**[Done 2026-11-20]** Find in the terminal, mouse reporting and the wheel on the alternate screen, OSC 8 links, restoring the tab layout on relaunch (the terminal host), split panes, separate windows for workspaces and picking an accent color are implemented.
- Split panes **[Decision]**: each pane is an ordinary tab of the workspace, and only the shape of the split (a `SplitNode` tree) groups them under the "head" tab in the tab bar. So the sidebar, agent state, ports, hooks and the terminal host didn't change. On screen there is one TerminalView per visible pane, and the views of tabs not on screen are dropped (each view has a window-sized drawing buffer).
- Separate windows **[Decision]**: a terminal is drawn in one place only (a session has one drawing connection). So windows are split by workspace, and the main window shows "Go to That Window" in place of that workspace. The workspace of the window in front becomes the selection, so the menus act on that window. Dialogs show in the main window and bring it to the front when they do.
- Light theme **[Decision, user]**: built, then taken out at the user's request. The app is always dark; only the accent color is picked.

- Drawing box characters directly (in case font glyphs show gaps)
- Verifying the Codex hooks, a button to install global hooks (optional)
- Checking a full vttest/esctest pass, measuring input latency
- Universal build, signing and notarization, automatic updates (macOS notifications need checking again after Developer ID signing)
- VoiceOver navigation of terminal content (today the whole screen is read only as one block of text)
- Measuring performance on other displays (60 Hz external) and in real long agent sessions

## 15. Open questions the author decided

The questions the reviewer (builder check) raised, and the decisions on them.

1. **[Decision, 2026-11-19] Sessions are kept.** The user asked: "Orca restores everything even after you quit and restart it, make it work the same way." In Orca a separate terminal daemon (`Orca Terminal Host`) owns the shells and outlives the app. In Plum too, a host started from the same executable with `--terminal-host` owns the ptys (`Sources/PlumKit/Terminal/TerminalHost.swift`). **[Builder]** While the app is attached, the host only passes output through; when the app quits it hands over each terminal's screen as VT sequences from libghostty-vt's formatter, and from then on the host parses. On reattach it gives that screen back (scrollback, modes and window title included). This avoids parsing twice while the app is attached (about 1 MB per terminal, scrollback up to 10 MB). Heavy output slows to 0.83x of a direct pty (measured in [Verification](../../verification.md)). Handing the pty to the app (SCM_RIGHTS) is faster but could lose output at the moment the app quits, so it wasn't chosen. Below is the earlier judgment.
   - (Earlier) **No session keeping.** Quitting the app ends its terminals and agents too. One process owning the PTY, the VT and the renderer suits the launch time and memory goals. Agent conversations can be continued with `claude --resume`. The PTY boundary is a single file descriptor, so adding a small process that only holds the PTYs later stays possible (the author's judgment, unverified).
2. **The renderer stays our own.** The user chose "not depending on Ghostty" and "the side that wires up the renderer directly".
3. **Existing worktrees aren't imported.** One of the user's repositories alone has 21 worktrees, most of them Orca's. If two apps manage the same worktree, deleting it in one breaks the other's record. Work in progress is finished in Orca, and new work starts in Plum. Workspaces store their path directly, so importing is easy to add later.
4. **At least as good as Ghostty is the baseline; faster is the aim.**
5. **No global hook install.** Injecting with `--settings` leaves global config files alone.
6. **The prototype is an Apple Silicon build.** The user's Mac is arm64.
7. **The worktree location is `~/plum/workspaces/…`.** Easier to open from Finder and editors than a hidden folder, and the same layout as Orca's.
