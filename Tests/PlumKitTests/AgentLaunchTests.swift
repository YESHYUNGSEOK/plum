import XCTest
@testable import PlumKit

final class AgentLaunchTests: XCTestCase {
    func testPermissionFlagsFollowOrca() {
        var settings = AppSettings()
        XCTAssertEqual(settings.agentPermission, .own)
        XCTAssertNil(settings.command(for: .terminal))
        XCTAssertEqual(settings.command(for: .claude), AppSettings.defaultClaudeCommand)
        XCTAssertEqual(settings.command(for: .codex), "codex")

        settings.agentPermission = .fullAccess
        XCTAssertEqual(settings.command(for: .claude), AppSettings.defaultClaudeCommand + " --dangerously-skip-permissions")
        XCTAssertEqual(settings.command(for: .codex), "codex --dangerously-bypass-approvals-and-sandbox")

        settings.agentPermission = .auto
        XCTAssertEqual(settings.command(for: .claude), AppSettings.defaultClaudeCommand + " --permission-mode auto")
        XCTAssertEqual(settings.command(for: .codex), "codex --approve-for-me")

        settings.agentPermission = .own
        XCTAssertEqual(settings.command(for: .claude), AppSettings.defaultClaudeCommand)

        // A command that settles permissions itself keeps them.
        settings.agentPermission = .fullAccess
        settings.claudeCommand = "claude --permission-mode=plan"
        settings.codexCommand = "codex -s read-only"
        XCTAssertEqual(settings.command(for: .claude), "claude --permission-mode=plan")
        XCTAssertEqual(settings.command(for: .codex), "codex -s read-only")
    }

    func testOlderSettingsGetTheDefaults() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"fontSize": 14}"#.utf8))
        XCTAssertEqual(settings.agentPermission, .own)
        XCTAssertFalse(settings.trustWorkspaces)
    }

    func testOldSavedFullAccessDefaultsRequireNewOptIn() throws {
        var state = try JSONDecoder().decode(AppState.self, from: Data(
            #"{"settings":{"agentPermission":"full-access","trustWorkspaces":true}}"#.utf8))
        XCTAssertEqual(state.settings.agentPermission, .own)
        XCTAssertFalse(state.settings.trustWorkspaces)

        state.settings.agentPermission = .fullAccess
        state.settings.trustWorkspaces = true
        let saved = try JSONDecoder().decode(AppState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(saved.settings.agentPermission, .fullAccess)
        XCTAssertTrue(saved.settings.trustWorkspaces)
    }

    func testClaudeTrustKeepsTheRestOfTheConfig() throws {
        let directory = try temporaryDirectory()
        let folder = directory.appendingPathComponent("work tree").path
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let config = directory.appendingPathComponent(".claude.json").path
        XCTAssertEqual(ClaudeTrust.grant(folder, config: config), .missingConfig)

        let original = #"{"numStartups": 3, "tipsHistory": {"a": 1.5}, "projects": {"/elsewhere": {"allowedTools": ["x"]}, "\#(folder)": {"lastCost": 2}}}"#
        FileManager.default.createFile(atPath: config, contents: Data(original.utf8), attributes: [.posixPermissions: 0o600])
        XCTAssertEqual(ClaudeTrust.grant(folder, config: config), .granted)
        XCTAssertEqual(ClaudeTrust.grant(folder, config: config), .unchanged)
        XCTAssertFalse(FileManager.default.fileExists(atPath: config + ".lock"))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: config)[.posixPermissions] as? Int, 0o600)

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: config))) as? [String: Any])
        XCTAssertEqual(json["numStartups"] as? Int, 3)
        XCTAssertEqual((json["tipsHistory"] as? [String: Any])?["a"] as? Double, 1.5)
        let projects = try XCTUnwrap(json["projects"] as? [String: Any])
        XCTAssertEqual((projects["/elsewhere"] as? [String: Any])?["allowedTools"] as? [String], ["x"])
        let entry = try XCTUnwrap(projects[folder] as? [String: Any])
        XCTAssertEqual(entry["hasTrustDialogAccepted"] as? Bool, true)
        XCTAssertEqual(entry["lastCost"] as? Int, 2)
        // Claude may find it by its real path too.
        let real = ClaudeTrust.realPath(folder)
        XCTAssertTrue(real.hasPrefix("/private/"), real)
        XCTAssertEqual((projects[real] as? [String: Any])?["hasTrustDialogAccepted"] as? Bool, true)
    }

    func testClaudeTrustWaitsForClaudesLock() throws {
        let directory = try temporaryDirectory()
        let config = directory.appendingPathComponent(".claude.json").path
        FileManager.default.createFile(atPath: config, contents: Data("{}".utf8))
        try FileManager.default.createDirectory(atPath: config + ".lock", withIntermediateDirectories: false)
        XCTAssertEqual(ClaudeTrust.grant(directory.path, config: config), .locked)
        XCTAssertEqual(try String(contentsOfFile: config, encoding: .utf8), "{}")
    }

    func testCodexTrustAppendsATable() throws {
        let directory = try temporaryDirectory()
        let config = directory.appendingPathComponent("config.toml").path
        XCTAssertEqual(CodexTrust.grant(directory.path, config: config), .missingConfig)

        FileManager.default.createFile(atPath: config, contents: Data("model = \"gpt-5\"".utf8))
        XCTAssertEqual(CodexTrust.grant(directory.path, config: config), .granted)
        XCTAssertEqual(CodexTrust.grant(directory.path, config: config), .unchanged)
        let real = ClaudeTrust.realPath(directory.path)
        XCTAssertTrue(real.hasPrefix("/private/"), real)
        XCTAssertEqual(
            try String(contentsOfFile: config, encoding: .utf8),
            "model = \"gpt-5\"\n\n[projects.\"\(real)\"]\ntrust_level = \"trusted\"\n")

        // Inline tables can't be added to; the file is left alone.
        let inline = "projects = { \"/x\" = { trust_level = \"trusted\" } }\n"
        FileManager.default.createFile(atPath: config, contents: Data(inline.utf8))
        XCTAssertEqual(CodexTrust.grant(directory.path, config: config), .unreadable)
        XCTAssertEqual(try String(contentsOfFile: config, encoding: .utf8), inline)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("plum-trust-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
