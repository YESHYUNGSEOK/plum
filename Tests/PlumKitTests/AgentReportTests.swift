import XCTest
@testable import PlumKit

/// An agent's model and plan limits: from Claude Code's status line input, and from a Codex session file.
final class AgentReportTests: XCTestCase {
    func testClaudeStatusLineInput() throws {
        let tab = UUID()
        let json = #"{"session_id":"s","model":{"id":"claude-opus-5-5","display_name":"Opus 5.5"},"rate_limits":{"five_hour":{"used_percentage":41.6,"resets_at":1795500000},"seven_day":{"used_percentage":18,"resets_at":1795900000}}}"#
        let said = try XCTUnwrap(AgentReport.parse("\(tab.uuidString) statusline \(json)"))
        XCTAssertEqual(said.tab, tab)
        XCTAssertEqual(said.report, AgentReport(model: "Opus 5.5", session: 41.6, weekly: 18, sessionResets: Date(timeIntervalSince1970: 1795500000),
                                                weeklyResets: Date(timeIntervalSince1970: 1795900000)))

        // An API key user, or before the first answer: no limits; a model still.
        let bare = try XCTUnwrap(AgentReport.parse("\(tab.uuidString) statusline {\"model\":{\"display_name\":\"Sonnet 5.5\"}}"))
        XCTAssertEqual(bare.report, AgentReport(model: "Sonnet 5.5"))
        XCTAssertNil(AgentReport.parse("\(tab.uuidString) statusline not json"))
        XCTAssertNil(AgentReport.parse("\(tab.uuidString) done"), "a state line is not a report")
        XCTAssertNil(StatusMessage.parse("\(tab.uuidString) statusline \(json)"), "nor a report a state line")
    }

    func testCodexSessionFileFoundByFolder() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("plum-codex-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let now = Date()
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: now)
        let day = home.appendingPathComponent(String(format: "sessions/%04d/%02d/%02d", parts.year!, parts.month!, parts.day!))
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        func session(_ name: String, folder: String, model: String, weekly: Int) throws {
            let lines = [
                #"{"type":"session_meta","payload":{"id":"x","cwd":"\#(folder)"}}"#,
                #"{"type":"turn_context","payload":{"cwd":"\#(folder)","model":"old-model"}}"#,
                #"{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":90.0,"window_minutes":300},"secondary":{"used_percent":1.0,"window_minutes":10080}}}}"#,
                #"{"type":"turn_context","payload":{"cwd":"\#(folder)","model":"\#(model)"}}"#,
                #"{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":\#(weekly).0,"window_minutes":10080,"resets_at":1795847887},"secondary":null}}}"#,
            ]
            try Data(lines.joined(separator: "\n").utf8).write(to: day.appendingPathComponent("rollout-\(name).jsonl"))
        }
        try session("a", folder: "/work/한글 폴더", model: "gpt-x", weekly: 25)
        try session("b", folder: "/work/other", model: "gpt-y", weekly: 60)

        // The last turn's model, and only the windows the last report had.
        XCTAssertEqual(CodexSessions.report(in: "/work/한글 폴더", home: home.path, now: now), AgentReport(model: "gpt-x", weekly: 25, weeklyResets: Date(timeIntervalSince1970: 1795847887)))
        XCTAssertEqual(CodexSessions.report(in: "/work/other", home: home.path, now: now)?.model, "gpt-y")
        XCTAssertNil(CodexSessions.report(in: "/work/none", home: home.path, now: now))
    }

    func testStatusLineIsInstalledOnlyWhenAskedAndRunsTheUsersOwn() throws {
        func settings(_ data: Data) throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]) }
        XCTAssertNil(try settings(HookSettings.claudeSettings())["statusLine"], "status lines left alone")
        let line = try XCTUnwrap(try settings(HookSettings.claudeSettings(statusLine: "~/bin/my-line.sh"))["statusLine"] as? [String: Any])
        let command = try XCTUnwrap(line["command"] as? String)
        XCTAssertTrue(command.contains("statusline"))
        XCTAssertTrue(command.contains("~/bin/my-line.sh"), "theirs still draws the line")

        // Run for real: Plum's socket hears the input, and their command gets it too.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("plum-line-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let heard = expectation(description: "report")
        let tab = UUID()
        let server = StatusServer(directory: URL(fileURLWithPath: "/tmp/plum-line-\(getpid())"), onMessage: { _, _, _ in }, onReport: { id, report in
            if id == tab, report.model == "Opus 5.5" { heard.fulfill() }
        })
        try FileManager.default.createDirectory(atPath: "/tmp/plum-line-\(getpid())", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: "/tmp/plum-line-\(getpid())") }
        try server.start()
        defer { server.stop() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", HookSettings.statusLineCommand(then: "tr a-z A-Z # theirs")]
        process.environment = ["PLUM_TAB_ID": tab.uuidString, "PLUM_SOCKET": server.path]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        input.fileHandleForWriting.write(Data("{\"model\":{\"display_name\":\"Opus 5.5\"},\n\"x\":1}".utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertEqual(String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), "{\"MODEL\":{\"DISPLAY_NAME\":\"OPUS 5.5\"},\n\"X\":1}")
        wait(for: [heard], timeout: 3)
    }
}
