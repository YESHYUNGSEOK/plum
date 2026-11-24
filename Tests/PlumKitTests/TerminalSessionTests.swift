import GhosttyVt
import XCTest
@testable import PlumKit

final class TerminalSessionTests: XCTestCase {
    func testUnusedKittyGraphicsProtocolIsDisabled() {
        let session = TerminalSession(cols: 40, rows: 5)
        var bytes: UInt64 = .max
        XCTAssertEqual(ghostty_terminal_get(session.terminal, GHOSTTY_TERMINAL_DATA_KITTY_IMAGE_STORAGE_LIMIT, &bytes), GHOSTTY_SUCCESS)
        XCTAssertEqual(bytes, 0)
    }

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

    func testMissingWorkingDirectoryDoesNotStartShellElsewhere() throws {
        let session = TerminalSession(cols: 80, rows: 10)
        let exited = expectation(description: "shell exits")
        session.onExit = { exited.fulfill() }
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

        try session.start(shell: "/bin/sh", cwd: missing.path, environment: ["TERM": "xterm-256color", "PATH": "/usr/bin:/bin"])
        session.write("printf 'unexpected-shell\\n'; exit\n")
        wait(for: [exited], timeout: 5)

        XCTAssertFalse(session.screenText().split(separator: "\n").contains("unexpected-shell"), session.screenText())
    }

    /// Closing tabs must not leave reader threads or pty descriptors behind,
    /// even when the program in the tab ignores the hangup.
    func testClosedSessionsLeaveNoThreadsOrDescriptors() throws {
        func descriptors() -> Int { (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1 }
        func readerThreads() -> Int {
            var threads: thread_act_array_t?
            var count: mach_msg_type_number_t = 0
            guard task_threads(mach_task_self_, &threads, &count) == KERN_SUCCESS, let threads else { return -1 }
            defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: threads), vm_size_t(Int(count) * MemoryLayout<thread_t>.stride)) }
            var found = 0
            for index in 0..<Int(count) {
                var name = [CChar](repeating: 0, count: 64)
                if let thread = pthread_from_mach_thread_np(threads[index]), pthread_getname_np(thread, &name, name.count) == 0,
                   String(cString: name) == "plum.terminal.read" { found += 1 }
                mach_port_deallocate(mach_task_self_, threads[index])
            }
            return found
        }
        let environment = ["TERM": "xterm-256color", "PATH": "/usr/bin:/bin"]
        let before = (descriptors(), readerThreads())
        do {
            var sessions: [TerminalSession] = []
            for ignoresHangup in [false, false, true] {
                let session = TerminalSession(cols: 80, rows: 10)
                try session.start(shell: "/bin/sh", cwd: NSTemporaryDirectory(), environment: environment)
                if ignoresHangup { session.write("trap '' HUP; while :; do sleep 1; done\n") }
                sessions.append(session)
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            XCTAssertEqual(readerThreads(), before.1 + 3)
        }
        let deadline = Date().addingTimeInterval(5)
        while (descriptors() > before.0 || readerThreads() > before.1), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertLessThanOrEqual(descriptors(), before.0, "pty descriptors left open")
        XCTAssertLessThanOrEqual(readerThreads(), before.1, "reader threads left running")
    }

    /// A shell must not keep the app's other descriptors: holding a pipe's
    /// write end, it would keep whoever reads that pipe (a git command's
    /// output) waiting forever, long after git itself has exited.
    func testShellsDontInheritTheAppsDescriptors() throws {
        var ends: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&ends), 0) // opened without close-on-exec, as Foundation's pipes are
        let session = TerminalSession(cols: 80, rows: 10)
        // zsh, the login shell Plum starts; /bin/sh would hide the leak, as
        // it starts the real shell again with only the standard descriptors.
        try session.start(shell: "/bin/zsh", cwd: NSTemporaryDirectory(), environment: ["PATH": "/usr/bin:/bin"])
        close(ends[1])
        defer { close(ends[0]) }
        var reader = pollfd(fd: ends[0], events: Int16(POLLIN), revents: 0)
        guard poll(&reader, 1, 2000) == 1 else { return XCTFail("the shell still holds the pipe's write end") }
        var byte: UInt8 = 0
        XCTAssertEqual(read(ends[0], &byte, 1), 0, "end of file once the app's own end is closed")
    }

    func testPortsAProgramInTheTabListensOnAreFound() throws {
        let session = TerminalSession(cols: 80, rows: 10)
        try session.start(shell: "/bin/zsh", cwd: NSTemporaryDirectory(), environment: ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color"])
        let port = UInt16.random(in: 40000...49000)
        session.writeWhenReady("nc -l 127.0.0.1 \(port)\n")
        func wait(until done: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(5)
            while !done(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
            return done()
        }
        XCTAssertTrue(wait { session.listeningPorts().contains(port) }, "nc's port, found under the shell")
        session.write("\u{3}") // Ctrl-C
        XCTAssertTrue(wait { !session.listeningPorts().contains(port) }, "gone once nc stops")
    }

    /// Claude Code's installer runs it from `…/claude/versions/<version>`:
    /// it's still Claude, and its own port isn't the tab's.
    func testAProgramNamedForItsVersionIsNamedForItsFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("plum-\(UUID().uuidString)/claude/versions")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent().deletingLastPathComponent()) }
        // A program built here: copies of the system's own aren't allowed to run.
        let agent = folder.appendingPathComponent("2.1.328").path
        let source = folder.appendingPathComponent("listen.c")
        try """
        #include <arpa/inet.h>
        #include <stdlib.h>
        #include <unistd.h>
        int main(int argc, char **argv) {
            int s = socket(AF_INET, SOCK_STREAM, 0);
            struct sockaddr_in a = { .sin_family = AF_INET, .sin_port = htons(atoi(argv[1])), .sin_addr.s_addr = htonl(INADDR_LOOPBACK) };
            bind(s, (struct sockaddr *)&a, sizeof a);
            listen(s, 8);
            pause();
        }
        """.write(to: source, atomically: true, encoding: .utf8)
        let clang = Process()
        clang.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        clang.arguments = ["clang", "-o", agent, source.path]
        try clang.run()
        clang.waitUntilExit()
        guard clang.terminationStatus == 0 else { throw XCTSkip("no C compiler") }

        let session = TerminalSession(cols: 80, rows: 10)
        try session.start(shell: "/bin/zsh", cwd: NSTemporaryDirectory(), environment: ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color"])
        defer { session.terminate() }
        let port = UInt16.random(in: 40000...49000)
        session.writeWhenReady("'\(agent)' \(port)\n")
        let deadline = Date().addingTimeInterval(5)
        while session.foregroundProgram() != "claude", Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        XCTAssertEqual(session.foregroundProgram(), "claude")
        // It does listen; the tab just doesn't show it.
        let listening = Date().addingTimeInterval(5)
        var up = isListening(port)
        while !up, Date() < listening {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            up = isListening(port)
        }
        XCTAssertTrue(up)
        XCTAssertFalse(session.listeningPorts().contains(port), "the agent's own port")
    }

    private func isListening(_ port: UInt16) -> Bool {
        let s = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(s) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
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
