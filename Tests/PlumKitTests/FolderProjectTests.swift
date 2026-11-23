import XCTest
@testable import PlumKit

/// A folder that isn't a git repository, opened as a project as in Orca:
/// its workspaces are named sets of tabs in that same folder.
@MainActor
final class FolderProjectTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("plum-folder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testANonGitFolderIsAddedOnlyWhenOpenedAsAFolder() throws {
        let folder = directory.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let model = AppModel(store: Store(directory: directory.appendingPathComponent("state")))

        model.addProject(at: folder.path)
        XCTAssertTrue(model.state.projects.isEmpty, "not a git repository: refused unless asked for as a folder")
        XCTAssertNotNil(model.errorMessage)

        model.addProject(at: folder.path, asFolder: true)
        let project = try XCTUnwrap(model.state.projects.first)
        XCTAssertTrue(project.isFolder)
        XCTAssertEqual(project.name, "project")
        XCTAssertTrue(WorkspaceService.samePath(project.path, folder.path))

        let reloaded = AppModel(store: Store(directory: directory.appendingPathComponent("state")))
        XCTAssertEqual(reloaded.state.projects.first?.isFolder, true, "saved")
    }

    func testAnOldStateFileLoadsWithGitProjects() throws {
        let json = """
        {"projects":[{"id":"11111111-1111-1111-1111-111111111111","name":"app","path":"/nonexistent/app","baseBranch":"",
        "copyPatterns":[],"setupCommand":"","agentCommand":""}],"workspaces":[],"settings":{}}
        """
        try Data(json.utf8).write(to: directory.appendingPathComponent("state.json"))
        let model = AppModel(store: Store(directory: directory))
        XCTAssertEqual(model.state.projects.map(\.isFolder), [false])
    }

    func testFolderWorkspacesShareTheFolderAndDeletingOneLeavesItAlone() async throws {
        var project = Project(name: "project", path: directory.path)
        project.folder = true
        var state = AppState()
        state.projects = [project]
        try Store(directory: directory.appendingPathComponent("state")).save(state)
        try "keep".write(to: directory.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        let model = AppModel(store: Store(directory: directory.appendingPathComponent("state")))

        let problem = await model.problemCreatingWorkspace(projectID: project.id, name: " ", branch: "", choice: .new(base: nil))
        XCTAssertNotNil(problem, "a name is needed")
        try await model.createWorkspace(projectID: project.id, name: "one", branch: "", choice: .new(base: nil), program: .terminal)
        try await model.createWorkspace(projectID: project.id, name: "two", branch: "", choice: .new(base: nil), program: .terminal)
        XCTAssertEqual(model.state.workspaces.map(\.name), ["one", "two"])
        XCTAssertTrue(model.state.workspaces.allSatisfy { $0.path == project.path && $0.branch.isEmpty }, "the same folder, no branch")
        let again = await model.problemCreatingWorkspace(projectID: project.id, name: "one", branch: "", choice: .new(base: nil))
        XCTAssertNotNil(again, "names stay unique in a project")

        let one = model.state.workspaces[0]
        XCTAssertEqual(model.tabs[one.id]?.count, 1, "its first tab opened")
        try await model.archive(one.id, force: true)
        XCTAssertFalse(model.state.workspaces[0].isArchived, "nothing to archive: there is no worktree")
        let kept = try await model.delete(one.id, force: true)
        XCTAssertEqual(kept, [])
        XCTAssertEqual(model.state.workspaces.map(\.name), ["two"])
        XCTAssertNil(model.tabs[one.id], "its tabs closed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("notes.txt").path), "the folder stays")
        for tab in model.tabs.values.joined() { model.closeTab(tab.id) }
    }

    func testGitIsNeverAskedAboutAFolderProject() async throws {
        // A folder inside a repository: git would walk up and report the repository's changes.
        let repo = directory.appendingPathComponent("repo")
        let folder = repo.appendingPathComponent("inside")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Git.run(["init", "-q", "-b", "main"], in: repo.path)
        try "hi".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try Git.run(["add", "."], in: repo.path)
        try Git.run(["-c", "user.email=t@e", "-c", "user.name=T", "commit", "-qm", "init"], in: repo.path)
        try "changed".write(to: folder.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        XCTAssertNotNil(Git.changes(in: folder.path), "git does answer for the folder")

        var project = Project(name: "inside", path: folder.path)
        project.folder = true
        var state = AppState()
        state.projects = [project]
        try Store(directory: directory.appendingPathComponent("state")).save(state)
        let model = AppModel(store: Store(directory: directory.appendingPathComponent("state")))
        model.refreshChanges(project.id)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertNil(model.changes[project.id], "not counted: the repository above isn't this project")
    }
}
