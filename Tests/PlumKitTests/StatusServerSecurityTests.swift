import Darwin
import XCTest
@testable import PlumKit

final class StatusServerSecurityTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("plum-status-security-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    func testSecondServerCannotReplaceAnActiveSocket() throws {
        let first = StatusServer(directory: directory, onMessage: { _, _, _ in })
        let second = StatusServer(directory: directory, onMessage: { _, _, _ in })
        try first.start()
        defer { first.stop(); second.stop() }
        let original = try inode(at: first.path)

        XCTAssertThrowsError(try second.start())
        XCTAssertEqual(try inode(at: first.path), original)
    }

    func testStoppingOldServerKeepsAReplacementAtItsPath() throws {
        let server = StatusServer(directory: directory, onMessage: { _, _, _ in })
        try server.start()
        defer { server.stop() }
        XCTAssertEqual(unlink(server.path), 0)
        let replacement = Data("another owner's file".utf8)
        try replacement.write(to: URL(fileURLWithPath: server.path))

        server.stop()

        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: server.path)), replacement)
    }

    func testLongStateDirectoriesHaveDistinctFallbackSockets() throws {
        let firstDirectory = directory.appendingPathComponent(String(repeating: "a", count: 80))
        let secondDirectory = directory.appendingPathComponent(String(repeating: "b", count: 80))
        try FileManager.default.createDirectory(at: firstDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondDirectory, withIntermediateDirectories: true)
        let first = StatusServer(directory: firstDirectory, onMessage: { _, _, _ in })
        let second = StatusServer(directory: secondDirectory, onMessage: { _, _, _ in })
        XCTAssertNotEqual(first.path, second.path)
        try first.start()
        defer { first.stop(); second.stop() }
        try second.start()
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
    }

    func testStatusSocketClosesDebugRequestsWithoutReply() throws {
        let server = StatusServer(directory: directory, onMessage: { _, _, _ in })
        try server.start()
        defer { server.stop() }

        let client = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(client, 0)
        defer { close(client) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) {
                _ = strlcpy($0, server.path, capacity)
            }
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(client, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(connected, 0)
        let command = "debug state\n"
        XCTAssertEqual(command.withCString { write(client, $0, strlen($0)) }, command.utf8.count)
        var response: UInt8 = 0
        XCTAssertEqual(read(client, &response, 1), 0)
    }

    func testSlowClientCannotHoldUpFollowingStatus() throws {
        let tab = UUID()
        let heard = expectation(description: "following status")
        let server = StatusServer(directory: directory, onMessage: { id, status, _ in
            if id == tab, status == .waiting { heard.fulfill() }
        })
        try server.start()
        defer { server.stop() }

        func client() throws -> Int32 {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw POSIXError(.EIO) }
            var noSigPipe: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let capacity = MemoryLayout.size(ofValue: address.sun_path)
            withUnsafeMutablePointer(to: &address.sun_path) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: capacity) {
                    _ = strlcpy($0, server.path, capacity)
                }
            }
            let connected = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard connected == 0 else { close(fd); throw POSIXError(.ECONNREFUSED) }
            return fd
        }

        let slow = try client()
        let dripper = DispatchGroup()
        dripper.enter()
        defer { dripper.wait(); close(slow) }
        DispatchQueue.global().async {
            defer { dripper.leave() }
            for _ in 0..<15 {
                let byte: UInt8 = 0x61
                guard withUnsafePointer(to: byte, { write(slow, $0, 1) }) == 1 else { break }
                usleep(200_000)
            }
        }
        let following = try client()
        defer { close(following) }
        let line = "\(tab.uuidString) waiting hello\n"
        XCTAssertEqual(line.withCString { write(following, $0, strlen($0)) }, line.utf8.count)
        wait(for: [heard], timeout: 2)
    }

    func testIncompleteStatusLineIsIgnored() throws {
        let tab = UUID()
        let heard = expectation(description: "incomplete status")
        heard.isInverted = true
        let server = StatusServer(directory: directory, onMessage: { id, _, _ in
            if id == tab { heard.fulfill() }
        })
        try server.start()
        defer { server.stop() }

        let client = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(client, 0)
        defer { close(client) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) {
                _ = strlcpy($0, server.path, capacity)
            }
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(client, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(connected, 0)
        let line = "\(tab.uuidString) waiting incomplete"
        XCTAssertEqual(line.withCString { write(client, $0, strlen($0)) }, line.utf8.count)
        XCTAssertEqual(shutdown(client, SHUT_WR), 0)
        wait(for: [heard], timeout: 0.2)
    }

    private func inode(at path: String) throws -> UInt64 {
        var details = stat()
        guard lstat(path, &details) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        return details.st_ino
    }
}
