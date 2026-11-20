import XCTest
@testable import PlumKit

@MainActor
final class SplitTests: XCTestCase {
    func testTheTreeSplitsRemovesAndPlacesPanes() {
        let (a, b, c) = (UUID(), UUID(), UUID())
        var node = SplitNode.pane(a).replacing(a, with: .split(.horizontal, ratio: 0.5, .pane(a), .pane(b)))
        node = node.replacing(b, with: .split(.vertical, ratio: 0.5, .pane(b), .pane(c)))
        XCTAssertEqual(node.panes, [a, b, c])
        let frames = node.frames()
        XCTAssertEqual(frames[a], CGRect(x: 0, y: 0, width: 0.5, height: 1))
        XCTAssertEqual(frames[c], CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5))
        XCTAssertEqual(node.neighbor(of: a, dx: 1, dy: 0).map { [b, c].contains($0) }, true)
        XCTAssertEqual(node.neighbor(of: b, dx: 0, dy: 1), c)
        XCTAssertEqual(node.neighbor(of: c, dx: -1, dy: 0), a)
        XCTAssertNil(node.neighbor(of: a, dx: -1, dy: 0))
        // The sibling takes the removed pane's place.
        XCTAssertEqual(node.removing(b), .split(.horizontal, ratio: 0.5, .pane(a), .pane(c)))
        XCTAssertEqual(node.removing(b)?.removing(c), .pane(a))
        XCTAssertEqual(node.settingRatio(0.7, at: [true]).frames()[b]?.height ?? 0, 0.7, accuracy: 1e-9)
        XCTAssertEqual(node.settingRatio(0.99, at: []).frames()[a]?.width, 0.9, "kept usable")
    }

    func testPanesSplitCloseAndComeBackAfterARestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("plum-split-\(UUID().uuidString)")
        let repo = directory.appendingPathComponent("repo").path
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Git.run(["init", "-q", "-b", "main"], in: repo)
        let model = AppModel(store: Store(directory: directory.appendingPathComponent("state")))
        model.addProject(at: repo)
        let workspace = try XCTUnwrap(model.selection)
        let first = try XCTUnwrap(model.activeTab)
        let other = try XCTUnwrap(model.openTab(in: workspace))
        model.activateTab(first.id)

        let right = try XCTUnwrap(model.splitPane(.horizontal))
        let below = try XCTUnwrap(model.splitPane(.vertical))
        XCTAssertEqual(model.activeTab?.id, below.id, "the new pane has the keyboard")
        XCTAssertEqual(model.panes(ofTab: first.id), [first.id, right.id, below.id])
        XCTAssertEqual(model.tabBarTabs(in: workspace).map(\.id), [first.id, other.id], "one tab in the bar for the split")
        XCTAssertEqual(model.head(of: below.id), first.id)
        XCTAssertEqual(model.state.splits[first.id.uuidString]?.panes, [first.id, right.id, below.id], "saved")

        model.focusPane(dx: -1, dy: 0)
        XCTAssertEqual(model.activeTab?.id, first.id)
        model.cycleTab(1)
        XCTAssertEqual(model.activeTab?.id, other.id)
        model.cycleTab(1)
        XCTAssertEqual(model.activeTab?.id, first.id, "back to the pane last used in the split")

        // Closing the head: the next pane heads the split, in its place.
        model.closeTab(first.id)
        XCTAssertEqual(model.tabBarTabs(in: workspace).map(\.id), [right.id, other.id])
        XCTAssertEqual(model.panes(ofTab: right.id), [right.id, below.id])
        XCTAssertEqual(model.activeTab?.id, right.id, "the keyboard stays in the split")
        model.closeTab(below.id)
        XCTAssertNil(model.splits[right.id], "one pane left: no split")
        for tab in model.tabs[workspace] ?? [] { model.closeTab(tab.id) }
    }

    func testSavedSplitsKeepOnlyTerminalsThatCameBack() {
        let (a, b, c) = (UUID(), UUID(), UUID())
        let node = SplitNode.split(.horizontal, ratio: 0.4, .pane(a), .split(.vertical, ratio: 0.5, .pane(b), .pane(c)))
        XCTAssertEqual(node.keeping([b, c]), .split(.vertical, ratio: 0.5, .pane(b), .pane(c)))
        XCTAssertEqual(node.keeping([a]), .pane(a))
        XCTAssertNil(node.keeping([]))
        let data = try! JSONEncoder().encode(["x": node])
        XCTAssertEqual(try! JSONDecoder().decode([String: SplitNode].self, from: data)["x"], node)
    }

    func testAWorkspaceMovesToItsOwnWindowAndBack() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("plum-window-\(UUID().uuidString)")
        let repo = directory.appendingPathComponent("repo").path
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Git.run(["init", "-q", "-b", "main"], in: repo)
        let store = Store(directory: directory.appendingPathComponent("state"))
        let model = AppModel(store: store)
        model.addProject(at: repo)
        let workspace = try XCTUnwrap(model.selection)
        var shown: [UUID] = []
        model.onShowWindow = { shown.append($0) }

        model.openInOwnWindow(workspace)
        XCTAssertEqual(model.ownWindows, [workspace])
        XCTAssertEqual(PanelScope.selection.workspace(in: model), nil, "the main window leaves it to its window")
        XCTAssertEqual(PanelScope.workspace(workspace).workspace(in: model), workspace)
        model.select(workspace)
        XCTAssertEqual(shown, [workspace, workspace], "picking it brings its window forward")
        XCTAssertEqual(AppModel(store: store).ownWindows, [workspace], "remembered")

        model.closeOwnWindow(workspace)
        XCTAssertEqual(model.ownWindows, [])
        XCTAssertEqual(PanelScope.selection.workspace(in: model), workspace)
        for tab in model.tabs[workspace] ?? [] { model.closeTab(tab.id) }
    }
}
