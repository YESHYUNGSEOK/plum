# Orca Import Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A one-time import of the user's Orca repositories and worktrees into Plum, read through Orca's CLI.

**Architecture:** `OrcaImport` (new file) finds Orca's CLI, runs `repo list --json` and `worktree list --json --limit 10000`, parses and filters the output, and checks every path on disk, giving a `Catalog`. `AppModel.importFromOrca(_:)` turns a catalog into projects and workspaces. `AppActions.importFromOrca(_:quietly:)` asks, imports and reports; a File menu item and a first-launch offer call it.

**Tech Stack:** Swift 5.10+, AppKit/SwiftUI, Foundation `Process`, `JSONSerialization`, XCTest.

**Spec:** `docs/superpowers/specs/2026-11-23-orca-import-design.md`

## Global Constraints

- Read-only toward Orca: no Orca command but `repo list --json` and `worktree list --json --limit 10000`; nothing of Orca's is written; nothing on disk changes.
- The CLI is found by bundle id `com.stablyai.orca` (Launch Services), at `Contents/Resources/bin/orca` inside the app, run by absolute path with fixed arguments and a time limit. Never from `PATH`.
- Orca's output is untrusted input: a repository is kept only if its folder exists and is a git repository (its root is used); a worktree only if its folder exists. Nothing from it is executed.
- Output that isn't what's expected (not JSON, unknown shape, `ok:false` other than `runtime_unavailable`, `truncated:true`) imports nothing.
- UI copy is Korean in the source with English in `Resources/en.lproj/Localizable.strings`; progress and results use `model.notice`, failures `model.errorMessage`.
- Debug runs (`PLUM_DEBUG`) never show the first-launch offer.

## Review Focus

- Orca running with no repositories: the menu says so (notice); the first-launch offer says nothing. → Task 1 test `testAnEmptyListIsAnEmptyCatalog`, Task 4 copy.
- A repository Orca lists whose folder was moved or deleted: skipped, not an error. → Task 2 test `testPathsAreCheckedOnDisk`.
- A repository Plum already has (under another name): its name stays, Orca's worktrees join it. → Task 3 test `testAnExistingProjectKeepsItsName`.
- A worktree whose Orca name is already a workspace name in that project: gets a `-2` suffix, as Plum's own import does. → Task 3 test `testNamesThatClashGetASuffix`.
- Orca busy and the CLI never returning: the import gives up after the time limit with "unreadable". → Task 2 test `testAHungCLIGivesUp`.

---

### Task 0: Commit the pending fixes

Three finished fixes are uncommitted in the working tree; commit them apart from this feature, one each.

- [ ] **Step 1:** `git add Sources/PlumKit/Model/StatusServer.swift Sources/PlumKit/Model/AppModel.swift Tests/PlumKitTests/CodexHooksTests.swift` → commit "Codex: 끊어진 서버 소켓 링크를 시작 전에 정리".
- [ ] **Step 2:** `git add Sources/PlumKit/Terminal/TerminalView.swift Tests/PlumKitTests/TerminalMoreTests.swift` → commit "워크스페이스 전환 때 터미널 크기를 두 번 바꾸던 것".
- [ ] **Step 3:** `git add Sources/PlumKit/UI/Dropdown.swift` → commit "드롭다운: 내용이 모서리에서 날아오던 것".
- [ ] **Step 4:** add the spec and this plan → commit "Orca 가져오기: 설계와 계획". Every commit ends with `Co-authored-by: Claude <noreply@anthropic.com>`. Use `/usr/bin/git`. Do not push.

### Task 1: Parse Orca's output

**Files:**
- Create: `Sources/PlumKit/Model/OrcaImport.swift`
- Test: `Tests/PlumKitTests/OrcaImportTests.swift`

**Interfaces:**
- Produces:
  ```swift
  enum OrcaImport {
      struct Repo: Equatable { var id: String; var path: String; var name: String }
      /// branch without "refs/heads/"
      struct Worktree: Equatable { var repoID: String; var path: String; var branch: String; var name: String }
      struct Catalog: Equatable { var repos: [Repo] = []; var worktrees: [Worktree] = []; var detached = 0; var missing = 0 }
      struct Result: Equatable { var projects = 0; var workspaces = 0 }
      enum Failure: Error, Equatable { case notInstalled, notRunning, unreadable }
      static func parse(repos: Data, worktrees: Data) throws -> Catalog
  }
  ```

Rules for `parse` (from the spec): top level must be an object with `ok`; `ok:false` with `error.code == "runtime_unavailable"` → `.notRunning`, any other `ok:false` → `.unreadable`; `result.repos` / `result.worktrees` must be arrays, else `.unreadable`; `truncated == true` → `.unreadable`. Repos: skip `kind == "folder"` (missing kind = git) and any with `hiddenAt`; name = `displayName`, else the folder's last component. Worktrees: skip `isMainWorktree == true`; `branch == ""` → `detached += 1`, skipped; strip a leading `refs/heads/`; name = `displayName` if not empty, else the folder's; keep only worktrees whose `repoID` is a kept repo. `missing` stays 0 here (Task 2 fills it).

- [ ] **Step 1: Write the failing tests** with small made-up JSON (no real data), built as Swift string literals:
  - `testReposAndWorktreesAreRead`: repos `r1` (`/tmp/a`, "Alpha", kind git), `r2` (`/tmp/b`, no displayName, no kind); worktrees: `r1` main checkout, `r1` `refs/heads/feat/x` at `/tmp/a-x` named "X work", `r2` `refs/heads/fix` at `/tmp/b-fix` with `displayName ""`. Expect repos `[Repo(id:"r1",path:"/tmp/a",name:"Alpha"), Repo(id:"r2",path:"/tmp/b",name:"b")]`, worktrees `[Worktree(repoID:"r1",path:"/tmp/a-x",branch:"feat/x",name:"X work"), Worktree(repoID:"r2",path:"/tmp/b-fix",branch:"fix",name:"b-fix")]`, `detached == 0`.
  - `testFoldersHiddenReposAndDetachedAreLeftOut`: a `kind:"folder"` repo, a repo with `hiddenAt: 1795000000000` (and a worktree of it), a worktree with `branch:""` → those repos absent, the hidden repo's worktree absent, `detached == 1`.
  - `testAnEmptyListIsAnEmptyCatalog`: `repos: []`, `worktrees: []` → `Catalog()`.
  - `testOrcaNotRunning`: `{"id":"local","ok":false,"error":{"code":"runtime_unavailable","message":"Start the Orca app first."},"_meta":{"runtimeId":null}}` → throws `.notRunning`.
  - `testOutputPlumDoesNotKnowImportsNothing`: each throws `.unreadable`: `"not json"`, `{"ok":true,"result":{}}`, `{"ok":false,"error":{"code":"other"}}`, worktrees with `"truncated":true`.
- [ ] **Step 2:** `swift test --filter OrcaImportTests` → fails to compile (`OrcaImport` not found).
- [ ] **Step 3:** Implement the types and `parse(repos:worktrees:)` in `OrcaImport.swift` with `JSONSerialization` (no Codable models of Orca's whole schema: only the fields above are read, the rest ignored).
- [ ] **Step 4:** `swift test --filter OrcaImportTests` → 5 tests pass.
- [ ] **Step 5:** Commit "Orca 가져오기: CLI 출력 해석".

### Task 2: Run the CLI and check paths

**Files:**
- Modify: `Sources/PlumKit/Model/OrcaImport.swift`
- Test: `Tests/PlumKitTests/OrcaImportTests.swift`

**Interfaces:**
- Consumes: `OrcaImport.parse`, `Git.repositoryRoot(of:)`, `Git.run` (tests only).
- Produces:
  ```swift
  static let bundleID = "com.stablyai.orca"
  /// Orca's CLI inside its app, if Orca is installed.
  static func cli() -> URL?
  /// Orca's version, for the "couldn't read" message.
  static func version() -> String?
  static func load(cli: URL, timeout: TimeInterval = 15) async throws -> Catalog
  ```

`load` runs `[cli] repo list --json` and `[cli] worktree list --json --limit 10000` off the main thread, each with `timeout`, reading stdout whatever the exit code (Orca exits 1 with JSON when not running; `Git.run` drops stdout on failure, so use a small `Process` runner of its own: stdin null, stderr discarded, terminate on timeout → `.unreadable`). Then `parse`, then: each repo's path → `Git.repositoryRoot(of:)`; no root → repo dropped (with its worktrees, uncounted); repo path becomes the root. Each worktree folder that doesn't exist → dropped, `missing += 1`. `cli()` = `NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)` + `Contents/Resources/bin/orca`, only if executable. `version()` = that app bundle's `CFBundleShortVersionString`.

- [ ] **Step 1: Write the failing tests.** A helper writes an executable fake CLI (`#!/bin/sh`, `case "$1" in repo) cat <repos.json>;; worktree) cat <worktrees.json>;; esac`) into a temp folder, plus a temp git repo with one worktree on branch `feat/x` (as `testWorktreesMadeElsewhereAreImportedOnce` in `TerminalBasicsTests.swift` builds one).
  - `testPathsAreCheckedOnDisk`: repos = the temp repo + `/nonexistent/repo`; worktrees = the real worktree, one at a missing folder of the temp repo, one of the missing repo. Expect `repos.map(\.path) == [root of temp repo]`, worktrees = only the real one, `missing == 1`.
  - `testAHungCLIGivesUp`: fake CLI `sleep 5`; `load(cli:timeout: 0.5)` throws `.unreadable` in under 2 s.
  - `testNotRunningComesThrough`: fake CLI prints the `runtime_unavailable` JSON and `exit 1` → throws `.notRunning`.
- [ ] **Step 2:** `swift test --filter OrcaImportTests` → the 3 new tests fail (no `load`).
- [ ] **Step 3:** Implement `cli()`, `version()`, `load(cli:timeout:)`.
- [ ] **Step 4:** `swift test --filter OrcaImportTests` → 8 tests pass.
- [ ] **Step 5:** Commit "Orca 가져오기: CLI 실행과 경로 확인".

### Task 3: Import a catalog into Plum's state

**Files:**
- Modify: `Sources/PlumKit/Model/AppModel.swift` (next to `addProject` / `importWorktrees`, ~line 968-1040)
- Test: `Tests/PlumKitTests/OrcaImportTests.swift`

**Interfaces:**
- Consumes: `OrcaImport.Catalog`, `OrcaImport.Result`, existing `importWorktrees(of:)`, `WorkspaceService.samePath`.
- Produces: `@discardableResult public func importFromOrca(_ catalog: OrcaImport.Catalog) async -> OrcaImport.Result`

Behavior: for each repo, a project with the same path is reused untouched; otherwise `Project(name:path:)` is appended with Orca's name made unique the way `addProject` does (`name`, `name-2`, …). For each worktree of a mapped repo: skip if a workspace with the same path exists; else `Workspace(projectID:name:branch:path:)` with the name made unique within the project the way `importWorktrees` does. Then, for each project added, `await importWorktrees(of:)` so its other git worktrees appear as when a project is added by hand (counted in `workspaces`). `save()` once if anything was added, `refreshPullRequests()`, and `findIcon(of:)` for new projects. Pull the two inline "unique name" loops of `addProject` and `importWorktrees` into private helpers used by all three places; their behavior must not change (the existing `testWorktreesMadeElsewhereAreImportedOnce` stays green).

- [ ] **Step 1: Write the failing tests** (real temp git repos; catalogs built by hand):
  - `testACatalogBecomesProjectsAndWorkspaces`: repo with worktrees `by-orca` (Orca name "Orca name", branch `feat/x`) and `by-hand` (branch `feat/y`, not in the catalog). Expect one project named after the catalog repo, workspaces `["Orca name", "by-hand"]` with branches `feat/x`, `feat/y`; `Result(projects: 1, workspaces: 2)`; a second `importFromOrca` of the same catalog → `Result()`.
  - `testAnExistingProjectKeepsItsName`: `addProject(at:)` first, rename it "mine" via `update(_:)`, then import a catalog naming it "Alpha" → still one project, named "mine", Orca's worktree added; `projects == 0`.
  - `testNamesThatClashGetASuffix`: a workspace named "X" exists in the project; a catalog worktree at another path named "X" → added as "X-2".
- [ ] **Step 2:** `swift test --filter OrcaImportTests` → the 3 new tests fail.
- [ ] **Step 3:** Implement `importFromOrca(_:)` and the two helpers.
- [ ] **Step 4:** `swift test` → all pass (92 before this feature + 11 new).
- [ ] **Step 5:** Commit "Orca 가져오기: 프로젝트와 워크스페이스로 옮기기".

### Task 4: Menu, offer, messages, debug command

**Files:**
- Modify: `Sources/PlumKit/UI/AppActions.swift`, `Sources/PlumKit/UI/App.swift` (File menu ~line 326, launch ~line 60, actions ~line 501), `Sources/PlumKit/Model/DebugCommands.swift`, `Resources/en.lproj/Localizable.strings`, `README.md`, `README.ko.md`

**Interfaces:**
- Consumes: `OrcaImport.cli()`, `.version()`, `.load(cli:)`, `AppModel.importFromOrca(_:)`, `AppActions.ask`, `Confirmation`.
- Produces: `static func importFromOrca(_ model: AppModel, quietly: Bool) async` in `AppActions`.

Flow: no CLI → (`quietly` ? nothing : error "Orca가 설치되어 있지 않습니다."). `load` → `.notRunning`: quietly nothing, else error "Orca를 켠 뒤 다시 시도해 주세요."; `.unreadable`: quietly nothing, else error "Orca의 출력을 읽지 못해 가져오지 않았습니다 (Orca \(version))." Empty catalog: quietly nothing, else notice "Orca에 가져올 저장소가 없습니다." Otherwise ask `Confirmation(title: "Orca에서 가져올까요?", summary: "저장소 \(repos)개와 워크트리 \(worktrees)개를 Plum 목록에 더합니다. 디스크의 파일은 바뀌지 않습니다.", sections: [.init(title: "저장소", lines: repo names)], action: "가져오기", destructive: false)`; yes → import → notice "저장소 \(projects)개와 워크트리 \(workspaces)개를 가져왔습니다." plus, when `detached + missing > 0`, " 브랜치가 없는 워크트리 \(detached)개와 폴더가 없는 워크트리 \(missing)개는 건너뛰었습니다."

English (add each to `Localizable.strings`, checking the key isn't there already): "Orca에서 가져오기…" = "Import from Orca…"; "Orca가 설치되어 있지 않습니다." = "Orca isn't installed."; "Orca를 켠 뒤 다시 시도해 주세요." = "Open Orca, then try again."; "Orca의 출력을 읽지 못해 가져오지 않았습니다 (Orca %@)." = "Couldn't read Orca's output, so nothing was imported (Orca %@)."; "Orca에 가져올 저장소가 없습니다." = "Orca has no repositories to import."; "Orca에서 가져올까요?" = "Import from Orca?"; summary = "Adds %lld repositories and %lld worktrees to Plum's list. Nothing on disk changes."; "저장소" = "Repositories"; "가져오기" = "Import"; result = "Imported %lld repositories and %lld worktrees."; skipped = " Skipped %lld worktrees without a branch and %lld whose folder is gone."

- [ ] **Step 1:** `AppActions.importFromOrca(_:quietly:)` as above.
- [ ] **Step 2:** File menu item "Orca에서 가져오기…" right after "프로젝트 추가…", `@objc private func importFromOrca()` → `Task { await AppActions.importFromOrca(model, quietly: false) }`.
- [ ] **Step 3:** First-launch offer after the daily update check: `if !debug, model.state.projects.isEmpty, !UserDefaults.standard.bool(forKey: "offeredOrcaImport"), OrcaImport.cli() != nil` → set `offeredOrcaImport` true, `Task { await AppActions.importFromOrca(model, quietly: true) }`.
- [ ] **Step 4:** Debug command `case "import-orca": // imports from Orca without asking (its CLI, read-only); the result lands in "result"` → runs `cli()`/`load`/`importFromOrca` in a `Task`, sets `debugResult` to `"projects=N workspaces=M detached=D missing=K"` or the failure, returns `"started"`.
- [ ] **Step 5:** Strings and README: one line under "Using it" in both READMEs (File → Import from Orca…, needs Orca running, nothing on disk changes).
- [ ] **Step 6: Verify.** `swift build` clean; `swift test` all pass; `debug menus` in the test copy lists "Orca에서 가져오기…" under 파일. In the test copy (temp state, `harness/start.sh`), `debug import-orca`, then `debug state`: the projects and workspaces match what `orca repo list --json` / `orca worktree list --json` show on this Mac minus folder/hidden repos, main checkouts and detached worktrees. Read-only against the real Orca; quit the test copy afterwards.
- [ ] **Step 7:** Commit "Orca 가져오기: 메뉴, 첫 실행 제안, 안내 문구".
