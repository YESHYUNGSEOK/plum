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

    func testMovingWorkspacesAndTheMainCheckoutIsSaved() {
        model.moveWorkspace(order[2], by: -1)
        XCTAssertEqual(model.workspaceOrder, [order[0], order[2], order[1], order[3]])
        model.moveWorkspace(order[2], by: -1) // past the main checkout: it moves too
        XCTAssertEqual(model.workspaceOrder, [order[2], order[0], order[1], order[3]])
        model.moveWorkspace(order[2], by: -1) // already first in its project
        model.moveWorkspace(order[1], by: 1) // already last
        XCTAssertEqual(model.workspaceOrder, [order[2], order[0], order[1], order[3]])
        model.moveWorkspace(order[0], by: 1) // the main checkout itself
        XCTAssertEqual(model.workspaceOrder, [order[2], order[1], order[0], order[3]])
        XCTAssertEqual(AppModel(store: Store(directory: directory)).workspaceOrder, model.workspaceOrder)
    }

    /// A drag can carry a workspace past several others, over archived ones
    /// and other projects' in the saved list.
    func testMovingSeveralPlacesAtOnce() throws {
        let a = Project(name: "alpha", path: "/nonexistent/alpha")
        let b = Project(name: "beta", path: "/nonexistent/beta")
        let names = ["one", "two", "three"]
        var listed = names.map { Workspace(projectID: a.id, name: $0, branch: "x/\($0)", path: "/nonexistent/\($0)") }
        var old = Workspace(projectID: a.id, name: "old", branch: "x/old", path: "/nonexistent/old")
        old.isArchived = true
        let other = Workspace(projectID: b.id, name: "other", branch: "x/other", path: "/nonexistent/other")
        listed.insert(old, at: 1)
        listed.insert(other, at: 3)
        var state = AppState()
        state.projects = [a, b]
        state.workspaces = listed // one, old, two, other, three
        try Store(directory: directory).save(state)
        let model = AppModel(store: Store(directory: directory))
        let rows = { model.workspaces(in: a).map { $0.id == a.id ? "main" : $0.name } }

        model.moveWorkspace(listed[0].id, by: 2)
        XCTAssertEqual(rows(), ["main", "two", "three", "one"])
        model.moveWorkspace(listed[0].id, by: -2)
        XCTAssertEqual(rows(), ["main", "one", "two", "three"])
        model.moveWorkspace(listed[4].id, by: -3) // past the main checkout
        XCTAssertEqual(rows(), ["three", "main", "one", "two"])
        model.moveWorkspace(a.id, by: 2) // the main checkout, two down
        XCTAssertEqual(rows(), ["three", "one", "two", "main"])
        XCTAssertEqual(model.workspaces(in: a, archived: true).map(\.name), ["old"])
        XCTAssertEqual(model.workspaces(in: b).map(\.name), ["main", "other"], "another project's order is its own")
        let reloaded = AppModel(store: Store(directory: directory))
        XCTAssertEqual(reloaded.workspaces(in: reloaded.state.projects[0]).map { $0.id == a.id ? "main" : $0.name }, rows())
    }

    func testRenamingChangesOnlyTheNameAndIsSaved() {
        let one = order[1]
        XCTAssertNil(model.renameWorkspace(one, to: "  first  "))
        let renamed = model.state.workspaces.first { $0.id == one }
        XCTAssertEqual(renamed?.name, "first", "trimmed")
        XCTAssertEqual(renamed?.branch, "x/one", "the branch stays")
        XCTAssertEqual(renamed?.path, "/nonexistent/one", "the folder stays")
        XCTAssertNotNil(model.renameWorkspace(one, to: "two"), "another workspace of the project has that name")
        XCTAssertNil(model.renameWorkspace(one, to: "   "), "blank: nothing happens")
        XCTAssertNotNil(model.renameWorkspace(order[0], to: "first"), "the main checkout is checked against the rest too")
        XCTAssertNil(model.renameWorkspace(order[0], to: "base"))
        XCTAssertEqual(model.workspace(order[0])?.name, "base", "the main checkout can be renamed")
        XCTAssertEqual(model.workspace(order[0])?.path, "/nonexistent/alpha")
        XCTAssertNotNil(model.renameWorkspace(one, to: "base"))
        let reloaded = AppModel(store: Store(directory: directory))
        XCTAssertEqual(reloaded.workspace(one)?.name, "first")
        XCTAssertEqual(reloaded.workspace(order[0])?.name, "base")
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
