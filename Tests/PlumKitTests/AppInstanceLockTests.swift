import XCTest
@testable import PlumKit

final class AppInstanceLockTests: XCTestCase {
    func testSecondAppCannotOpenTheSameState() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("plum-instance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var first: AppInstanceLock? = try AppInstanceLock(directory: directory)
        XCTAssertThrowsError(try AppInstanceLock(directory: directory))
        first = nil
        XCTAssertNoThrow(try AppInstanceLock(directory: directory))
    }

    func testExistingStatusServerPreventsOpeningState() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("plum-instance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = StatusServer(directory: directory, onMessage: { _, _, _ in })
        try server.start()
        defer { server.stop() }

        XCTAssertThrowsError(try AppInstanceLock(directory: directory))
    }
}
