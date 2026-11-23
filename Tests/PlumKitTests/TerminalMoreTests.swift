import GhosttyVt
import XCTest
@testable import PlumKit

@MainActor
final class TerminalMoreTests: XCTestCase {
    /// Switching workspaces makes a new view for the tab. Until it is laid out
    /// it must leave the session's size alone: the program would get a
    /// terminal of the wrong size, redraw for it, then redraw again (a jump).
    func testANewViewKeepsTheSizeUntilItIsLaidOut() {
        let session = TerminalSession(cols: 120, rows: 50)
        let view = TerminalView(fontName: "", fontSize: 13)
        view.session = session
        XCTAssertEqual([session.cols, session.rows], [120, 50])
        view.setFrameSize(NSSize(width: 400, height: 300))
        XCTAssertNotEqual([session.cols, session.rows], [120, 50], "laid out: now the view's size")
    }

    func testProgramsCanCopyTextToTheClipboard() {
        var copied: [String] = []
        let original = TerminalSession.copyToClipboard
        TerminalSession.copyToClipboard = { copied.append($0) }
        defer { TerminalSession.copyToClipboard = original }
        let session = TerminalSession(cols: 40, rows: 5)
        session.feed("\u{1b}]52;c;\(Data("복사 됨".utf8).base64EncodedString())\u{7}") // what vim's "+y sends over OSC 52
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(copied, ["복사 됨"])
    }

    func testAProgramsOwnLinksAreFound() {
        let session = TerminalSession(cols: 40, rows: 5)
        session.feed("see \u{1b}]8;;https://example.com/pr/7\u{1b}\\PR seven\u{1b}]8;;\u{1b}\\ here")
        XCTAssertEqual(session.hyperlink(at: (6, 0)), "https://example.com/pr/7")
        XCTAssertNil(session.hyperlink(at: (1, 0)))
    }

    func testTheViewJumpsBetweenMarkedPrompts() {
        let session = TerminalSession(cols: 30, rows: 4)
        for command in 1...3 {
            // As the zsh integration marks it: the prompt, then output once the command runs.
            session.feed("\u{1b}]133;A\u{7}$ cmd\(command)\r\n\u{1b}]133;C\u{7}")
            for line in 1...10 { session.feed("out \(command)-\(line)\r\n") }
        }
        // Each command is its prompt and ten lines: prompts on rows 0, 11 and 22.
        session.scrollToPrompt(-1)
        XCTAssertEqual(viewportTop(session), 22)
        session.scrollToPrompt(-1)
        XCTAssertEqual(viewportTop(session), 11)
        session.scrollToPrompt(1)
        XCTAssertEqual(viewportTop(session), 22)
    }

    func testTheShellsFolderIsReadBack() throws {
        let session = TerminalSession(cols: 80, rows: 10)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("plum-cwd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("inner"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try session.start(shell: "/bin/zsh", cwd: folder.path, environment: ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color", "ZDOTDIR": "/nonexistent"])
        defer { session.terminate() }
        session.writeWhenReady("cd inner\n")
        let expected = ClaudeTrust.realPath(folder.appendingPathComponent("inner").path)
        let deadline = Date().addingTimeInterval(5)
        while session.currentDirectory() != expected, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        XCTAssertEqual(session.currentDirectory(), expected)
    }

    func testCursorPreferenceBecomesTheDefault() {
        let session = TerminalSession(cols: 30, rows: 4)
        session.applyPreferences(cursor: .bar, blink: false, scrollbackMB: 1)
        let style = session.withFrame { state -> GhosttyCursorStyle in
            var style = GHOSTTY_CURSOR_STYLE_BLOCK
            ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_CURSOR_VISUAL_STYLE, &style)
            return style
        }
        XCTAssertEqual(style, GHOSTTY_CURSOR_STYLE_BAR)
    }

    func testZshIntegrationGivesTheUsersZdotdirBack() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("plum-zsh-\(UUID().uuidString)")
        let mine = folder.appendingPathComponent("plum"), theirs = folder.appendingPathComponent("theirs")
        for dir in [mine, theirs] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        defer { try? FileManager.default.removeItem(at: folder) }
        try ShellIntegration.zshenv.write(to: mine.appendingPathComponent(".zshenv"), atomically: true, encoding: .utf8)
        try "export FROM_ENV=1\n".write(to: theirs.appendingPathComponent(".zshenv"), atomically: true, encoding: .utf8)
        try "export FROM_RC=1\n".write(to: theirs.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        let zsh = Process()
        zsh.executableURL = URL(fileURLWithPath: "/bin/zsh")
        zsh.arguments = ["-i", "-c", "print -r -- \"$ZDOTDIR|$FROM_ENV|$FROM_RC|${+PLUM_USER_ZDOTDIR}\""]
        zsh.environment = ["PATH": "/usr/bin:/bin", "ZDOTDIR": mine.path, "PLUM_USER_ZDOTDIR": theirs.path, "HOME": folder.path]
        let out = Pipe()
        zsh.standardOutput = out
        zsh.standardError = FileHandle.nullDevice
        try zsh.run()
        zsh.waitUntilExit()
        let printed = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(printed.trimmingCharacters(in: .whitespacesAndNewlines), "\(theirs.path)|1|1|0")
    }

    func testTheDiffIsReadFileByFileWithLineNumbers() {
        let patch = """
        diff --git a/src/a.swift b/src/a.swift
        index 1..2 100644
        --- a/src/a.swift
        +++ b/src/a.swift
        @@ -10,3 +10,4 @@ func f() {
         keep
        -old
        +new
        +more
         end
        diff --git a/b.png b/b.png
        Binary files a/b.png and b/b.png differ
        """
        let files = Diff.parse(patch)
        XCTAssertEqual(files.map(\.path), ["src/a.swift", "b.png"])
        XCTAssertEqual(files[0].added, 2)
        XCTAssertEqual(files[0].removed, 1)
        XCTAssertEqual(files[0].lines.map(\.text), ["@@ -10,3 +10,4 @@ func f() {", "keep", "old", "new", "more", "end"])
        XCTAssertEqual(files[0].lines[2].old, 11)
        XCTAssertEqual(files[0].lines[4].new, 12)
        XCTAssertEqual(files[0].lines[5].old, 12)
        XCTAssertEqual(files[0].lines[5].new, 13)
        XCTAssertTrue(files[1].isBinary)
    }

    func testTheDiffCoversNewFilesAndTheWholeBranch() throws {
        let repo = FileManager.default.temporaryDirectory.appendingPathComponent("plum-diff-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: repo) }
        try Git.run(["init", "-q", "-b", "main"], in: repo)
        try Git.run(["config", "user.email", "t@e"], in: repo)
        try Git.run(["config", "user.name", "T"], in: repo)
        try "one\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
        try Git.run(["add", "."], in: repo)
        try Git.run(["commit", "-qm", "init"], in: repo)
        try Git.run(["checkout", "-qb", "feature"], in: repo)
        try "one\ntwo\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
        try Git.run(["commit", "-qam", "two"], in: repo)
        try "새 파일\n".write(toFile: repo + "/한글.txt", atomically: true, encoding: .utf8)

        let uncommitted = try Diff.files(in: repo, scope: .uncommitted, base: "main")
        XCTAssertEqual(uncommitted.map(\.path), ["한글.txt"])
        XCTAssertTrue(uncommitted[0].isNew)
        let branch = try Diff.files(in: repo, scope: .branch, base: "main")
        XCTAssertEqual(Set(branch.map(\.path)), ["a.txt", "한글.txt"])
        XCTAssertEqual(branch.first { $0.path == "a.txt" }?.added, 1)
        XCTAssertThrowsError(try Diff.files(in: repo, scope: .branch, base: "no-such-branch"))
    }

    func testClosedTabsComeBackAndTabsMoveByDrop() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("plum-reopen-\(UUID().uuidString)")
        let repo = directory.appendingPathComponent("repo").path
        try FileManager.default.createDirectory(atPath: repo + "/sub", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Git.run(["init", "-q", "-b", "main"], in: repo)
        let model = AppModel(store: Store(directory: directory.appendingPathComponent("state")))
        model.addProject(at: repo)
        let workspace = try XCTUnwrap(model.state.projects.first?.id) // the main checkout's workspace id is the project's
        let first = try XCTUnwrap(model.openTab(in: workspace, cwd: repo + "/sub"))
        let second = try XCTUnwrap(model.openTab(in: workspace))
        let third = try XCTUnwrap(model.openTab(in: workspace))
        model.moveTab(third.id, to: first.id)
        let ours = Set([first.id, second.id, third.id])
        XCTAssertEqual(model.tabs[workspace]?.map(\.id).filter(ours.contains), [third.id, first.id, second.id])

        model.renameTab(first.id, to: "서버")
        let sub = ClaudeTrust.realPath(repo + "/sub")
        let deadline = Date().addingTimeInterval(5)
        while first.session.currentDirectory() != sub, Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        model.closeTab(first.id)
        let again = try XCTUnwrap(model.reopenClosedTab())
        XCTAssertEqual(again.customTitle, "서버")
        let until = Date().addingTimeInterval(5)
        while again.session.currentDirectory() != sub, Date() < until { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertEqual(again.session.currentDirectory(), sub)
        for tab in model.tabs[workspace] ?? [] { model.closeTab(tab.id) }
    }
}

/// The first row on screen, counted from the top of the scrollback.
@MainActor
func viewportTop(_ session: TerminalSession) -> Int {
    session.withTerminal { terminal in
        var bar = GhosttyTerminalScrollbar()
        ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &bar)
        return Int(bar.offset)
    }
}
