import XCTest
@testable import PlumKit

/// What the sidebar shows about a workspace besides its name: changed lines,
/// the pull request, and folded projects.
@MainActor
final class WorkspaceDetailsTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("plum-details-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testChangesCountEditedLinesAndNewTextFiles() throws {
        let repo = directory.path
        try Git.run(["init", "-q", "-b", "main"], in: repo)
        try Git.run(["config", "user.email", "t@e"], in: repo)
        try Git.run(["config", "user.name", "T"], in: repo)
        XCTAssertNil(Git.changes(in: repo), "no commit yet: nothing to compare with")

        try "one\ntwo\nthree\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
        try Git.run(["add", "."], in: repo)
        try Git.run(["commit", "-qm", "init"], in: repo)
        XCTAssertEqual(Git.changes(in: repo), Git.Changes(added: 0, removed: 0))

        try "one\nTWO\nthree\nfour\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8) // +2 −1
        try "x\ny\nz".write(toFile: repo + "/new.txt", atomically: true, encoding: .utf8) // 3 lines, no final newline
        try Data([0, 1, 2, 10, 10]).write(to: URL(fileURLWithPath: repo + "/blob.bin")) // binary: not counted
        try "ignored\n".write(toFile: repo + "/.gitignore", atomically: true, encoding: .utf8) // 1 line
        try "a\nb\n".write(toFile: repo + "/ignored", atomically: true, encoding: .utf8)
        XCTAssertEqual(Git.changes(in: repo), Git.Changes(added: 2 + 3 + 1, removed: 1))
    }

    func testPullRequestsTakeEachBranchsNewestAndSkipForks() throws {
        let json = """
        [
          {"number": 9, "state": "OPEN", "isDraft": false, "url": "https://github.com/o/r/pull/9", "headRefName": "dev/a",
           "isCrossRepository": false, "statusCheckRollup": [
             {"__typename": "CheckRun", "status": "COMPLETED", "conclusion": "SUCCESS"},
             {"__typename": "CheckRun", "status": "IN_PROGRESS", "conclusion": ""}]},
          {"number": 7, "state": "MERGED", "isDraft": false, "url": "https://github.com/o/r/pull/7", "headRefName": "dev/a",
           "isCrossRepository": false, "statusCheckRollup": []},
          {"number": 6, "state": "OPEN", "isDraft": true, "url": "https://github.com/o/r/pull/6", "headRefName": "dev/b",
           "isCrossRepository": false, "statusCheckRollup": [{"__typename": "StatusContext", "state": "SUCCESS"}]},
          {"number": 5, "state": "OPEN", "isDraft": false, "url": "https://github.com/x/r/pull/5", "headRefName": "main",
           "isCrossRepository": true, "statusCheckRollup": []},
          {"number": 4, "state": "CLOSED", "isDraft": false, "url": "https://github.com/o/r/pull/4", "headRefName": "dev/c",
           "isCrossRepository": false, "statusCheckRollup": [
             {"__typename": "CheckRun", "status": "COMPLETED", "conclusion": "SUCCESS"},
             {"__typename": "StatusContext", "state": "ERROR"}]}
        ]
        """
        let found = try XCTUnwrap(GitHub.parse(Data(json.utf8)))
        XCTAssertEqual(found["dev/a"]?.number, 9, "the newest of the branch's pull requests")
        XCTAssertEqual(found["dev/a"]?.state, .open)
        XCTAssertEqual(found["dev/a"]?.checks, .pending)
        XCTAssertEqual(found["dev/b"]?.state, .draft)
        XCTAssertEqual(found["dev/b"]?.checks, .passing)
        XCTAssertNil(found["main"], "a fork's branch of the same name isn't this repository's")
        XCTAssertEqual(found["dev/c"]?.state, .closed)
        XCTAssertEqual(found["dev/c"]?.checks, .failing)
        XCTAssertNil(GitHub.parse(Data("not json".utf8)))
    }

    func testATabsOwnTitleWinsAndAnEmptyOneGivesTheProgramsBack() throws {
        var state = AppState()
        let project = Project(name: "here", path: directory.path)
        state.projects = [project]
        let store = Store(directory: directory.appendingPathComponent("state"))
        try store.save(state)
        let model = AppModel(store: store)
        let tab = try XCTUnwrap(model.openTab(in: project.id))
        defer { model.closeTab(tab.id) }
        let programs = TabTitle.label(tab)

        model.renameTab(tab.id, to: "  dev server ")
        XCTAssertEqual(TabTitle.label(tab), "dev server", "trimmed, and shown instead of the program's")
        model.renameTab(tab.id, to: " ")
        XCTAssertNil(tab.customTitle)
        XCTAssertEqual(TabTitle.label(tab), programs)
    }

    func testFoldedProjectsLeaveTheOrderAndAreSaved() throws {
        var state = AppState()
        let a = Project(name: "alpha", path: "/nonexistent/alpha")
        let b = Project(name: "beta", path: "/nonexistent/beta")
        let one = Workspace(projectID: a.id, name: "one", branch: "x/one", path: "/nonexistent/one")
        state.projects = [a, b]
        state.workspaces = [one]
        try Store(directory: directory).save(state)
        let model = AppModel(store: Store(directory: directory))
        XCTAssertEqual(model.workspaceOrder, [a.id, one.id, b.id])

        model.setCollapsed(a.id, true)
        XCTAssertEqual(model.workspaceOrder, [b.id], "⌘1 is the first row you can see")
        XCTAssertEqual(AppModel(store: Store(directory: directory)).state.collapsedProjects, [a.id])
        model.setCollapsed(a.id, false)
        XCTAssertEqual(model.workspaceOrder, [a.id, one.id, b.id])
    }
}
