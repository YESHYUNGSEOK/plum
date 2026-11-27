import XCTest
@testable import PlumKit

/// An update keeps running terminals: the new app attaches to the hosts of
/// the releases before it, and the app installs an update only when the new
/// build will be able to (HostIdentity).
@MainActor
final class UpdateKeepsTerminalsTests: XCTestCase {
    private let environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "ZDOTDIR": "/nonexistent"]

    func testReleasedHashesAreReadOnePerLine() {
        let first = String(repeating: "a", count: 40), second = String(repeating: "B", count: 40)
        let text = """
        # comment \(String(repeating: "c", count: 40))
        \(first) 0.1.21
        \(second)
        \(String(repeating: "d", count: 39)) too short
        not a hash at all

        """
        XCTAssertEqual(HostIdentity.parse(text), [first, second.lowercased()])
    }

    func testAnUpdateKeepsHostsOnlyWhenItTrustsAndSpeaksToEachOne() {
        let host = (hash: String(repeating: "a", count: 40), version: 6)
        XCTAssertTrue(HostIdentity.keeps([host], trusted: [host.hash], oldestVersion: 6))
        XCTAssertTrue(HostIdentity.keeps([], trusted: [], oldestVersion: nil))
        XCTAssertFalse(HostIdentity.keeps([host], trusted: [], oldestVersion: 6), "the new build doesn't list this host's release")
        XCTAssertFalse(HostIdentity.keeps([host], trusted: [host.hash], oldestVersion: 7), "the new build no longer speaks version 6")
        XCTAssertFalse(HostIdentity.keeps([host], trusted: [host.hash], oldestVersion: nil), "a build that doesn't say")
    }

    func testAnUpdateThatIsntSignedAsThisBuildIsWouldEndTheTerminals() {
        let host = (hash: HostIdentity.ownHash ?? "", version: TerminalHost.version)
        XCTAssertFalse(HostIdentity.keepsTerminals(updatingTo: URL(fileURLWithPath: "/nonexistent"), hosts: [host]))
        XCTAssertTrue(HostIdentity.keepsTerminals(updatingTo: URL(fileURLWithPath: "/nonexistent"), hosts: []))
    }

    func testTheHostOfAnEarlierBuildIsFoundKeptForItsTabsAndLetGo() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("plum-earlier-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = Store(directory: folder.appendingPathComponent("state"))
        let project = Project(name: "checkout", path: folder.path)
        let kept = UUID()
        var state = AppState()
        state.projects = [project]
        state.tabs = [SavedTab(id: kept, workspace: project.id, title: "kept", active: true)]
        try store.save(state)

        // This build's host, and one named as an earlier build's would be.
        let ownPath = TerminalHost.socketPath(for: store)
        let earlierPath = ownPath.replacingOccurrences(of: #"-[0-9a-f]+\.sock$"#, with: "-0123456789ab.sock", options: .regularExpression)
        XCTAssertNotEqual(earlierPath, ownPath)
        let ownHost = TerminalHost(socketPath: ownPath), earlierHost = TerminalHost(socketPath: earlierPath)
        try ownHost.listen()
        try earlierHost.listen()
        defer { unlink(ownPath); unlink(earlierPath) }
        let opener = try XCTUnwrap(TerminalHostClient(socketPath: earlierPath, executable: "/nonexistent"))
        let shell = try XCTUnwrap(opener.open(id: kept, workspace: project.id, shell: "/bin/zsh", cwd: folder.path,
                                              environment: environment, cols: 80, rows: 24, command: nil))
        close(shell.fd)
        let own = try XCTUnwrap(TerminalHostClient(socketPath: ownPath, executable: "/nonexistent"))
        defer { for session in own.list() { own.close(session.id) } }

        XCTAssertEqual(TerminalHost.earlierHostSockets(for: store), [earlierPath])
        let model = AppModel(store: store)
        model.restoreTabs(host: own, earlier: TerminalHost.earlierHostSockets(for: store).compactMap(TerminalHostClient.init(earlierSocketPath:)))
        XCTAssertEqual(model.tabs[project.id]?.map(\.id), [kept])
        XCTAssertEqual(model.tabs[project.id]?.first?.customTitle, "kept")

        let fresh = try XCTUnwrap(model.openTab(in: project.id))
        XCTAssertTrue(own.list().contains { $0.id == fresh.id }, "new tabs open in this build's host")
        XCTAssertEqual(opener.list().map(\.id), [kept])
        // An update this test build can't vouch for would end them: it isn't installed.
        XCTAssertTrue(model.losesTerminals(updatingTo: URL(fileURLWithPath: "/nonexistent")))

        model.closeTab(kept)
        let deadline = Date().addingTimeInterval(8)
        while opener.list().contains(where: { $0.id == kept }), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertTrue(opener.list().isEmpty, "the earlier host's terminal ended with its tab")
        model.closeTab(fresh.id)
    }

    func testAHostOfAnUnknownVersionIsntTakenForAnEarlierOne() throws {
        let store = Store(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let own = TerminalHost.socketPath(for: store)
        let older = own.replacingOccurrences(of: "plum-host-\(TerminalHost.version)-", with: "plum-host-5-")
            .replacingOccurrences(of: #"-[0-9a-f]+\.sock$"#, with: "-0123456789ab.sock", options: .regularExpression)
        let newer = older.replacingOccurrences(of: "plum-host-5-", with: "plum-host-\(TerminalHost.version + 1)-")
        for path in [older, newer] { FileManager.default.createFile(atPath: path, contents: nil) }
        defer { for path in [older, newer] { unlink(path) } }
        XCTAssertEqual(TerminalHost.earlierHostSockets(for: store), [])
    }
}
