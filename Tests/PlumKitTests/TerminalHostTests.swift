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

    /// Input and output go through non-blocking descriptors: a paste larger
    /// than every buffer on the way must wait for room, not lose bytes, and
    /// output larger than them must arrive whole.
    func testLargeInputAndOutputArriveWhole() throws {
        let id = UUID()
        let file = NSTemporaryDirectory() + "plum-paste-\(UUID().uuidString.prefix(8))"
        defer { unlink(file) }
        // Raw mode: no line editing or echo between the paste and `head`.
        let opened = try XCTUnwrap(client.open(
            id: id, workspace: UUID(), shell: "/bin/zsh", cwd: NSTemporaryDirectory(), environment: environment,
            cols: 60, rows: 12, command: "stty raw -echo; head -c 1000000 > \(file); stty sane; echo pasted-$(wc -c < \(file) | tr -d ' ')"))
        let session = attach(id, to: opened)
        Thread.sleep(forTimeInterval: 0.5) // the command has started reading
        session.write(Data(repeating: UInt8(ascii: "x"), count: 1_000_000))
        wait("all of the paste reached the program") { session.screenText().contains("pasted-1000000") }

        session.write("yes 0123456789 | head -c 3000000 | wc -c | sed 's/^ */out-/'; seq 1 20000 | tail -1\n")
        wait("output went through whole") { session.screenText().contains("out-3000000") && session.screenText().contains("20000") }
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

    func testSecondHostCannotReplaceALiveSocket() throws {
        let id = UUID()
        _ = try XCTUnwrap(client.open(id: id, workspace: UUID(), shell: "/bin/zsh", cwd: NSTemporaryDirectory(),
                                      environment: environment, cols: 60, rows: 12, command: "sleep 10"))

        let second = TerminalHost(socketPath: socketPath)
        XCTAssertThrowsError(try second.listen())
        let freshClient = try XCTUnwrap(TerminalHostClient(socketPath: socketPath, executable: "/nonexistent"))
        XCTAssertTrue(freshClient.list().contains { $0.id == id })
    }

    func testHostDoesNotIdleOutWhileItsClientIsConnected() {
        XCTAssertFalse(host.idle(for: -1))
    }

    func testIncompleteRequestDoesNotKeepAConnectionOpen() throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            socketPath.withCString { _ = strcpy(raw.baseAddress!.assumingMemoryBound(to: CChar.self), $0) }
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        XCTAssertEqual(connected, 0)
        var partial: UInt8 = 123
        XCTAssertEqual(write(fd, &partial, 1), 1)
        var timeout = timeval(tv_sec: 4, tv_usec: 0)
        XCTAssertEqual(setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)), 0)
        var byte: UInt8 = 0
        XCTAssertEqual(read(fd, &byte, 1), 0)
    }

    func testHostReclaimsStaleSocketAfterCrash() throws {
        let stalePath = NSTemporaryDirectory() + "plum-stale-host-\(UUID().uuidString.prefix(8)).sock"
        defer { unlink(stalePath) }
        let stale = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(stale, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            stalePath.withCString { _ = strcpy(raw.baseAddress!.assumingMemoryBound(to: CChar.self), $0) }
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(stale, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        XCTAssertEqual(bound, 0)
        close(stale)

        let restarted = TerminalHost(socketPath: stalePath)
        try restarted.listen()

        XCTAssertNotNil(TerminalHostClient(socketPath: stalePath, executable: "/nonexistent"))
    }

    func testOtherProcessesCannotOpenATerminalThroughTheHostSocket() throws {
        let id = UUID()
        let command = Process()
        command.executableURL = URL(fileURLWithPath: "/bin/sh")
        command.arguments = ["-c", "printf '%s\\n' '{\"op\":\"open\",\"id\":\"\(id.uuidString)\",\"workspace\":\"\(UUID().uuidString)\",\"shell\":\"/bin/zsh\",\"cwd\":\"/tmp\",\"env\":{\"PATH\":\"/usr/bin:/bin\",\"HOME\":\"/tmp\"},\"cols\":80,\"rows\":24,\"command\":\"sleep 5\"}' | /usr/bin/nc -w 1 -U '\(socketPath)'"]
        let output = Pipe()
        command.standardOutput = output
        try command.run()
        command.waitUntilExit()

        XCTAssertFalse(String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).contains("\"ok\":true"))
        XCTAssertFalse(client.list().contains { $0.id == id })
    }

    func testReplacingAClientsExecutablePathDoesNotImpersonatePlum() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("plum-path-swap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("client")
        let source = directory.appendingPathComponent("client.c")
        try Data("""
        #include <sys/socket.h>
        #include <sys/un.h>
        #include <unistd.h>
        #include <stdio.h>
        #include <string.h>
        int main(int argc, char **argv) {
            if (argc < 2) return 1;
            int fd = socket(AF_UNIX, SOCK_STREAM, 0);
            struct sockaddr_un address = {0};
            address.sun_family = AF_UNIX;
            snprintf(address.sun_path, sizeof(address.sun_path), "%s", argv[1]);
            if (connect(fd, (struct sockaddr *)&address, sizeof(address)) != 0) return 2;
            write(1, "R", 1);
            char buffer[4096];
            ssize_t count = read(0, buffer, sizeof(buffer));
            if (count > 0) write(fd, buffer, count);
            shutdown(fd, SHUT_WR);
            while ((count = read(fd, buffer, sizeof(buffer))) > 0) write(1, buffer, count);
            close(fd);
            return 0;
        }
        """.utf8).write(to: source)
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        compiler.arguments = [source.path, "-o", executable.path]
        try compiler.run()
        compiler.waitUntilExit()
        XCTAssertEqual(compiler.terminationStatus, 0)
        let process = Process()
        process.executableURL = executable
        process.arguments = [socketPath]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        XCTAssertEqual(try output.fileHandleForReading.read(upToCount: 1), Data("R".utf8))
        XCTAssertTrue(process.isRunning)

        var ownerPath = [CChar](repeating: 0, count: 4096)
        XCTAssertGreaterThan(proc_pidpath(getpid(), &ownerPath, UInt32(ownerPath.count)), 0)
        try FileManager.default.removeItem(at: executable)
        try FileManager.default.copyItem(atPath: String(cString: ownerPath), toPath: executable.path)
        XCTAssertTrue(FileManager.default.contentsEqual(atPath: String(cString: ownerPath), andPath: executable.path))
        XCTAssertTrue(process.isRunning)

        input.fileHandleForWriting.write(Data("{\"op\":\"hello\"}\n".utf8))
        input.fileHandleForWriting.closeFile()
        process.waitUntilExit()
        let response = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertFalse(response.contains("\"ok\":true"))
    }

    func testClientDoesNotSendRequestsToAnotherProgramsSocket() throws {
        let fakeSocket = NSTemporaryDirectory() + "plum-fake-host-\(UUID().uuidString.prefix(8)).sock"
        let fake = Process()
        fake.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        fake.arguments = ["-c", "import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(1); c,_=s.accept(); c.recv(4096); c.sendall(b'{\"ok\":true,\"version\":1}\\n'); c.close(); s.close()", fakeSocket]
        try fake.run()
        defer { fake.terminate(); fake.waitUntilExit(); unlink(fakeSocket) }
        wait("fake socket is ready") { FileManager.default.fileExists(atPath: fakeSocket) }

        XCTAssertNil(TerminalHostClient(socketPath: fakeSocket, executable: "/nonexistent"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fakeSocket))
    }

    func testLegacyClientDoesNotStartAMissingHost() {
        let missing = NSTemporaryDirectory() + "plum-missing-legacy-\(UUID().uuidString).sock"
        XCTAssertNil(TerminalHostClient(legacySocketPath: missing, codeHash: "b9b3230b9540d5f174d0e60c8729a53ba7cea9a9"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing))
    }

    func testLegacyClientRejectsTheWrongProcess() throws {
        let fakeSocket = NSTemporaryDirectory() + "plum-fake-legacy-\(UUID().uuidString.prefix(8)).sock"
        let fake = Process()
        fake.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        fake.arguments = ["-c", "import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(1); c,_=s.accept(); c.recv(4096); c.sendall(b'{\"ok\":true,\"version\":1}\\n'); c.close(); s.close()", fakeSocket]
        try fake.run()
        defer { fake.terminate(); fake.waitUntilExit(); unlink(fakeSocket) }
        wait("fake legacy socket is ready") { FileManager.default.fileExists(atPath: fakeSocket) }

        XCTAssertNil(TerminalHostClient(legacySocketPath: fakeSocket, codeHash: "b9b3230b9540d5f174d0e60c8729a53ba7cea9a9"))
    }

    func testRunningLegacyHostCanBeListedAfterItsBinaryWasReplacedOnDisk() throws {
        let env = ProcessInfo.processInfo.environment
        guard let socket = env["PLUM_TEST_LEGACY_SOCKET"] else {
            throw XCTSkip("requires an isolated or live legacy host")
        }
        let legacy = try XCTUnwrap(TerminalHostClient(legacySocketPath: socket,
                                                      codeHash: "b9b3230b9540d5f174d0e60c8729a53ba7cea9a9"))
        XCTAssertFalse(legacy.list().isEmpty)
    }

    func testHardenedHostUsesADifferentSocketFromLegacyHost() {
        let store = Store(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        XCTAssertTrue(TerminalHost.legacySocketPath(for: store).contains("plum-host-1-"))
        XCTAssertTrue(TerminalHost.socketPath(for: store).contains("plum-host-3-"))
        XCTAssertNotEqual(TerminalHost.legacySocketPath(for: store), TerminalHost.socketPath(for: store))
    }


    func testHostRejectsNegativeSnapshotLengthWithoutCrashing() {
        var descriptors: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors), 0)
        defer { close(descriptors[0]); close(descriptors[1]) }

        XCTAssertNil(Connection(fd: descriptors[0]).read(count: -1))
    }
}
