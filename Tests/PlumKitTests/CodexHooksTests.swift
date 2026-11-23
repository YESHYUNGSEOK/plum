import XCTest
@testable import PlumKit

/// Codex tells Plum its state through hooks Plum adds to Codex's hooks.json,
/// after the user's own, which keep their places.
final class CodexHooksTests: XCTestCase {
    private var home: URL!
    private var file: String { home.appendingPathComponent("hooks.json").path }

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("plum-codex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: home)
    }

    func testAddsAfterTheUsersOwnHooksOnce() throws {
        let own = #"{"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "/usr/local/bin/quality-gate"}]}]}, "other": 1}"#
        try Data(own.utf8).write(to: URL(fileURLWithPath: file))
        XCTAssertEqual(CodexHooks.install(file: file), .granted)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: file))) as? [String: Any])
        let hooks = try XCTUnwrap(root["hooks"] as? [String: [[String: Any]]])
        XCTAssertEqual(Set(hooks.keys), ["Stop", "UserPromptSubmit", "PostToolUse", "PermissionRequest"])
        let stop = try XCTUnwrap(hooks["Stop"])
        XCTAssertEqual(stop.count, 2)
        XCTAssertEqual((stop[0]["hooks"] as? [[String: Any]])?.first?["command"] as? String, "/usr/local/bin/quality-gate", "theirs first, where it was")
        let mine = try XCTUnwrap((stop[1]["hooks"] as? [[String: Any]])?.first?["command"] as? String)
        XCTAssertTrue(mine.hasPrefix(CodexHooks.marker) && mine.contains("done"))
        XCTAssertEqual(root["other"] as? Int, 1, "the rest of the file stays")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file + ".pre-plum"))

        XCTAssertEqual(CodexHooks.install(file: file), .unchanged, "once")
    }

    func testAnOlderPlumHookIsReplacedInPlace() throws {
        let old = #"{"hooks": {"Stop": [{"hooks": [{"type": "command", "command": ": plum-agent-hook-form=1; old"}]}, {"hooks": [{"type": "command", "command": "theirs"}]}]}}"#
        try Data(old.utf8).write(to: URL(fileURLWithPath: file))
        XCTAssertEqual(CodexHooks.install(file: file), .granted)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: file))) as? [String: Any])
        let stop = try XCTUnwrap((root["hooks"] as? [String: [[String: Any]]])?["Stop"])
        XCTAssertEqual(stop.count, 2)
        XCTAssertNotEqual((stop[0]["hooks"] as? [[String: Any]])?.first?["command"] as? String, ": plum-agent-hook-form=1; old")
        XCTAssertEqual((stop[1]["hooks"] as? [[String: Any]])?.first?["command"] as? String, "theirs")
    }

    func testLeavesWhatItCantReadAlone() throws {
        try Data("{ not json".utf8).write(to: URL(fileURLWithPath: file))
        XCTAssertEqual(CodexHooks.install(file: file), .unreadable)
        XCTAssertEqual(try String(contentsOfFile: file, encoding: .utf8), "{ not json")
        XCTAssertEqual(CodexHooks.install(file: home.appendingPathComponent("no-codex/hooks.json").path), .missingConfig)
    }

    func testTheHookReportsOnlyInsidePlum() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: "/usr/bin/nc"))
        XCTAssertEqual(CodexHooks.install(file: file), .granted)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: file))) as? [String: Any])
        let command = try XCTUnwrap(((root["hooks"] as? [String: [[String: Any]]])?["PermissionRequest"]?.first?["hooks"] as? [[String: Any]])?.first?["command"] as? String)
        // Outside Plum: nothing set, exits 0 and says nothing (Codex reads a hook's output).
        let outside = Process()
        outside.executableURL = URL(fileURLWithPath: "/bin/sh")
        outside.arguments = ["-c", command]
        outside.environment = [:]
        let pipe = Pipe()
        outside.standardOutput = pipe
        try outside.run()
        outside.waitUntilExit()
        XCTAssertEqual(outside.terminationStatus, 0)
        XCTAssertTrue(pipe.fileHandleForReading.readDataToEndOfFile().isEmpty)
    }
}
