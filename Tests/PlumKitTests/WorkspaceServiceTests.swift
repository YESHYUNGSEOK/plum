import XCTest
@testable import PlumKit

final class WorkspaceServiceTests: XCTestCase {
    private var sandbox: URL!
    private var project: Project!
    private var root: String { sandbox.appendingPathComponent("workspaces").path }

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory.appendingPathComponent("plum-test-\(UUID().uuidString)")
        let repo = sandbox.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try Git.run(["init", "-q", "-b", "main"], in: repo.path)
        try Git.run(["config", "user.email", "test@example.com"], in: repo.path)
        try Git.run(["config", "user.name", "Test"], in: repo.path)
        try "hello".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try ".env*\nnode_modules\n".write(to: repo.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try Git.run(["add", "."], in: repo.path)
        try Git.run(["commit", "-q", "-m", "init"], in: repo.path)
        try "SECRET=1".write(to: repo.appendingPathComponent(".env.local"), atomically: true, encoding: .utf8)
        project = Project(name: "repo", path: repo.path)
        project.copyPatterns = [".env*", "../outside", "/etc/hosts"]
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sandbox)
    }

    private func create(_ name: String, branch: String? = nil, choice: WorkspaceService.BranchChoice = .new(base: nil),
                        existing: [Workspace] = []) throws -> WorkspaceService.Created {
        try WorkspaceService.create(
            project: project, name: name, branch: branch ?? WorkspaceNaming.branchName(for: name, prefix: "eric/"),
            choice: choice, root: root, existing: existing)
    }

    func testCreateMakesWorktreeBranchAndCopiesFiles() throws {
        let created = try create("결제 화면 Phase 2")
        let ws = created.workspace
        XCTAssertEqual(ws.branch, "eric/결제-화면-Phase-2")
        XCTAssertTrue(ws.path.hasSuffix("/workspaces/repo/결제-화면-Phase-2"), ws.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: ws.path + "/README.md"))
        XCTAssertEqual(created.copiedFiles, [".env.local"])
        XCTAssertEqual(created.rejectedPatterns, ["../outside", "/etc/hosts"])
        XCTAssertEqual(try String(contentsOfFile: ws.path + "/.env.local"), "SECRET=1")
        XCTAssertEqual(try Git.run(["branch", "--show-current"], in: ws.path), "eric/결제-화면-Phase-2")
        // A new branch must not track the base branch.
        XCTAssertThrowsError(try Git.run(["rev-parse", "--abbrev-ref", "@{upstream}"], in: ws.path))
    }

    func testCreateRejectsDuplicatesAndBadNames() throws {
        let first = try create("feature").workspace
        XCTAssertThrowsError(try create("feature", existing: [first]))
        XCTAssertThrowsError(try create("other", branch: "eric/feature")) // branch exists
        XCTAssertThrowsError(try create("  "))
        XCTAssertThrowsError(try create(".."))
        XCTAssertThrowsError(try create("x", branch: "bad..name"))
        XCTAssertThrowsError(try create("x", branch: "-rf"))
    }

    func testCreateReportsItsStepsInOrder() throws {
        var steps: [WorkspaceService.CreateStep] = []
        _ = try WorkspaceService.create(
            project: project, name: "steps", branch: "eric/steps", choice: .new(base: nil), root: root, existing: []
        ) { steps.append($0) }
        XCTAssertEqual(steps, [.fetch, .worktree, .copy])

        project.copyPatterns = []
        steps = []
        try Git.run(["branch", "eric/other"], in: project.path)
        _ = try WorkspaceService.create(
            project: project, name: "again", branch: "eric/other", choice: .existing, root: root, existing: []
        ) { steps.append($0) }
        XCTAssertEqual(steps, [.worktree], "no fetch for an existing branch, no copy without patterns")
    }

    func testLossLinesSplitIntoCodeAndRest() {
        let modified = Confirmation.split(" M Sources/a b.swift", maxCode: 2)
        XCTAssertEqual(modified.code, "M")
        XCTAssertEqual(modified.rest, "Sources/a b.swift")
        XCTAssertEqual(Confirmation.split("?? new.txt", maxCode: 2).code, "??")
        let commit = Confirmation.split("a1c9e27 사이드바 행 높이 조정", maxCode: 40)
        XCTAssertEqual(commit.code, "a1c9e27")
        XCTAssertEqual(commit.rest, "사이드바 행 높이 조정")
        // An error line has no short code: shown whole.
        let failure = Confirmation.split("상태를 확인하지 못했습니다: 권한 없음", maxCode: 2)
        XCTAssertEqual(failure.code, "")
        XCTAssertEqual(failure.rest, "상태를 확인하지 못했습니다: 권한 없음")
    }

    func testExistingBranchCheckout() throws {
        try Git.run(["branch", "review/pr-1"], in: project.path)
        let ws = try create("pr-1", branch: "review/pr-1", choice: .existing).workspace
        XCTAssertEqual(try Git.run(["branch", "--show-current"], in: ws.path), "review/pr-1")
    }

    func testCleanArchiveThenRestoreThenDelete() throws {
        var ws = try create("task").workspace
        XCTAssertTrue(WorkspaceService.inspect(ws, project: project, deletingBranch: false).isClean)

        try WorkspaceService.removeWorktree(ws, project: project, force: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ws.path))
        XCTAssertTrue(Git.branchExists("eric/task", in: project.path), "archive keeps the branch")
        ws.isArchived = true

        let restored = try WorkspaceService.restore(ws, project: project)
        XCTAssertFalse(restored.workspace.isArchived)
        XCTAssertTrue(FileManager.default.fileExists(atPath: ws.path + "/README.md"))
        XCTAssertEqual(restored.copiedFiles, [".env.local"])

        try WorkspaceService.removeWorktree(restored.workspace, project: project, force: false)
        XCTAssertNil(Git.deleteBranchIfMerged("eric/task", in: project.path), "no commits of its own: merged")
        XCTAssertFalse(Git.branchExists("eric/task", in: project.path))
    }

    private func commit(_ file: String, _ text: String, in path: String, _ message: String) throws {
        try text.write(toFile: path + "/" + file, atomically: true, encoding: .utf8)
        try Git.run(["add", "."], in: path)
        try Git.run(["commit", "-q", "-m", message], in: path)
    }

    func testDeleteKeepsOnlyUnmergedBranchesAsOrcaDoes() throws {
        let kept = try create("kept").workspace
        try commit("kept.txt", "work", in: kept.path, "unmerged work")
        let merged = try create("merged").workspace
        try commit("merged.txt", "work", in: merged.path, "merged work")
        try Git.run(["merge", "-q", "--no-ff", "-m", "merge", "eric/merged"], in: project.path)
        let squashed = try create("squashed").workspace
        try commit("a.txt", "one", in: squashed.path, "first")
        try commit("b.txt", "two", in: squashed.path, "second")
        try Git.run(["merge", "-q", "--squash", "eric/squashed"], in: project.path)
        try Git.run(["commit", "-q", "-m", "squashed (#1)"], in: project.path)
        try commit("later.txt", "main moved on", in: project.path, "later")

        for ws in [kept, merged, squashed] {
            let left = try WorkspaceService.delete(ws, project: project, force: false, approvedNested: [])
            XCTAssertFalse(FileManager.default.fileExists(atPath: ws.path), ws.name)
            XCTAssertEqual(left.map(\.name), ws.name == "kept" ? ["eric/kept"] : [], ws.name)
        }
        XCTAssertTrue(Git.branchExists("eric/kept", in: project.path), "unmerged work stays")
        XCTAssertFalse(Git.branchExists("eric/merged", in: project.path))
        XCTAssertFalse(Git.branchExists("eric/squashed", in: project.path), "a squash merge counts as merged")

        // The offered "Delete Branch" only deletes the commit the user was told about.
        let head = try Git.run(["rev-parse", "eric/kept"], in: project.path)
        let other = try Git.run(["rev-parse", "main"], in: project.path)
        XCTAssertThrowsError(try Git.deleteBranch("eric/kept", at: other, in: project.path))
        XCTAssertTrue(Git.branchExists("eric/kept", in: project.path))
        try Git.deleteBranch("eric/kept", at: head, in: project.path)
        XCTAssertFalse(Git.branchExists("eric/kept", in: project.path))
    }

    func testABranchSquashMergedOnTheRemoteIsDeletedThoughMainWasNotPulled() throws {
        let origin = sandbox.appendingPathComponent("origin.git").path
        try Git.run(["init", "-q", "--bare", "-b", "main", origin], in: sandbox.path)
        try Git.run(["remote", "add", "origin", origin], in: project.path)
        try Git.run(["push", "-q", "origin", "main"], in: project.path)
        try Git.run(["remote", "set-head", "origin", "main"], in: project.path)

        let ws = try create("pr").workspace
        try commit("feature.txt", "work", in: ws.path, "feature")
        try Git.run(["push", "-q", "origin", "eric/pr"], in: ws.path)
        // Someone squash-merges the pull request on the remote.
        let other = sandbox.appendingPathComponent("other").path
        try Git.run(["clone", "-q", origin, other], in: sandbox.path)
        try Git.run(["-c", "user.email=t@example.com", "-c", "user.name=T", "merge", "-q", "--squash", "origin/eric/pr"], in: other)
        try Git.run(["-c", "user.email=t@example.com", "-c", "user.name=T", "commit", "-q", "-m", "feature (#2)"], in: other)
        try Git.run(["push", "-q", "origin", "main"], in: other)

        XCTAssertEqual(try WorkspaceService.delete(ws, project: project, force: false, approvedNested: []), [])
        XCTAssertFalse(Git.branchExists("eric/pr", in: project.path), "origin/main was fetched and holds the work")
    }

    func testDeleteTakesTheWorktreesInsideItsFolderFirst() throws {
        let outer = try create("outer").workspace
        let innerPath = outer.path + "/inner"
        try Git.run(["worktree", "add", "-q", "-b", "eric/inner", innerPath], in: project.path)
        try commit("inner.txt", "work", in: innerPath, "inner work")

        let check = WorkspaceService.inspect(outer, project: project, deletingBranch: false)
        XCTAssertEqual(check.nested.map(\.branch), ["eric/inner"])
        XCTAssertFalse(check.isClean, "the inner worktree shows as untracked")
        XCTAssertThrowsError(try WorkspaceService.delete(outer, project: project, force: true, approvedNested: []),
                             "not the list the user was shown")
        XCTAssertTrue(FileManager.default.fileExists(atPath: innerPath + "/inner.txt"), "nothing removed")

        let left = try WorkspaceService.delete(outer, project: project, force: true, approvedNested: check.nested)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outer.path))
        XCTAssertFalse(Git.worktrees(in: project.path).contains { $0.branch == "eric/inner" || $0.branch == "eric/outer" })
        XCTAssertEqual(left.map(\.name), ["eric/inner"], "unmerged: kept")
        XCTAssertFalse(Git.branchExists("eric/outer", in: project.path), "no commits of its own: merged")
    }

    func testDirtyWorktreeIsReportedAndNotRemovedWithoutForce() throws {
        let ws = try create("dirty").workspace
        try "edit".write(toFile: ws.path + "/README.md", atomically: true, encoding: .utf8)
        try "new".write(toFile: ws.path + "/untracked.txt", atomically: true, encoding: .utf8)

        let check = WorkspaceService.inspect(ws, project: project, deletingBranch: false)
        XCTAssertFalse(check.isClean)
        XCTAssertTrue(check.uncommitted.contains { $0.hasSuffix("README.md") })
        XCTAssertTrue(check.uncommitted.contains { $0.hasSuffix("untracked.txt") })

        XCTAssertThrowsError(try WorkspaceService.removeWorktree(ws, project: project, force: false))
        XCTAssertTrue(FileManager.default.fileExists(atPath: ws.path + "/untracked.txt"), "nothing lost without force")

        try WorkspaceService.removeWorktree(ws, project: project, force: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ws.path))
    }

    func testUnpushedCommitsAreReportedBeforeBranchDeletion() throws {
        let ws = try create("commits").workspace
        try "more".write(toFile: ws.path + "/file.txt", atomically: true, encoding: .utf8)
        try Git.run(["add", "."], in: ws.path)
        try Git.run(["commit", "-q", "-m", "local only work"], in: ws.path)

        let check = WorkspaceService.inspect(ws, project: project, deletingBranch: true)
        // No remote exists, so every commit on the branch is unpushed.
        XCTAssertTrue(check.unpushed.contains { $0.contains("local only work") }, "\(check.unpushed)")
        XCTAssertTrue(WorkspaceService.inspect(ws, project: project, deletingBranch: false).unpushed.isEmpty)
    }

    func testNeverRemovesMainCheckoutOrForeignFolders() throws {
        let main = Workspace(projectID: project.id, name: "main", branch: "main", path: project.path)
        XCTAssertThrowsError(try WorkspaceService.removeWorktree(main, project: project, force: true))
        XCTAssertTrue(FileManager.default.fileExists(atPath: project.path + "/README.md"))

        let foreign = sandbox.appendingPathComponent("not-a-worktree")
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        try "keep".write(to: foreign.appendingPathComponent("keep.txt"), atomically: true, encoding: .utf8)
        let bogus = Workspace(projectID: project.id, name: "bogus", branch: "x", path: foreign.path)
        XCTAssertThrowsError(try WorkspaceService.removeWorktree(bogus, project: project, force: true))
        XCTAssertTrue(FileManager.default.fileExists(atPath: foreign.appendingPathComponent("keep.txt").path))
    }

    func testFolderDeletedOutsideAppCanStillBeArchivedAndRestored() throws {
        var ws = try create("gone").workspace
        try FileManager.default.removeItem(atPath: ws.path)
        XCTAssertTrue(WorkspaceService.inspect(ws, project: project, deletingBranch: false).folderMissing)

        try WorkspaceService.removeWorktree(ws, project: project, force: false)
        XCTAssertFalse(Git.worktrees(in: project.path).contains { $0.branch == "eric/gone" }, "stale entry cleared")
        ws.isArchived = true
        _ = try WorkspaceService.restore(ws, project: project)
        XCTAssertTrue(FileManager.default.fileExists(atPath: ws.path + "/README.md"))
    }

    func testNaming() {
        XCTAssertEqual(WorkspaceNaming.branchName(for: " fix: login bug? ", prefix: ""), "fix-login-bug")
        XCTAssertEqual(WorkspaceNaming.branchName(for: "a..b//c.lock", prefix: "p/"), "p/a.b/c")
        XCTAssertEqual(WorkspaceNaming.branchName(for: "~^:", prefix: "p/"), "")
        XCTAssertEqual(WorkspaceNaming.folderName(for: "feat/login page"), "feat-login-page")
        XCTAssertNil(WorkspaceNaming.folderName(for: ".."))
        XCTAssertNil(WorkspaceNaming.worktreePath(root: "/tmp/r", project: "p", workspace: ""))
        XCTAssertEqual(WorkspaceNaming.worktreePath(root: "/tmp/r", project: "p", workspace: "w"), "/tmp/r/p/w")
    }

    func testTabTitle() {
        XCTAssertEqual(TabTitle.display("dev@macbook:~/work/shop-web", shell: "zsh"), "zsh")
        XCTAssertEqual(TabTitle.display("", shell: "zsh"), "zsh")
        XCTAssertEqual(TabTitle.display("claude", shell: "zsh"), "claude")
        XCTAssertEqual(TabTitle.display("vim notes@home.md", shell: "zsh"), "vim notes@home.md")
    }

    func testStatusMessageParsing() {
        let id = UUID()
        XCTAssertEqual(StatusMessage.parse("\(id) waiting needs \u{1b}[31mapproval\n")?.message, "needs [31mapproval")
        XCTAssertEqual(StatusMessage.parse("\(id) working")?.status, .working)
        XCTAssertNil(StatusMessage.parse("\(id) exploded"))
        XCTAssertNil(StatusMessage.parse("not-a-uuid done"))
        XCTAssertNil(StatusMessage.parse(""))
    }

    /// A finished turn is done, unless Claude Code says work is still in
    /// flight: a subagent keeps it working; a command, a monitor or a
    /// scheduled wakeup means it is monitoring.
    func testAStopIsDoneWorkingOrMonitoringByWhatIsStillInFlight() {
        let id = UUID()
        func stop(_ json: String) -> (AgentStatus, String)? {
            StatusMessage.parse("\(id) stop \(json)").map { ($0.status, $0.message) }
        }
        XCTAssertEqual(stop(#"{"last_assistant_message":"리팩터링을 마쳤습니다.","background_tasks":[],"session_crons":[]}"#)?.0, .done)
        XCTAssertEqual(stop(#"{"last_assistant_message":"리팩터링을 마쳤습니다.","background_tasks":[]}"#)?.1, "리팩터링을 마쳤습니다.", "the answer, for the notification")
        XCTAssertEqual(stop(#"{"background_tasks":[{"id":"t1","type":"shell","status":"running","command":"npm run dev"}]}"#)?.0, .monitoring)
        XCTAssertEqual(stop(#"{"background_tasks":[{"id":"t2","type":"monitor","status":"running"}]}"#)?.0, .monitoring)
        XCTAssertEqual(stop(#"{"background_tasks":[],"session_crons":[{"id":"c1","schedule":"*/5 * * * *","recurring":true}]}"#)?.0, .monitoring)
        XCTAssertEqual(stop(#"{"background_tasks":[{"id":"t3","type":"shell","status":"running"},{"id":"a1","type":"subagent","status":"running"}]}"#)?.0, .working)
        XCTAssertEqual(stop(#"{"background_tasks":[{"id":"t4","type":"shell","status":"completed"}]}"#)?.0, .done, "finished tasks don't count")
        XCTAssertEqual(stop("not json")?.0, .done)
        XCTAssertEqual(stop("")?.0, .done)
    }

    func testHookSettingsIsValidJSONWithExpectedEvents() throws {
        let object = try JSONSerialization.jsonObject(with: HookSettings.claudeSettings()) as? [String: Any]
        let hooks = try XCTUnwrap(object?["hooks"] as? [String: Any])
        XCTAssertEqual(Set(hooks.keys), ["UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure", "Notification", "Stop", "StopFailure", "SessionEnd"])
    }

    func testStoreRoundTripAndCorruptFileIsKept() throws {
        let store = Store(directory: sandbox.appendingPathComponent("state"))
        var state = AppState()
        state.projects = [project]
        state.settings.branchPrefix = "eric/"
        try store.save(state)
        XCTAssertEqual(store.load(), state)

        try "{not json".write(to: store.directory.appendingPathComponent("state.json"), atomically: true, encoding: .utf8)
        XCTAssertEqual(store.load(), AppState())
        let files = try FileManager.default.contentsOfDirectory(atPath: store.directory.path)
        XCTAssertTrue(files.contains { $0.hasPrefix("state.corrupt-") }, "\(files)")
    }
}
