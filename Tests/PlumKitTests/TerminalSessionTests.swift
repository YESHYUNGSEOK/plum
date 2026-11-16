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

    func testSanitizeStripsControlAndBidi() {
        XCTAssertEqual(sanitizeForDisplay("a\u{1b}[31m\u{202e}b\nc", limit: 10), "a[31mbc")
        XCTAssertEqual(sanitizeForDisplay("abcdef", limit: 3), "abc")
    }
}
