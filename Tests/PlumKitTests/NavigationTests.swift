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

    func testSavedTerminalsRemainRecoverableWhenTheHostIsUnavailable() throws {
        let checkout = directory.appendingPathComponent("checkout")
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        let store = Store(directory: directory.appendingPathComponent("recovery-state"))
        let project = Project(name: "checkout", path: checkout.path)
        let saved = SavedTab(id: UUID(), workspace: project.id, title: "running", active: true)
        var state = AppState()
        state.projects = [project]
        state.tabs = [saved]
        try store.save(state)

        let model = AppModel(store: store)
        model.select(project.id)
        XCTAssertNotNil(model.activeTab)
        XCTAssertEqual(store.load().tabs, [saved])
        model.activeTab?.session.terminate()
    }

    func testRestoresLegacyTabsButOpensNewTabsOnTheHardenedHost() throws {
        let checkout = directory.appendingPathComponent("dual-host-checkout")
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        let store = Store(directory: directory.appendingPathComponent("dual-host-state"))
        let project = Project(name: "checkout", path: checkout.path)
        let legacyID = UUID(), secureID = UUID()
        var state = AppState()
        state.projects = [project]
        state.tabs = [SavedTab(id: legacyID, workspace: project.id, title: "legacy", active: true),
                      SavedTab(id: secureID, workspace: project.id, title: "secure", active: false)]
        try store.save(state)

        let legacyPath = NSTemporaryDirectory() + "plum-test-legacy-\(UUID().uuidString.prefix(8)).sock"
        let securePath = NSTemporaryDirectory() + "plum-test-secure-\(UUID().uuidString.prefix(8)).sock"
        let legacyServer = TerminalHost(socketPath: legacyPath)
        let secureServer = TerminalHost(socketPath: securePath)
        try legacyServer.listen()
        try secureServer.listen()
        defer { unlink(legacyPath); unlink(securePath) }
        let legacyClient = try XCTUnwrap(TerminalHostClient(socketPath: legacyPath, executable: "/nonexistent"))
        let secureClient = try XCTUnwrap(TerminalHostClient(socketPath: securePath, executable: "/nonexistent"))
        let environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "ZDOTDIR": "/nonexistent"]
        let legacyShell = try XCTUnwrap(legacyClient.open(id: legacyID, workspace: project.id, shell: "/bin/zsh",
                                                          cwd: checkout.path, environment: environment, cols: 80, rows: 24, command: nil))
        let secureShell = try XCTUnwrap(secureClient.open(id: secureID, workspace: project.id, shell: "/bin/zsh",
                                                          cwd: checkout.path, environment: environment, cols: 80, rows: 24, command: nil))
        close(legacyShell.fd)
        close(secureShell.fd)
        defer {
            for session in legacyClient.list() { legacyClient.close(session.id) }
            for session in secureClient.list() { secureClient.close(session.id) }
        }

        let model = AppModel(store: store)
        model.restoreTabs(secureHost: secureClient, legacyHost: legacyClient)
        XCTAssertEqual(Set(model.tabs[project.id, default: []].map(\.id)), Set([legacyID, secureID]))
        XCTAssertEqual(model.tabs[project.id]?.first(where: { $0.id == legacyID })?.customTitle, "legacy")

        let fresh = try XCTUnwrap(model.openTab(in: project.id))
        XCTAssertTrue(secureClient.list().contains { $0.id == fresh.id })
        XCTAssertFalse(legacyClient.list().contains { $0.id == fresh.id })
    }

    func testNewTabReconnectsTheHardenedHostAfterStartupFailure() throws {
        let checkout = directory.appendingPathComponent("retry-host-checkout")
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        let store = Store(directory: directory.appendingPathComponent("retry-host-state"))
        let project = Project(name: "checkout", path: checkout.path)
        var state = AppState()
        state.projects = [project]
        try store.save(state)
        let securePath = TerminalHost.socketPath(for: store)
        let secureServer = TerminalHost(socketPath: securePath)
        try secureServer.listen()
        defer { unlink(securePath) }
        let secureClient = try XCTUnwrap(TerminalHostClient(socketPath: securePath, executable: "/nonexistent"))
        defer { for session in secureClient.list() { secureClient.close(session.id) } }

        let model = AppModel(store: store)
        model.terminalHostExecutable = "/nonexistent"
        model.restoreTabs(secureHost: nil, legacyHost: nil)
        let fresh = try XCTUnwrap(model.openTab(in: project.id))

        XCTAssertTrue(secureClient.list().contains { $0.id == fresh.id })
    }

    func testMissingLegacyHostDoesNotEraseSavedTabs() throws {
        let store = Store(directory: directory.appendingPathComponent("missing-legacy-state"))
        let project = Project(name: "checkout", path: directory.path)
        let saved = SavedTab(id: UUID(), workspace: project.id, title: "legacy", active: true)
        let other = SavedTab(id: UUID(), workspace: project.id, title: "other", active: false)
        var state = AppState()
        state.projects = [project]
        state.tabs = [saved, other]
        let split = SplitNode.split(.horizontal, ratio: 0.5, .pane(saved.id), .pane(other.id))
        state.splits = [saved.id.uuidString: split]
        try store.save(state)

        let securePath = NSTemporaryDirectory() + "plum-test-recovery-\(UUID().uuidString.prefix(8)).sock"
        let secureServer = TerminalHost(socketPath: securePath)
        try secureServer.listen()
        defer { unlink(securePath) }
        let secureClient = try XCTUnwrap(TerminalHostClient(socketPath: securePath, executable: "/nonexistent"))
        defer { for session in secureClient.list() { secureClient.close(session.id) } }

        let model = AppModel(store: store)
        model.restoreTabs(secureHost: secureClient, legacyHost: nil)

        XCTAssertEqual(store.load().tabs, [saved, other])
        XCTAssertEqual(store.load().splits[saved.id.uuidString], split)
        let fresh = try XCTUnwrap(model.openTab(in: project.id))
        XCTAssertEqual(Set(store.load().tabs.map(\.id)), Set([saved.id, other.id, fresh.id]))
        XCTAssertEqual(store.load().splits[saved.id.uuidString], split)
    }

    func testUnknownWorkspaceDoesNotCloseARunningLegacySession() throws {
        let store = Store(directory: directory.appendingPathComponent("unknown-workspace-state"))
        let oldPath = NSTemporaryDirectory() + "plum-test-unknown-\(UUID().uuidString.prefix(8)).sock"
        let oldServer = TerminalHost(socketPath: oldPath)
        try oldServer.listen()
        defer { unlink(oldPath) }
        let oldClient = try XCTUnwrap(TerminalHostClient(socketPath: oldPath, executable: "/nonexistent"))
        let id = UUID()
        let opened = try XCTUnwrap(oldClient.open(id: id, workspace: UUID(), shell: "/bin/zsh", cwd: directory.path,
                                                  environment: ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "ZDOTDIR": "/nonexistent"],
                                                  cols: 80, rows: 24, command: nil))
        close(opened.fd)
        defer { oldClient.close(id) }

        let model = AppModel(store: store)
        model.restoreTabs(secureHost: nil, legacyHost: oldClient)
        Thread.sleep(forTimeInterval: 0.3)

        XCTAssertTrue(oldClient.list().contains { $0.id == id })
    }

    func testEmptyHostReplyDoesNotEraseSavedTabs() throws {
        let store = Store(directory: directory.appendingPathComponent("empty-host-state"))
        let project = Project(name: "checkout", path: directory.path)
        let saved = SavedTab(id: UUID(), workspace: project.id, title: "running", active: true)
        var state = AppState()
        state.projects = [project]
        state.tabs = [saved]
        try store.save(state)

        let securePath = NSTemporaryDirectory() + "plum-test-empty-secure-\(UUID().uuidString.prefix(8)).sock"
        let legacyPath = NSTemporaryDirectory() + "plum-test-empty-legacy-\(UUID().uuidString.prefix(8)).sock"
        let secureServer = TerminalHost(socketPath: securePath)
        let legacyServer = TerminalHost(socketPath: legacyPath)
        try secureServer.listen()
        try legacyServer.listen()
        defer { unlink(securePath); unlink(legacyPath) }
        let secureClient = try XCTUnwrap(TerminalHostClient(socketPath: securePath, executable: "/nonexistent"))
        let legacyClient = try XCTUnwrap(TerminalHostClient(socketPath: legacyPath, executable: "/nonexistent"))

        let model = AppModel(store: store)
        model.restoreTabs(secureHost: secureClient, legacyHost: legacyClient)

        XCTAssertEqual(store.load().tabs, [saved])
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
