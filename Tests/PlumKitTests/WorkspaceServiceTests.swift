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
        try Git.deleteBranch("eric/task", in: project.path)
        XCTAssertFalse(Git.branchExists("eric/task", in: project.path))
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

    func testStatusMessageParsing() {
        let id = UUID()
        XCTAssertEqual(StatusMessage.parse("\(id) waiting needs \u{1b}[31mapproval\n")?.message, "needs [31mapproval")
        XCTAssertEqual(StatusMessage.parse("\(id) working")?.status, .working)
        XCTAssertNil(StatusMessage.parse("\(id) exploded"))
        XCTAssertNil(StatusMessage.parse("not-a-uuid done"))
        XCTAssertNil(StatusMessage.parse(""))
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
