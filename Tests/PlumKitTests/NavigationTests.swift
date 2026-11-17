import XCTest
@testable import PlumKit

/// Moving between workspaces: order, numbers, history, reordering, the switcher.
/// The folders don't exist, so selecting a workspace opens no shell.
@MainActor
final class NavigationTests: XCTestCase {
    private var directory: URL!
    private var order: [UUID] = []
    private var model: AppModel!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("plum-nav-\(UUID().uuidString)")
        var state = AppState()
        let a = Project(name: "alpha", path: "/nonexistent/alpha")
        let b = Project(name: "beta", path: "/nonexistent/beta")
        let one = Workspace(projectID: a.id, name: "one", branch: "x/one", path: "/nonexistent/one")
        let two = Workspace(projectID: a.id, name: "two", branch: "x/two", path: "/nonexistent/two")
        var old = Workspace(projectID: a.id, name: "old", branch: "x/old", path: "/nonexistent/old")
        old.isArchived = true
        state.projects = [a, b]
        state.workspaces = [one, old, two]
        try Store(directory: directory).save(state)
        model = AppModel(store: Store(directory: directory))
        // Sidebar order: each project's main checkout (its id), then its workspaces.
        order = [a.id, one.id, two.id, b.id]
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testOrderNumbersAndWrapping() {
        XCTAssertEqual(model.workspaceOrder, order, "archived workspaces are skipped")
        model.selectWorkspace(at: 2)
        XCTAssertEqual(model.selection, order[2])
        model.selectWorkspace(at: nil) // ⌘9: the last
        XCTAssertEqual(model.selection, order.last)
        model.selectWorkspace(at: 7) // no 8th: stays
        XCTAssertEqual(model.selection, order.last)
        model.selectWorkspace(offset: 1)
        XCTAssertEqual(model.selection, order[0], "wraps around")
        model.selectWorkspace(offset: -1)
        XCTAssertEqual(model.selection, order.last)
    }

    func testBackForwardAndLastPlace() {
        for index in 0...2 { model.selectWorkspace(at: index) }
        model.goBack()
        XCTAssertEqual(model.selection, order[1])
        model.goBack()
        XCTAssertEqual(model.selection, order[0])
        model.goForward()
        XCTAssertEqual(model.selection, order[1])

        model.selectWorkspace(at: 3) // a new place drops the way forward
        model.goForward()
        XCTAssertEqual(model.selection, order[3])

        model.goToLastPlace()
        XCTAssertEqual(model.selection, order[1])
        model.goToLastPlace() // and back again
        XCTAssertEqual(model.selection, order[3])
    }

    func testMovingWorkspacesKeepsTheMainCheckoutFirstAndIsSaved() {
        model.moveWorkspace(order[2], by: -1)
        XCTAssertEqual(model.workspaceOrder, [order[0], order[2], order[1], order[3]])
        model.moveWorkspace(order[2], by: -1) // can't pass the main checkout
        XCTAssertEqual(model.workspaceOrder, [order[0], order[2], order[1], order[3]])
        model.moveWorkspace(order[1], by: 1) // already last in its project
        XCTAssertEqual(model.workspaceOrder, [order[0], order[2], order[1], order[3]])
        XCTAssertEqual(AppModel(store: Store(directory: directory)).workspaceOrder, model.workspaceOrder)
    }

    func testSwitcherPutsRecentFirstAndRanksMatches() {
        model.selectWorkspace(at: 1)
        model.selectWorkspace(at: 2)
        let names = { (query: String) in WorkspaceSwitcher.entries(self.model, query: query).map(\.name) }
        XCTAssertEqual(names(""), ["one", "main", "main", "two"], "recent, then the rest, then the current one")
        XCTAssertEqual(names("tw").first, "two", "a name starting with the query comes first")
        XCTAssertEqual(names("x/o"), ["one"], "branches match; archived ones are not offered")
        XCTAssertEqual(names("oe"), ["one"], "letters in order")
        XCTAssertEqual(names("zzz"), [])
    }
}
