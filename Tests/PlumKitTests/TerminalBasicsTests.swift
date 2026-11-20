import GhosttyVt
import XCTest
@testable import PlumKit

/// What every terminal is expected to do: search, clear, the mouse in
/// full-screen programs, dropped files.
@MainActor
final class TerminalBasicsTests: XCTestCase {
    func testFindWalksMatchesFromTheNewestAndSelectsThem() {
        let session = TerminalSession(cols: 40, rows: 5)
        for line in 1...30 { session.feed("line \(line) \(line % 10 == 0 ? "ERROR" : "ok")\r\n") }
        XCTAssertEqual(session.find("error").total, 3, "found in the scrollback too, whatever the case")
        XCTAssertEqual(session.find("error").selected, 1)
        XCTAssertEqual(session.selectedText(), "ERROR")
        XCTAssertEqual(session.findNext().selected, 2)
        XCTAssertTrue((15...19).contains(viewportTop(session)), "line 20 (row 19) is on screen: \(viewportTop(session))")
        XCTAssertEqual(session.findNext(backward: true).selected, 1)
        XCTAssertEqual(session.find("nothing like it").total, 0)
        XCTAssertNil(session.selectedText())
        session.endFind()
        XCTAssertNil(session.selectedText())
    }

    func testClearDropsTheScreenAndTheScrollback() {
        let session = TerminalSession(cols: 40, rows: 5)
        for line in 1...30 { session.feed("line \(line)\r\n") }
        session.clear()
        XCTAssertEqual(session.screenText().trimmingCharacters(in: .whitespacesAndNewlines), "")
        session.selectAll()
        XCTAssertEqual((session.selectedText() ?? "").trimmingCharacters(in: .whitespacesAndNewlines), "")
    }

    func testSelectAllTakesTheScrollbackToo() {
        let session = TerminalSession(cols: 40, rows: 5)
        for line in 1...30 { session.feed("line \(line)\r\n") }
        session.selectAll()
        let text = session.selectedText() ?? ""
        XCTAssertTrue(text.hasPrefix("line 1\n"), String(text.prefix(20)))
        XCTAssertTrue(text.contains("line 30"))
    }

    func testTheMouseGoesToAProgramOnlyWhenItAsked() {
        let session = TerminalSession(cols: 40, rows: 5)
        let press = TerminalSession.Mouse(action: GHOSTTY_MOUSE_ACTION_PRESS, button: GHOSTTY_MOUSE_BUTTON_LEFT, x: 30, y: 30)
        XCTAssertFalse(session.wantsMouse)
        XCTAssertFalse(session.send(press, viewWidth: 400, viewHeight: 100, padding: 8))
        session.feed("\u{1b}[?1000h\u{1b}[?1006h") // what vim and htop send
        XCTAssertTrue(session.wantsMouse)
        XCTAssertTrue(session.send(press, viewWidth: 400, viewHeight: 100, padding: 8))
        session.feed("\u{1b}[?1000l")
        XCTAssertFalse(session.wantsMouse)
    }

    func testFullScreenProgramsAndTheKittyKeyboardAreNoticed() {
        let session = TerminalSession(cols: 40, rows: 5)
        XCTAssertFalse(session.isAlternateScreen)
        XCTAssertFalse(session.usesKittyKeyboard)
        session.feed("\u{1b}[?1049h\u{1b}[>1u")
        XCTAssertTrue(session.isAlternateScreen)
        XCTAssertTrue(session.usesKittyKeyboard)
        session.feed("\u{1b}[<u\u{1b}[?1049l")
        XCTAssertFalse(session.isAlternateScreen)
        XCTAssertFalse(session.usesKittyKeyboard)
    }

    func testDroppedPathsAreQuotedForTheShell() {
        XCTAssertEqual(TerminalView.shellQuoted("/tmp/a-b_c.png"), "/tmp/a-b_c.png")
        XCTAssertEqual(
            TerminalView.shellQuoted("/Users/me/Desktop/스크린샷 2026-11-19 오후 2.48.36.png"),
            "/Users/me/Desktop/스크린샷\\ 2026-11-19\\ 오후\\ 2.48.36.png")
        XCTAssertEqual(TerminalView.shellQuoted("a'b$(c);d"), #"a\'b\$\(c\)\;d"#)
    }

    func testReleaseTagsCompareByNumber() {
        XCTAssertTrue(Updates.isNewer("v0.2.0", than: "0.1.9"))
        XCTAssertTrue(Updates.isNewer("0.10.0", than: "0.9.0"))
        XCTAssertFalse(Updates.isNewer("v0.1.0", than: "0.1.0"))
        XCTAssertFalse(Updates.isNewer("v0.1", than: "0.1.0"))
        XCTAssertFalse(Updates.isNewer("nightly", than: "0.1.0"))
    }

    func testWorktreesMadeElsewhereAreImportedOnce() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("plum-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repo = directory.appendingPathComponent("repo").path
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        try Git.run(["init", "-q", "-b", "main"], in: repo)
        try Git.run(["config", "user.email", "t@e"], in: repo)
        try Git.run(["config", "user.name", "T"], in: repo)
        try "hi".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
        try Git.run(["add", "."], in: repo)
        try Git.run(["commit", "-qm", "init"], in: repo)
        try Git.run(["worktree", "add", "-q", "-b", "feature/x", directory.appendingPathComponent("by-hand").path], in: repo)
        try Git.run(["worktree", "add", "-q", "--detach", directory.appendingPathComponent("detached").path], in: repo)

        let model = AppModel(store: Store(directory: directory.appendingPathComponent("state")))
        model.addProject(at: repo) // imports what's there by itself
        let project = model.state.projects[0].id
        let deadline = Date().addingTimeInterval(5)
        while model.state.workspaces.isEmpty, Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertEqual(model.state.workspaces.map(\.name), ["by-hand"], "the detached one has no branch to be a workspace of")
        XCTAssertEqual(model.state.workspaces.first?.branch, "feature/x")
        let again = await model.importWorktrees(of: project)
        XCTAssertEqual(again, 0)
    }
}
