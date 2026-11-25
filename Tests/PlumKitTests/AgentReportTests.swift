import XCTest
@testable import PlumKit

/// An agent's model and plan limits: from Claude Code's status line input, and from a Codex session file.
final class AgentReportTests: XCTestCase {
    func testClaudeStatusLineInput() throws {
        let tab = UUID()
        let json = #"{"session_id":"s","model":{"id":"claude-opus-5-5","display_name":"Opus 5.5"},"effort":{"level":"high"},"rate_limits":{"five_hour":{"used_percentage":41.6,"resets_at":1795500000},"seven_day":{"used_percentage":18,"resets_at":1795900000}}}"#
        let said = try XCTUnwrap(AgentReport.parse("\(tab.uuidString) statusline \(json)"))
        XCTAssertEqual(said.tab, tab)
        XCTAssertEqual(said.report, AgentReport(model: "Opus 5.5", effort: "high", session: 41.6, weekly: 18, sessionResets: Date(timeIntervalSince1970: 1795500000),
                                                weeklyResets: Date(timeIntervalSince1970: 1795900000)))

        // An API key user, or before the first answer: no limits; a model still.
        let bare = try XCTUnwrap(AgentReport.parse("\(tab.uuidString) statusline {\"model\":{\"display_name\":\"Sonnet 5.5\"}}"))
        XCTAssertEqual(bare.report, AgentReport(model: "Sonnet 5.5"))
        XCTAssertNil(AgentReport.parse("\(tab.uuidString) statusline not json"))
        XCTAssertNil(AgentReport.parse("\(tab.uuidString) done"), "a state line is not a report")
        XCTAssertNil(StatusMessage.parse("\(tab.uuidString) statusline \(json)"), "nor a report a state line")
    }

    func testInvalidUsagePercentagesAreIgnored() throws {
        let tab = UUID()
        let json = #"{"rate_limits":{"five_hour":{"used_percentage":1e100},"seven_day":{"used_percentage":-1}}}"#
        let said = try XCTUnwrap(AgentReport.parse("\(tab.uuidString) statusline \(json)"))
        XCTAssertNil(said.report.session)
        XCTAssertNil(said.report.weekly)

        let codex = Data(#"{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":1e100,"window_minutes":300}}}}"#.utf8)
        XCTAssertNil(AgentReport.codex(session: codex).session)
        XCTAssertNil(ClaudeUsage.parse(Data(#"{"five_hour":{"utilization":1e100}}"#.utf8))?.session)
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
                #"{"type":"turn_context","payload":{"cwd":"\#(folder)","model":"\#(model)","effort":"high"}}"#,
                #"{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":\#(weekly).0,"window_minutes":10080,"resets_at":1795847887},"secondary":null}}}"#,
            ]
            try Data(lines.joined(separator: "\n").utf8).write(to: day.appendingPathComponent("rollout-\(name).jsonl"))
        }
        try session("a", folder: "/work/한글 폴더", model: "gpt-x", weekly: 25)
        try session("b", folder: "/work/other", model: "gpt-y", weekly: 60)

        // The last turn's model, and only the windows the last report had.
        XCTAssertEqual(CodexSessions.report(in: "/work/한글 폴더", home: home.path, now: now), AgentReport(model: "gpt-x", effort: "high", weekly: 25, weeklyResets: Date(timeIntervalSince1970: 1795847887)))
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

    func testAClaudeNotStartedByPlumStillSaysItsModelInItsSessionFile() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("plum-claude-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let folder = "/Users/me/work/한글.repo"
        let sessions = home.appendingPathComponent(".claude/projects/-Users-me-work----repo")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let lines = [
            #"{"type":"assistant","message":{"model":"claude-sonnet-5-5","content":[]}}"#,
            #"{"type":"user","message":{"content":"which \"model\":\"claude-fake is this?"}}"#,
            #"{"type":"assistant","message":{"model":"claude-opus-5-5-20270101","content":[]},"effort":"medium"}"#,
            #"{"type":"assistant","message":{"model":"<synthetic>","content":[]}}"#,
        ]
        try Data(lines.joined(separator: "\n").utf8).write(to: sessions.appendingPathComponent("s.jsonl"))
        XCTAssertEqual(ClaudeSessions.report(in: folder, environment: [:], home: home.path), AgentReport(model: "Opus 5.5", effort: "medium"))
        XCTAssertNil(ClaudeSessions.report(in: "/Users/me/elsewhere", environment: [:], home: home.path))
        XCTAssertEqual(ClaudeSessions.displayName("fable-5-2"), "Fable 5.2")
    }

    func testAnthropicsUsageAnswer() throws {
        let answer = #"{"five_hour":null,"seven_day":{"utilization":51.0,"resets_at":"2026-11-29T01:00:00.219686+00:00"},"extra_usage":{"is_enabled":false}}"#
        let report = try XCTUnwrap(ClaudeUsage.parse(Data(answer.utf8)))
        XCTAssertNil(report.session)
        XCTAssertEqual(report.weekly, 51)
        XCTAssertEqual(report.weeklyResets, ISO8601DateFormatter().date(from: "2026-11-29T01:00:00Z"))
        XCTAssertNil(ClaudeUsage.parse(Data("rate limited".utf8)))
    }

    func testClaudeUsageDoesNotFollowRedirects() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("plum-usage-redirect-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        let script = """
        from http.server import BaseHTTPRequestHandler, HTTPServer
        import sys
        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                if self.path == '/start':
                    self.send_response(302)
                    self.send_header('Location', '/redirected')
                    self.end_headers()
                else:
                    open(sys.argv[1], 'w').write(self.headers.get('Authorization', ''))
                    self.send_response(200)
                    self.end_headers()
                    self.wfile.write(b'{"five_hour":null,"seven_day":null}')
            def log_message(self, *args):
                pass
        server = HTTPServer(('127.0.0.1', 0), Handler)
        print(server.server_port, flush=True)
        server.serve_forever()
        """
        let server = Process()
        let output = Pipe()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-u", "-c", script, marker.path]
        server.standardOutput = output
        server.standardError = FileHandle.nullDevice
        try server.run()
        defer { server.terminate(); server.waitUntilExit() }
        let port = try XCTUnwrap(Int(String(decoding: output.fileHandleForReading.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
        let endpoint = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/start"))

        let report = await ClaudeUsage.fetch(token: "test-token", endpoint: endpoint)

        XCTAssertNil(report)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    @MainActor
    func testNotificationTitlesAreMarkedByWhatHappened() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("plum-marks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var project = Project(name: "alpha", path: directory.path)
        project.folder = true
        var state = AppState()
        state.projects = [project]
        try Store(directory: directory.appendingPathComponent("state")).save(state)
        let model = AppModel(store: Store(directory: directory.appendingPathComponent("state")))
        try await model.createWorkspace(projectID: project.id, name: "one", branch: "", choice: .new(base: nil), program: .terminal)
        let tab = try XCTUnwrap(model.tabs[model.state.workspaces[0].id]?.first)
        var titles: [String] = []
        model.notify = { title, _, _ in titles.append(title) }
        func say(_ line: String) throws {
            let message = try XCTUnwrap(StatusMessage.parse("\(tab.id.uuidString) \(line)"))
            model.setStatus(message.status, message: message.message, tab: tab.id, structured: true)
        }
        try say("waiting")
        try say("working")
        try say("done all good")
        try say("working")
        try say("failed")
        XCTAssertEqual(titles, ["🐱 alpha · one", "👍 alpha · one", "😡 alpha · one"])
        model.closeTab(tab.id)
    }

    func testCodexLimitsSayWhenAndAccountIsRead() throws {
        let said = Data(#"{"timestamp":"2026-11-24T14:59:54.240Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":4.0,"window_minutes":10080}}}}"#.utf8)
        let report = AgentReport.codex(session: said)
        XCTAssertEqual(report.weekly, 4)
        XCTAssertEqual(report.at, Date(timeIntervalSince1970: 1795532394.24))
        // No limits said: no time either, so it never replaces what is held.
        let empty = Data(#"{"timestamp":"2026-11-24T14:59:54.240Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{}}}"#.utf8)
        XCTAssertEqual(AgentReport.codex(session: empty), AgentReport())

        let home = FileManager.default.temporaryDirectory.appendingPathComponent("plum-codex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        XCTAssertNil(CodexSessions.account(home: home.path))
        try Data(#"{"tokens":{"account_id":"a"}}"#.utf8).write(to: home.appendingPathComponent("auth.json"))
        let first = try XCTUnwrap(CodexSessions.account(home: home.path))
        try Data(#"{"tokens":{"account_id":"b"}}"#.utf8).write(to: home.appendingPathComponent("auth.json"))
        let second = try XCTUnwrap(CodexSessions.account(home: home.path))
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(first.id.count, 64) // a digest, not the id itself
    }
}
