# Contributing to Plum

Thanks for looking. Bug reports, ideas, documentation and code are all welcome.

Plum is a small native macOS app with one dependency. Most changes can be built, tested and tried in a few minutes.

## Before you start

- **A bug or a small fix**: open a pull request directly.
- **A new feature or a bigger change**: open an issue first, so the direction is agreed before you write the code.
- **What Plum is for**: the [design document](docs/superpowers/specs/2026-11-16-plum-design.md) says what it aims at (chapter 2), what it leaves out (chapter 3) and what counts as a failure even if it works (chapter 4). A change that goes against chapters 3 or 4 is unlikely to be merged.
- **A security problem**: don't open a public issue. See [SECURITY.md](SECURITY.md).

## Set up

You need an Apple Silicon Mac with macOS 14 or later and Xcode.

```sh
git clone https://github.com/YESHYUNGSEOK/plum.git
cd plum
./scripts/build-vt.sh   # once: downloads Zig and builds libghostty-vt into Vendor/ (needs the network, takes a few minutes)
swift test              # the automated tests
./scripts/bundle.sh     # makes build/Plum.app
```

`build-vt.sh` installs nothing system-wide: what it downloads stays in `.tools/`, and it checks the checksums of what it fetched.

## Try your change

Run your build with a state folder of its own, so it never touches the workspaces and tabs of a Plum you already use:

```sh
PLUM_STATE_DIR="$HOME/plum-dev-state" build/Plum.app/Contents/MacOS/Plum
```

- Start it this way, not with `open`. If Plum is installed, `open build/Plum.app` may bring the installed one forward instead.
- New workspaces are made under the workspace root in Settings (`~/plum/workspaces` by default), also for a development build. Use a throwaway repository when you try creating, archiving or deleting workspaces.
- Terminals live in a separate host process (`Plum --terminal-host`) that outlives the app. After testing, close the tabs you opened, or the host keeps running.

## Where things are

The [Code](README.md#code) section of the README maps the folders. In short:

- `Sources/PlumKit/Terminal/`: the pty, VT state, the Metal renderer, input, the terminal host.
- `Sources/PlumKit/Model/`: state and its file, git and worktrees, agent status, updates.
- `Sources/PlumKit/UI/`: the window, sidebar, dialogs and menus (SwiftUI and AppKit).
- `Tests/PlumKitTests/`: the tests. They make real git repositories and real ptys in temporary folders.

## What a change should look like

- **Small and about one thing.** Leave unrelated code, comments and formatting as they are.
- **Tested.** A bug fix comes with a test that fails without it. New logic comes with a test of that logic. Run `swift test` before you push; CI runs it again on the pull request.
- **Looked at.** If you changed anything on screen, run the app and look at it, and add a screenshot to the pull request.
- **No new dependencies.** libghostty-vt is the only one, on purpose. If you think another is needed, raise it in an issue first.
- **Comments say why.** The code already says what it does. Match the style of the file you are in.
- **Careful where it can lose work.** Deleting worktrees, overwriting the state file, and anything that reads external input (hook messages, session files, downloads) are checked strictly in review.

### UI text

The Korean string in the source is the key, and the English is in `Resources/en.lproj/Localizable.strings`. When you add or change text on screen, add the English line too. If you don't write Korean, write the English and say so in the pull request: a maintainer will supply the Korean key.

### Performance

Plum's memory, key latency and output throughput are measured and published in the README. If your change touches the terminal engine, the renderer or the pty path, say what you measured. The speed tests are skipped unless given data:

```sh
python3 bench/gen-data.py /tmp/plum-bench-data 122 46   # about 260 MB
PLUM_BENCH_DATA=/tmp/plum-bench-data swift test -c release -Xswiftc -enable-testing \
  --filter "EngineSpeedTests|PtySpeedTests|RenderSpeedTests|SessionMemoryTests"
```

Run it before and after your change, a few times each, and compare. How the published numbers were measured is in [`docs/benchmarks/`](docs/benchmarks/).

## Commits and pull requests

- Write commit messages in English, as a short sentence saying what the change does: `Keep unreadable workspace state from being overwritten`.
- Branch from `main` and open the pull request against `main`. Any branch name is fine.
- Fill in the pull request template: what changed, why, and how you checked it.
- A maintainer reviews it. Expect questions about edge cases, and requests to make it smaller.
- Maintainers squash or merge as fits. You don't need to tidy the history.

## Releases

Maintainers make releases. Please don't change the version in `scripts/bundle.sh` or the release scripts in a pull request.

## License

Plum is MIT licensed. By contributing, you agree that your contribution is licensed under the same terms.
