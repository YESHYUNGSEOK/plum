import XCTest
@testable import PlumKit

/// Choosing what a new workspace or tab starts: a shell, Claude or Codex.
@MainActor
final class TabProgramTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("plum-program-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A state file from before the choice existed: settings without the new
    /// fields, and the agent command kept on the project.
    private func writeOldState(agentCommand: String) throws {
        let json = """
        {"projects":[{"id":"11111111-1111-1111-1111-111111111111","name":"app","path":"/nonexistent/app","baseBranch":"",
        "copyPatterns":[],"setupCommand":"pnpm install","agentCommand":\(String(reflecting: agentCommand))}],
        "workspaces":[],"settings":{"fontName":"","fontSize":14,"workspaceRoot":"~/ws","branchPrefix":"me/"}}
        """
        try Data(json.utf8).write(to: directory.appendingPathComponent("state.json"))
    }

    func testOldSettingsLoadAndTheProjectsAgentCommandMovesToTheSettings() throws {
        let custom = "claude --settings \"$PLUM_CLAUDE_SETTINGS\" --model opus"
        try writeOldState(agentCommand: custom)
        let model = AppModel(store: Store(directory: directory))
        XCTAssertEqual(model.state.settings.fontSize, 14, "the rest of the old settings is kept")
        XCTAssertEqual(model.state.settings.branchPrefix, "me/")
        XCTAssertEqual(model.state.settings.claudeCommand, custom)
        XCTAssertEqual(model.state.settings.codexCommand, AppSettings.defaultCodexCommand)
        XCTAssertEqual(model.state.settings.newWorkspaceProgram, .claude, "new workspaces keep starting the agent")
        XCTAssertEqual(model.state.projects[0].agentCommand, "")

        let reloaded = AppModel(store: Store(directory: directory))
        XCTAssertEqual(reloaded.state.settings.claudeCommand, custom, "saved, and not moved twice")
    }

    func testAnOldCodexCommandBecomesTheCodexCommand() throws {
        try writeOldState(agentCommand: "codex --full-auto")
        let model = AppModel(store: Store(directory: directory))
        XCTAssertEqual(model.state.settings.codexCommand, "codex --full-auto")
        XCTAssertEqual(model.state.settings.claudeCommand, AppSettings.defaultClaudeCommand)
        XCTAssertEqual(model.state.settings.newWorkspaceProgram, .codex)
    }

    func testTheFirstTabRunsSetupThenTheChosenProgram() throws {
        try writeOldState(agentCommand: "")
        let model = AppModel(store: Store(directory: directory))
        XCTAssertEqual(model.state.settings.newWorkspaceProgram, .terminal, "nothing to carry over")
        var project = model.state.projects[0]
        XCTAssertEqual(model.firstCommand(for: project, program: .terminal), "pnpm install")
        XCTAssertEqual(model.firstCommand(for: project, program: .claude), "pnpm install && " + AppSettings.defaultClaudeCommand + " --dangerously-skip-permissions")
        project.setupCommand = ""
        XCTAssertEqual(model.firstCommand(for: project, program: .codex), "codex --dangerously-bypass-approvals-and-sandbox")
        XCTAssertEqual(model.firstCommand(for: project, program: .terminal), "")
    }
}
