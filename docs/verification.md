# What has been checked, and what hasn't

The summary is in the README, under [What has been checked, and what hasn't](../README.md#what-has-been-checked-and-what-hasnt). This is the full record, with dates and numbers.

Checked on 2026-11-16 on a MacBook Pro (M4 Pro, macOS 26.3.1).

**Checked by running it**

- 15 automated tests pass: worktree creation (new branch, existing branch, Korean name), file copying and refusing patterns outside the repository, a worktree with changes isn't removed without the force option, reporting unpushed commits, the main checkout and folders that aren't worktrees are never removed, archive and restore of a folder deleted outside the app, state message parsing, keeping the original when the state file is damaged.
- In the real app (through the test control socket and window screenshots): add a project → make a workspace → copy `.env.local` → run the setup command; archive, restore, delete; open, close and switch tabs; a tab closes when its shell exits, leaving no zombie processes.
- Rendering: bold, italic, underline, strikethrough, inverse, faint; 16 colors, 256 colors, true color; Korean at two cells wide; emoji (including clusters such as families and flags); a powerline prompt; vim full screen; Claude Code's folder trust screen.
- Key encoding (checked with `cat -v`): plain characters, arrow keys, Enter, Esc, Ctrl+A, Ctrl+C, Shift+Tab, ⌥←, ⌘←.
- Agent state: socket messages, OSC 7501 and the bell show in the sidebar. Malformed messages and unknown tab IDs are ignored. The socket file's permissions are 0600.
- Not drawing windows that aren't visible: run on screen, the terminal is drawn; output that arrived while the window was minimized shows once the window is back.
- A real Claude Code 2.1.325: in one run of `claude --settings "$PLUM_CLAUDE_SETTINGS" -p …` the state went waiting → working → done → waiting.

**Checked by running it, 2026-11-17 UI overhaul**

- Dialogs: system sheets (`beginSheet`) held the main thread about 0.3 s with their own event loop on every open and close, and terminal output and screen updates stopped meanwhile. They were replaced with in-window overlays and Core Animation transitions. The longest main-thread stall, measured under a tab title changing ten times a second (`debug hitches`, each opened and closed 5 times):

  | | Before | After |
  |---|---|---|
  | New workspace palette | 354 ms | 52 ms (once, on opening: the cost of making the view. The motion starts after it) |
  | Settings | 331 ms | 40 ms (same) |
  | Delete confirmation | 316 ms | 18 ms |
  | Error toast | 20 ms | 31 ms (it had no problem before. The slide-in motion was added) |
  | Doing nothing: frames over one 120 Hz frame (8.3 ms) / 14 s | 80 | 15 |

- The model moved to Observation, so a changed tab title redraws only the tab bar (before, everything down to the sidebar).
- Keyboard: the palette opens with the cursor in the name field; type the name and Return makes it. Return in confirmations ("Cancel" when destructive) and Esc; the keyboard goes back to the terminal after closing; menu shortcuts don't reach the terminal while a dialog is open.
- Quit confirmation: ⌘Q asks inside the app; Esc stays, Return quits. On logout or restart macOS asks first, so Plum doesn't ask again.
- Detecting a running program (⌘W while `sleep` runs → confirmation; at a prompt it closes right away), restoring the last selection on reopening, the font list and name resolution, finding links in lines that mix Korean and line wraps (automated tests).
- Links and paste: ⌘-click with real mouse events opens a link (debug mode records it instead of opening the browser), and pasting several lines into a program with bracketed paste off (`cat`) asks first. Shells that turn it on, like zsh, get the paste without asking. Debug mode uses a separate pasteboard and leaves the user's clipboard alone.
- Moving commands: every key in the README's keyboard table was sent through the real key event path (`NSApp.sendEvent`). Doing so found that ⇧⌘[ and ⇧⌘] didn't work in 0.1, and fixed it (they must be registered as the `{` `}` that ⇧ makes). Back/forward, numbers, reordering and the find ranking have automated tests too.
- The English UI (`-AppleLanguages "(en)"`) and a hardened-runtime signature (`PLUM_SIGN_IDENTITY=-`): shells, rendering, worktree creation.
- The screen right after switching workspaces: the terminal area captured 0 s, 0.05 s and 0.35 s after switching and compared with a reference; all 70 times the new workspace was drawn (the previous screen seen once didn't come back).
- The Korean input-method path: calling `setMarkedText` (ㅎ→하→한, ㄱ→그→글) and `insertText` in the order an input method does, nothing goes to the shell while composing, and only the committed `한글` goes in.
- Mouse (the real mouse event path): double click selects a word, triple click a line, a drag its range, a click clears the selection. Wheel scrolling (earlier lines show, scrolling back gives the first screen, typing while scrolled goes to the bottom).
- Dock badge: when tabs not on screen start waiting or finish, the Dock badge goes up to 1, then 2.

**Checked by running it, 2026-11-19 sidebar expansion**

- 40 automated tests pass (3 measurement tests skipped). New: changed-line counts (edits, new text files, binary and ignored files left out, a repository with no commits), PR list parsing (the newest per branch, a same-named branch on a fork left out, combining check states), folded projects leaving the ⌘1–9 order and being saved, moving several places, tab titles, detecting ports a tab opened and their going away, shells not inheriting the app's file descriptors.
- In the test app (synthesized mouse events): clicks on the tab line, name line and branch line; renaming by double-clicking the name; dragging cards to reorder (saved, `main` included, four times in a row with cards of different heights); folding projects; Plum's own right-click and Control-click menus (workspace, project, main checkout, tab; opening submenus; Esc); renaming a tab by double-clicking its title (window size and place unchanged); agent tabs' permission flags and trust records (a temporary config folder); the keyboard going back to the terminal after renaming a tab; the port of `python3 -m http.server` showing; an agent's line going away when it ends.
- A bug fixed (it was there before): new shells inherited every file descriptor the app had open (the state socket, other tabs' ptys, the output pipe of a running git). When running git and opening a new tab overlapped, the shell held the pipe and the app waited for git's output forever. Now shells are given only their terminal.
- Real GitHub data: a shallow clone of the public repository `cli/cli`, with the main checkout and two workspaces on branches named like real PRs. The badges matched what `gh` gave (#15100 open, checks passing; #15081 merged, passing; #15095 open, passing). Adding a project fetches right away instead of waiting for the next 3 minutes.
- Idle load: the test app with 8 tabs open used 50 ms of CPU in 30 s. Changed-line counts are recounted every 30 s, only for workspaces that had output in between.

**Checked, 2026-11-19 terminals that outlive the app (the terminal host)**

- 44 automated tests pass (3 measurement tests skipped). New: shells keep running without the app, and on reattach the previous screen, the output from while it was detached and window titles changed meanwhile come back (same shell pid, input passed through again); recovery from recent output when the app goes away without handing over its screen (a crash); states that hooks sent while the app was closed are kept and states the app had already seen are cleared; closing a tab ends its shell; no attaching to a terminal that doesn't exist.
- Quitting and relaunching the test app: while it was closed, the host (its parent now launchd), a stand-in Claude and `python3 -m http.server` kept running, and the server answered (200). After relaunching, each workspace's tab count, order and open tab, the screen content, a tab title given by hand ("web server"), the Claude conversation title, ports and the last selection were all as before, and the "Waiting for input" a hook sent while it was closed showed in the sidebar and under "Needs attention". When every terminal had ended, the host quit by itself and removed its socket.
- Cost: with 7 tabs attached the host used 4 MB of memory and 0% CPU. While the app is attached the host doesn't parse output; it only passes it on (it parses only after the app quits). Heavy output (50 MB of text, release build, median of 6 runs): a direct pty 183 MB/s, through the host 152 MB/s (0.83x). Each 1 KB the pty hands over adds a socket write and read. Handing the pty to the app directly would be faster, but output arriving the moment the app quits could be lost, so it wasn't chosen.

**Not checked: needs checking by actually using it**

- **Quitting and relaunching with a real Claude or Codex running**: checked with stand-in processes and hook commands.

- **The sidebar with a real mouse**: dragging cards, the × on tab lines, clicking ports and PRs were checked only with synthesized events.
- **Real Claude and Codex tab titles**: checked with stand-in processes named `claude` and `codex`. If Codex doesn't title its tab, it shows only as "Codex". Installed with npm, so the process name is `node`, it isn't recognized as an agent.

- **How the transitions feel**: checked with measurements and captures of a background window. Not watched by eye in front of a 120 Hz display.
- **Developer ID signing and notarization**: no certificate, so that step of `release.sh` hasn't been run (checked only as far as ad-hoc + hardened runtime).
- **Updating from a real release (2026-11-23)**: in the test app, a signed 0.2.0 zip went through the same install path: a tampered file and a file with another version were refused, and the right one was swapped in and reopened, with the terminals and the `sleep` in them carrying on. Not checked: downloading from GitHub, and whether macOS asks for the "App Management" permission when replacing an app in Applications.
- **Korean input (IME) from a real keyboard**: the methods an input method calls were checked (above), but not input through the real macOS input method. In particular Return while composing is handled by the input method, and wasn't checked.
- **A real keyboard and mouse**: keys and clicks were all checked by sending synthesized events through the app's real path (`NSApp.sendEvent`). Not checked by a person on a keyboard and trackpad.
- **macOS notifications (2026-11-20)**: the current way was refused with "Notifications are not allowed for this application" for both an ad-hoc signature and a self-made certificate. In the test app, done and waiting notifications sent the older way showed as banners, and only the newest per tab stayed in Notification Center. With an identifier attached a notification doesn't show at all, so none is attached. PR notifications were checked with automated tests only.
- **Claude Code's interactive screen**: whether a permission request turns the state into "Waiting for input" wasn't checked. Trust records were checked only by tests and a copy of a real `~/.claude.json` (the content was the same apart from the added keys); whether a real Claude or Codex then skips its trust screen wasn't seen.
- **Codex integration**: neither implemented nor checked.
