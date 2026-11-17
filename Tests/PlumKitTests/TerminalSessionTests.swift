import XCTest
@testable import PlumKit

final class TerminalSessionTests: XCTestCase {
    func testFeedAndReadBack() {
        let session = TerminalSession(cols: 40, rows: 5)
        session.feed("Hello \u{1b}[1;32m한글\u{1b}[0m world\r\nsecond")
        XCTAssertEqual(session.screenText(), "Hello 한글 world\nsecond")
    }

    func testShellRunsOnPty() throws {
        let session = TerminalSession(cols: 80, rows: 10)
        let exited = expectation(description: "shell exits")
        session.onExit = { exited.fulfill() }
        try session.start(shell: "/bin/sh", cwd: NSTemporaryDirectory(), environment: ["TERM": "xterm-256color", "PATH": "/usr/bin:/bin"])
        session.write("printf 'plum-%s\\n' ok; exit\n")
        wait(for: [exited], timeout: 10)
        XCTAssertTrue(session.screenText().contains("plum-ok"), session.screenText())
    }

    func testForegroundProgramIsNilAtThePromptAndNamesARunningCommand() throws {
        let session = TerminalSession(cols: 80, rows: 10)
        try session.start(shell: "/bin/sh", cwd: NSTemporaryDirectory(), environment: ["TERM": "xterm-256color", "PATH": "/usr/bin:/bin"])
        defer { session.terminate() }
        func eventually(_ expected: String?) {
            let deadline = Date().addingTimeInterval(5)
            while session.foregroundProgram() != expected, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
            XCTAssertEqual(session.foregroundProgram(), expected)
        }
        eventually(nil)
        session.write("sleep 30\n")
        eventually("sleep")
        session.write("\u{03}") // Ctrl-C: back to the prompt
        eventually(nil)
    }

    func testFontNamesResolveAndUnknownOnesStayMonospaced() {
        XCTAssertEqual(CTFontCopyFamilyName(FontSpec.font(named: "Menlo", size: 12)) as String, "Menlo")
        let unknown = FontSpec.font(named: "No Such Font 123", size: 12)
        XCTAssertTrue(CTFontGetSymbolicTraits(unknown).contains(.traitMonoSpace))
        XCTAssertTrue(FontSpec.monospacedFamilies().contains("Menlo"))
    }

    func testLinkUnderACellIsFoundAcrossWideTextAndWrapping() {
        let session = TerminalSession(cols: 24, rows: 6)
        // Two wide characters before the link; the link wraps onto row 2.
        session.feed("한글 https://example.com/pull/1234 끝")
        // Column 10 on row 0 is inside "https://…", after the 4 cells of 한글 and a space.
        let first = session.line(at: (10, 0))
        XCTAssertEqual(first.flatMap { TerminalView.webLink(in: $0.text, at: $0.offset) }?.absoluteString, "https://example.com/pull/1234")
        // A cell of the link on the wrapped row finds the same link.
        let wrapped = session.line(at: (3, 1))
        XCTAssertEqual(wrapped.flatMap { TerminalView.webLink(in: $0.text, at: $0.offset) }?.absoluteString, "https://example.com/pull/1234")
        // The Hangul before it is not a link.
        let hangul = session.line(at: (0, 0))
        XCTAssertNil(hangul.flatMap { TerminalView.webLink(in: $0.text, at: $0.offset) })
        XCTAssertNil(TerminalView.webLink(in: "open file:///Applications/Calculator.app", at: 8), "only web links open")
    }

    func testSanitizeStripsControlAndBidi() {
        XCTAssertEqual(sanitizeForDisplay("a\u{1b}[31m\u{202e}b\nc", limit: 10), "a[31mbc")
        XCTAssertEqual(sanitizeForDisplay("abcdef", limit: 3), "abc")
    }
}
