import XCTest
@testable import PlumKit

/// Terminals the host keeps outlive the app: their programs keep running
/// while it's away, and attaching again brings the screen back.
final class TerminalHostTests: XCTestCase {
    private var socketPath = ""
    private var host: TerminalHost!
    private var client: TerminalHostClient!
    /// No user zsh setup: a prompt that sets the window title would hide the one under test.
    private let environment = ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color", "HOME": NSHomeDirectory(), "ZDOTDIR": "/nonexistent"]

    override func setUpWithError() throws {
        socketPath = NSTemporaryDirectory() + "plum-host-test-\(UUID().uuidString.prefix(8)).sock"
        host = TerminalHost(socketPath: socketPath)
        try host.listen()
        client = try XCTUnwrap(TerminalHostClient(socketPath: socketPath, executable: "/nonexistent"))
    }

    override func tearDown() {
        for session in client?.list() ?? [] { client.close(session.id) }
        unlink(socketPath)
    }

    private func attach(_ id: UUID, to carried: TerminalHostClient.Carried) -> TerminalSession {
        let session = TerminalSession(id: id, cols: carried.cols, rows: carried.rows)
        session.attach(fd: carried.fd, pid: carried.pid, remote: .init(
            resize: { [client] cols, rows, width, height in client!.resize(id, cols: cols, rows: rows, width: width, height: height) },
            end: { [client] in client!.close(id) }))
        return session
    }

    private func wait(_ what: String, until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(8)
        while !done(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertTrue(done(), what)
    }

    func testATerminalLivesOnWhileDetachedAndComesBackWithItsScreen() throws {
        let id = UUID(), workspace = UUID()
        let opened = try XCTUnwrap(client.open(
            id: id, workspace: workspace, shell: "/bin/zsh", cwd: NSTemporaryDirectory(), environment: environment,
            cols: 60, rows: 12, command: "printf '\\033]2;first title\\007'; echo before-$((40+2)); sleep 1; printf '\\033]2;title while away\\007'; echo while-$((6*7))-away"))
        XCTAssertGreaterThan(opened.pid, 0)
        var session: TerminalSession? = attach(id, to: opened)
        wait("the command's output arrives") { session!.screenText().contains("before-42") }
        XCTAssertEqual(client.list().map(\.id), [id])
        XCTAssertEqual(client.list().first?.workspace, workspace)

        // The app quits: it hands the screen over and lets go.
        let (screen, received) = session!.snapshot()
        client.park(id, snapshot: screen, received: received)
        session = nil
        Thread.sleep(forTimeInterval: 1.6) // `sleep 1` ends and prints while nobody is attached
        XCTAssertEqual(client.list().map(\.id), [id], "the shell runs on")

        let again = try XCTUnwrap(client.attach(id: id))
        XCTAssertEqual(again.pid, opened.pid, "the same shell")
        let restored = attach(id, to: again)
        wait("the screen from before, and what came while away") {
            let text = restored.screenText()
            return text.contains("before-42") && text.contains("while-42-away")
        }
        wait("the title it was given while away") { restored.title == "title while away" }
        restored.write("echo typed-$((1+1))\n")
        wait("typing reaches the shell again") { restored.screenText().contains("typed-2") }

        var ended = false
        restored.onExit = { ended = true }
        restored.terminate()
        wait("closing the tab ends the shell") { ended && self.client.list().isEmpty }
    }

    func testAnAppThatWentAwayWithoutParkingStillGetsTheLatestOutput() throws {
        let id = UUID()
        let opened = try XCTUnwrap(client.open(
            id: id, workspace: UUID(), shell: "/bin/zsh", cwd: NSTemporaryDirectory(), environment: environment,
            cols: 60, rows: 12, command: "echo crash-$((40+2))"))
        var session: TerminalSession? = attach(id, to: opened)
        wait("output arrives") { session!.screenText().contains("crash-42") }
        session = nil // gone without a word, as if the app crashed
        Thread.sleep(forTimeInterval: 0.3)
        let restored = attach(id, to: try XCTUnwrap(client.attach(id: id)))
        wait("rebuilt from the output the host kept") { restored.screenText().contains("crash-42") }
    }

    /// An agent that stops waiting for an answer while the app is away still
    /// shows as waiting when it comes back; what the app had seen to doesn't.
    func testTheAgentsLastStateIsKeptForTheApp() throws {
        let id = UUID()
        let opened = try XCTUnwrap(client.open(
            id: id, workspace: UUID(), shell: "/bin/zsh", cwd: NSTemporaryDirectory(), environment: environment,
            cols: 60, rows: 12, command: nil))
        var session: TerminalSession? = attach(id, to: opened)
        let (screen, received) = session!.snapshot()
        client.park(id, snapshot: screen, received: received, status: .idle)
        session = nil
        // The hook, as Claude Code runs it.
        let hook = Process()
        hook.executableURL = URL(fileURLWithPath: "/bin/sh")
        hook.arguments = ["-c", HookSettings.command("waiting")]
        hook.environment = ["PLUM_TAB_ID": id.uuidString, "PLUM_HOST_SOCKET": socketPath]
        try hook.run()
        hook.waitUntilExit()
        let again = try XCTUnwrap(client.attach(id: id))
        XCTAssertEqual(again.status, .waiting)
        let back = attach(id, to: again)
        client.park(id, snapshot: back.snapshot().screen, received: back.snapshot().received, status: .idle) // seen to
        XCTAssertEqual(try XCTUnwrap(client.attach(id: id)).status, .idle)
    }

    /// The Stop hook as Claude Code runs it: its input, pretty-printed over
    /// several lines, reaches Plum as one line, and a command left running
    /// in the background makes the agent monitoring, not done.
    func testTheStopHookTellsMonitoringFromDone() throws {
        let id = UUID()
        _ = try XCTUnwrap(client.open(id: id, workspace: UUID(), shell: "/bin/zsh", cwd: NSTemporaryDirectory(),
                                      environment: environment, cols: 60, rows: 12, command: nil))
        func stop(_ input: String) throws -> AgentStatus {
            let hook = Process()
            hook.executableURL = URL(fileURLWithPath: "/bin/sh")
            hook.arguments = ["-c", HookSettings.stopCommand]
            hook.environment = ["PLUM_TAB_ID": id.uuidString, "PLUM_HOST_SOCKET": socketPath]
            let pipe = Pipe()
            hook.standardInput = pipe
            try hook.run()
            pipe.fileHandleForWriting.write(Data(input.utf8))
            pipe.fileHandleForWriting.closeFile()
            hook.waitUntilExit()
            let again = try XCTUnwrap(client.attach(id: id))
            close(again.fd)
            return again.status
        }
        XCTAssertEqual(try stop("""
        {
          "hook_event_name": "Stop",
          "last_assistant_message": "dev 서버를 띄워 두었습니다. 100% 'ready' \\"quoted\\"",
          "background_tasks": [
            { "id": "t1", "type": "shell", "status": "running", "command": "npm run dev" }
          ],
          "session_crons": []
        }
        """), .monitoring)
        XCTAssertEqual(try stop(#"{"hook_event_name": "Stop", "background_tasks": [], "session_crons": []}"#), .done)
    }

    func testAttachingToAnUnknownTerminalFails() {
        XCTAssertNil(client.attach(id: UUID()))
    }
}
