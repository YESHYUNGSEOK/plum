import Foundation
import CryptoKit

/// One line from an agent hook: `<tab id> <state> [message]`, or
/// `<tab id> stop <json>` with what Claude Code's Stop hook was given.
public enum StatusMessage {
    public static func parse(_ line: String) -> (tab: UUID, status: AgentStatus, message: String)? {
        let parts = line.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2, let tab = UUID(uuidString: parts[0]) else { return nil }
        if parts[1] == "stop" {
            let (status, message) = afterStop(parts.count > 2 ? parts[2] : "")
            return (tab, status, sanitizeForDisplay(message, limit: 200))
        }
        // An agent stopped by an error (Claude's StopFailure): done, and said so in `failed`.
        if parts[1] == "failed" { return (tab, .done, failed) }
        guard let status = AgentStatus(rawValue: parts[1]) else { return nil }
        return (tab, status, sanitizeForDisplay(parts.count > 2 ? parts[2] : "", limit: 200))
    }

    /// The turn is over. Done, unless Claude Code still has work in flight
    /// that will wake it: a subagent means it is still working; a command,
    /// a monitor, a workflow or a scheduled wakeup means it is monitoring.
    /// The final answer comes along, for the notification.
    /// What a tab that stopped on an error says, in place of a last answer;
    /// the notification for it is marked apart from a finished one's.
    public static var failed: String { String(localized: "오류로 멈췄습니다.") }

    static func afterStop(_ json: String) -> (AgentStatus, String) {
        guard let input = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return (.done, "") }
        let message = input["last_assistant_message"] as? String ?? ""
        let ended: Set = ["idle", "done", "success", "succeeded", "complete", "completed", "finished", "failed", "error",
                          "terminated", "exited", "aborted", "expired", "skipped", "crashed", "killed", "cancelled", "canceled", "timed_out"]
        let running = (input["background_tasks"] as? [[String: Any]] ?? []).filter {
            !ended.contains(($0["status"] as? String ?? "").lowercased())
        }
        if running.contains(where: { ["subagent", "teammate"].contains(($0["type"] as? String ?? "").lowercased()) }) {
            return (.working, message)
        }
        if !running.isEmpty || !(input["session_crons"] as? [Any] ?? []).isEmpty { return (.monitoring, message) }
        return (.done, message)
    }
}

/// The settings file handed to Claude Code with `--settings`, so its hooks
/// report to Plum without touching the user's own configuration.
/// What an agent says of itself: its model, and how much of the plan's
/// 5-hour ("session") and weekly limits is used, in percent.
public struct AgentReport: Equatable, Sendable, Codable {
    public var model: String?
    /// How hard it thinks ("high"), where the agent says.
    public var effort: String?
    public var session: Double?
    public var weekly: Double?
    /// When each limit starts over.
    public var sessionResets: Date?
    public var weeklyResets: Date?

    static func percent(_ value: Double?) -> Double? {
        guard let value, value.isFinite, (0...100).contains(value) else { return nil }
        return value
    }

    /// "<tab> statusline <json>": Claude Code's status line input, passed on by Plum's status line command.
    public static func parse(_ line: String) -> (tab: UUID, report: AgentReport)? {
        let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count == 3, parts[1] == "statusline", let tab = UUID(uuidString: parts[0]),
              let input = try? JSONSerialization.jsonObject(with: Data(parts[2].utf8)) as? [String: Any] else { return nil }
        let limits = input["rate_limits"] as? [String: Any]
        func used(_ window: String) -> Double? { percent(((limits?[window] as? [String: Any])?["used_percentage"] as? NSNumber)?.doubleValue) }
        func resets(_ window: String) -> Date? { date((limits?[window] as? [String: Any])?["resets_at"]) }
        let model = ((input["model"] as? [String: Any])?["display_name"] as? String).map { sanitizeForDisplay($0, limit: 40) }
        let effort = ((input["effort"] as? [String: Any])?["level"] as? String).map { sanitizeForDisplay($0, limit: 12) }
        return (tab, AgentReport(model: model, effort: effort, session: used("five_hour"), weekly: used("seven_day"),
                                 sessionResets: resets("five_hour"), weeklyResets: resets("seven_day")))
    }

    /// Both agents give the time as Unix seconds.
    private static func date(_ seconds: Any?) -> Date? {
        (seconds as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
    }

    /// From a Codex session file: the last turn's model and the limits Codex
    /// was last told. Only those two records are parsed, found from the end
    /// (a turn names its model once, megabytes before the file's end).
    public static func codex(session data: Data) -> AgentReport {
        func last(_ type: String) -> [String: Any]? {
            guard let at = data.range(of: Data("\"type\":\"\(type)\"".utf8), options: .backwards) else { return nil }
            let start = data[..<at.lowerBound].lastIndex(of: 0x0A).map { $0 + 1 } ?? data.startIndex
            let end = data[at.upperBound...].firstIndex(of: 0x0A) ?? data.endIndex
            return ((try? JSONSerialization.jsonObject(with: data[start..<end])) as? [String: Any])?["payload"] as? [String: Any]
        }
        let turn = last("turn_context")
        var report = AgentReport(model: (turn?["model"] as? String).map { sanitizeForDisplay($0, limit: 40) },
                                 effort: (turn?["effort"] as? String).map { sanitizeForDisplay($0, limit: 12) })
        let limits = last("token_count")?["rate_limits"] as? [String: Any]
        for key in ["primary", "secondary"] {
            guard let window = limits?[key] as? [String: Any], let used = (window["used_percent"] as? NSNumber)?.doubleValue,
                  let minutes = (window["window_minutes"] as? NSNumber)?.intValue else { continue }
            // Codex names its windows by length: hours for the session one, a week for the other.
            if minutes < 1440 {
                (report.session, report.sessionResets) = (percent(used), date(window["resets_at"]))
            } else {
                (report.weekly, report.weeklyResets) = (percent(used), date(window["resets_at"]))
            }
        }
        return report
    }
}

/// Codex's session files (`sessions/YYYY/MM/DD/rollout-*.jsonl` in CODEX_HOME).
/// Its hooks don't say which file is theirs, so a tab's is found by folder.
/// ponytail: by folder and recency. Two Codex tabs in one folder both show
/// the newer session's model, and a session older than yesterday isn't
/// found; pass the session id through the hook if that matters.
public enum CodexSessions {
    public static func report(in folder: String, home: String = (CodexHooks.file() as NSString).deletingLastPathComponent,
                              now: Date = Date()) -> AgentReport? {
        let manager = FileManager.default
        let days = [now, now.addingTimeInterval(-86400)].map { day -> URL in
            let parts = Calendar.current.dateComponents([.year, .month, .day], from: day)
            return URL(fileURLWithPath: home).appendingPathComponent(
                String(format: "sessions/%04d/%02d/%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0))
        }
        let files = days.flatMap { (try? manager.contentsOfDirectory(at: $0, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] }
            .filter { $0.lastPathComponent.hasPrefix("rollout-") && $0.pathExtension == "jsonl" }
            .sorted { modified($0) > modified($1) }
        let marker = Data("\"cwd\":\"\(folder)\"".utf8)
        for file in files.prefix(8) {
            // The session's first record names its folder. Mapped, not read: only what is searched is paged in.
            guard let data = try? Data(contentsOf: file, options: .mappedIfSafe), data.prefix(1 << 16).range(of: marker) != nil else { continue }
            return AgentReport.codex(session: data)
        }
        return nil
    }

    private static func modified(_ file: URL) -> Date {
        (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}

/// Claude Code's session files (`projects/<folder>/<session>.jsonl` in its
/// config folder): where a Claude that wasn't started with Plum's settings
/// (typed at a prompt, or running since before) still says its model.
/// ponytail: by folder and recency, as CodexSessions; and Claude names the
/// folder with every character that isn't a letter or digit turned to "-",
/// so two folders can share one.
public enum ClaudeSessions {
    public static func report(in folder: String, environment: [String: String] = ProcessInfo.processInfo.environment,
                              home: String = NSHomeDirectory()) -> AgentReport? {
        let config = environment["CLAUDE_CONFIG_DIR"] ?? (home as NSString).appendingPathComponent(".claude")
        let name = String(folder.unicodeScalars.map { $0.isASCII && CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" })
        let sessions = URL(fileURLWithPath: config).appendingPathComponent("projects").appendingPathComponent(name)
        let files = ((try? FileManager.default.contentsOfDirectory(at: sessions, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "jsonl" }
        func modified(_ file: URL) -> Date {
            (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }
        guard let newest = files.max(by: { modified($0) < modified($1) }),
              let data = try? Data(contentsOf: newest, options: .mappedIfSafe) else { return nil }
        // The last answer's model and the last turn's effort, found from the end: `"model":"claude-opus-5-5"`.
        func last(_ marker: String) -> String? {
            guard let at = data.range(of: Data(marker.utf8), options: .backwards),
                  let close = data[at.upperBound...].prefix(60).firstIndex(of: UInt8(ascii: "\"")) else { return nil }
            return String(decoding: data[at.upperBound..<close], as: UTF8.self)
        }
        guard let model = last("\"model\":\"claude-") else { return nil }
        return AgentReport(model: displayName(model), effort: last("\"effort\":\"").map { sanitizeForDisplay($0, limit: 12) })
    }

    /// "opus-5-5-20270101" → "Opus 5.5", as Claude Code's own display name.
    static func displayName(_ id: String) -> String {
        let parts = id.split(separator: "-").map(String.init).filter { !($0.count == 8 && $0.allSatisfy(\.isNumber)) }
        guard let family = parts.first else { return id }
        let version = parts.dropFirst().joined(separator: ".")
        return sanitizeForDisplay(family.capitalized + (version.isEmpty ? "" : " " + version), limit: 40)
    }
}

/// The plan's limits for Claude, asked of Anthropic as Orca does, with the
/// login Claude Code keeps: sessions that weren't started with Plum's
/// settings have no status line to say them with. The token goes to
/// api.anthropic.com alone and is neither kept nor logged; Plum never
/// refreshes or writes the login (a stale one just gets no answer). The
/// endpoint is not a documented one.
public enum ClaudeUsage {
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    public static func fetch() async -> AgentReport? {
        guard let token = token() else { return nil }
        return await fetch(token: token, endpoint: endpoint)
    }

    static func fetch(token: String, endpoint: URL) async -> AgentReport? {
        var request = URLRequest(url: endpoint, timeoutInterval: 10)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("Plum/\(Updates.current)", forHTTPHeaderField: "User-Agent")
        guard let (bytes, response) = try? await URLSession(configuration: .ephemeral).bytes(for: request, delegate: NoRedirects()),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let data = try? await Updates.collect(bytes, expectedLength: response.expectedContentLength, limit: 64 * 1024) else { return nil }
        return parse(data)
    }

    /// `{"five_hour":{"utilization":12.0,"resets_at":"2026-11-29T01:00:00.219686+00:00"},"seven_day":{…}}`, either possibly null.
    public static func parse(_ data: Data) -> AgentReport? {
        guard let answer = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func window(_ key: String) -> (Double?, Date?) {
            let window = answer[key] as? [String: Any]
            // Fractions of a second, which the date parser doesn't take, are dropped.
            let resets = (window?["resets_at"] as? String).flatMap {
                ISO8601DateFormatter().date(from: $0.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression))
            }
            return (AgentReport.percent((window?["utilization"] as? NSNumber)?.doubleValue), resets)
        }
        let (session, weekly) = (window("five_hour"), window("seven_day"))
        return AgentReport(session: session.0, weekly: weekly.0, sessionResets: session.1, weeklyResets: weekly.1)
    }

    /// Claude Code's login: in the keychain on a Mac, as it reads it itself (through `security`), or in its config folder.
    static func token(environment: [String: String] = ProcessInfo.processInfo.environment, home: String = NSHomeDirectory()) -> String? {
        func access(_ data: Data?) -> String? {
            guard let data, let login = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["claudeAiOauth"] as? [String: Any] else { return nil }
            return login["accessToken"] as? String
        }
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        if (try? process.run()) != nil {
            let found = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if process.terminationStatus == 0, let token = access(found) { return token }
        }
        let folder = environment["CLAUDE_CONFIG_DIR"] ?? (home as NSString).appendingPathComponent(".claude")
        return access(FileManager.default.contents(atPath: (folder as NSString).appendingPathComponent(".credentials.json")))
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}

public enum HookSettings {
    /// The Stop hook hands over what it was given (one line of JSON) and
    /// lets Plum tell "done" from "waiting for background work".
    static let stopCommand = #"[ -n "$PLUM_TAB_ID" ] && { input=$(tr -d '\n'); for socket in "$PLUM_SOCKET" "$PLUM_HOST_SOCKET"; do [ -S "$socket" ] && printf '%s stop %s\n' "$PLUM_TAB_ID" "$input" | /usr/bin/nc -w 1 -U "$socket" >/dev/null 2>&1; done; }; true"#

    static func command(_ state: String) -> String {
        // Outside Plum the variables are unset and the hook does nothing.
        // The terminal host hears it too, and keeps it for a Plum that
        // isn't running now.
        ["PLUM_SOCKET", "PLUM_HOST_SOCKET"].map { socket in
            "[ -n \"$PLUM_TAB_ID\" ] && [ -S \"$\(socket)\" ] && printf '%s \(state)\\n' \"$PLUM_TAB_ID\" | /usr/bin/nc -w 1 -U \"$\(socket)\" >/dev/null 2>&1"
        }.joined(separator: "; ") + "; true"
    }

    /// Claude Code's own status line command (settings.json in its config folder), if the user set one.
    public static func userStatusLine(environment: [String: String] = ProcessInfo.processInfo.environment,
                                      home: String = NSHomeDirectory()) -> String {
        let folder = environment["CLAUDE_CONFIG_DIR"] ?? (home as NSString).appendingPathComponent(".claude")
        guard let data = FileManager.default.contents(atPath: (folder as NSString).appendingPathComponent("settings.json")),
              let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        return (settings["statusLine"] as? [String: Any])?["command"] as? String ?? ""
    }

    /// Passes Claude Code's status line input (its model and plan limits)
    /// to Plum, then on to the user's own status line command, whose
    /// output is the line shown: a status line given with `--settings`
    /// takes the place of theirs.
    static func statusLineCommand(then own: String) -> String {
        #"input=$(cat); [ -n "$PLUM_TAB_ID" ] && [ -S "$PLUM_SOCKET" ] && printf '%s statusline %s\n' "$PLUM_TAB_ID" "$(printf '%s' "$input" | tr -d '\n')" | /usr/bin/nc -w 1 -U "$PLUM_SOCKET" >/dev/null 2>&1"#
            + (own.isEmpty ? "; true" : "; printf '%s' \"$input\" | { \(own)\n}")
    }

    /// `statusLine`: the user's own status line command to run after Plum's (empty for none), or nil to leave status lines alone.
    public static func claudeSettings(statusLine: String? = nil) -> Data {
        func group(_ state: String, matcher: String? = nil) -> [[String: Any]] {
            var entry: [String: Any] = ["hooks": [["type": "command", "command": command(state)]]]
            if let matcher { entry["matcher"] = matcher }
            return [entry]
        }
        var settings: [String: Any] = ["hooks": [
            "UserPromptSubmit": group("working"),
            "PreToolUse": group("working"),
            "PostToolUse": group("working"),
            "PostToolUseFailure": group("working"),
            "Notification": group("waiting", matcher: "permission_prompt|elicitation_dialog|agent_needs_input"),
            "Stop": [["hooks": [["type": "command", "command": stopCommand]]]],
            "StopFailure": group("failed"),
            "SessionEnd": group("idle"),
        ]]
        if let statusLine {
            settings["statusLine"] = ["type": "command", "command": statusLineCommand(then: statusLine)]
        }
        return try! JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
    }
}

/// Codex's background server keeps links to its sockets in CODEX_HOME. One
/// left pointing at a socket that is gone stops every later start: the new
/// server can't put its link where the old one is ("File exists") and `codex`
/// quits with "app server did not become ready". Plum removes such a link
/// before Codex starts, so nobody has to find it by hand.
public enum CodexDaemon {
    static let links = ["app-server-control/app-server-control.sock", "app-server-daemon/daemon-updater.sock"]

    /// The links it removed. One made in the last minute stays: a server
    /// starting right now may not have made its socket yet.
    @discardableResult
    public static func removeStaleLinks(home: String = (CodexHooks.file() as NSString).deletingLastPathComponent,
                                        now: Date = Date()) -> [String] {
        let manager = FileManager.default
        return links.compactMap { link in
            let path = (home as NSString).appendingPathComponent(link)
            guard let attributes = try? manager.attributesOfItem(atPath: path), // the link itself
                  attributes[.type] as? FileAttributeType == .typeSymbolicLink,
                  !manager.fileExists(atPath: path), // what it points at
                  let made = attributes[.modificationDate] as? Date, now.timeIntervalSince(made) > 60,
                  (try? manager.removeItem(atPath: path)) != nil else { return nil }
            return path
        }
    }
}

/// Codex has no flag like Claude's `--settings`: its hooks live in
/// `hooks.json` in CODEX_HOME. Plum appends one group per event there, as
/// Orca does, marked so it finds them again; outside Plum they do nothing.
/// The user's own hooks keep their places (Codex trusts hooks by position),
/// and the file as it was is kept once as `hooks.json.pre-plum`. Codex runs
/// new hooks only after the user trusts them once (`/hooks` in Codex).
public enum CodexHooks {
    static let marker = ": plum-agent-hook-form=1;"
    static let events = ["UserPromptSubmit": "working", "PostToolUse": "working", "PermissionRequest": "waiting", "Stop": "done"]

    public static func file(environment: [String: String] = ProcessInfo.processInfo.environment, home: String = NSHomeDirectory()) -> String {
        (CodexTrust.configFile(environment: environment, home: home) as NSString).deletingLastPathComponent + "/hooks.json"
    }

    @discardableResult
    public static func install(file: String = file()) -> ClaudeTrust.Result {
        let manager = FileManager.default
        // No Codex folder, no Codex to tell.
        guard manager.fileExists(atPath: (file as NSString).deletingLastPathComponent) else { return .missingConfig }
        let resolved = ClaudeTrust.realPath(file)
        guard resolved != file || (try? manager.destinationOfSymbolicLink(atPath: file)) == nil else { return .unreadable }
        let file = resolved
        var root: [String: Any] = [:]
        let original = manager.contents(atPath: file)
        if let data = original {
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .unreadable }
            root = json
        } else if manager.fileExists(atPath: file) {
            return .unreadable
        }
        guard var hooks = (root["hooks"] ?? [String: Any]()) as? [String: Any] else { return .unreadable }
        var changed = false
        for (event, state) in events {
            guard var groups = (hooks[event] ?? [[String: Any]]()) as? [[String: Any]] else { return .unreadable }
            let command = marker + " " + HookSettings.command(state)
            let mine = groups.firstIndex { group in
                (group["hooks"] as? [[String: Any]] ?? []).contains { ($0["command"] as? String)?.hasPrefix(marker) == true }
            }
            let group: [String: Any] = ["hooks": [["type": "command", "command": command]]]
            if let mine {
                guard (groups[mine]["hooks"] as? [[String: Any]])?.first?["command"] as? String != command else { continue }
                groups[mine] = group
            } else {
                groups.append(group)
            }
            hooks[event] = groups
            changed = true
        }
        guard changed else { return .unchanged }
        root["hooks"] = hooks
        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return .unreadable }
        let backup = file + ".pre-plum"
        if manager.fileExists(atPath: file), !manager.fileExists(atPath: backup) { try? manager.copyItem(atPath: file, toPath: backup) }
        let temporary = file + ".plum-\(UUID().uuidString).tmp"
        let mode = (try? manager.attributesOfItem(atPath: file)[.posixPermissions] as? Int) ?? 0o600
        guard manager.createFile(atPath: temporary, contents: data, attributes: [.posixPermissions: mode]) else { return .unreadable }
        guard manager.contents(atPath: file) == original else { unlink(temporary); return .locked }
        guard rename(temporary, file) == 0 else {
            unlink(temporary)
            return .unreadable
        }
        return .granted
    }
}

/// Listens on a Unix socket for status lines from agent hooks.
public final class StatusServer {
    public let path: String
    private let directory: URL
    private let queue = DispatchQueue(label: "plum.status-server")
    private var listener: Int32 = -1
    private var lockFD: Int32 = -1
    private var socketIdentity: (device: dev_t, inode: ino_t)?
    private var source: DispatchSourceRead?
    private let onMessage: (UUID, AgentStatus, String) -> Void
    private let onReport: (UUID, AgentReport) -> Void

    public init(
        directory: URL,
        onMessage: @escaping (UUID, AgentStatus, String) -> Void,
        onReport: @escaping (UUID, AgentReport) -> Void = { _, _ in }
    ) {
        self.directory = directory
        // sun_path holds 104 bytes; fall back to a per-store name in the per-user temp folder.
        let preferred = directory.appendingPathComponent("plum.sock").path
        let digest = SHA256.hash(data: Data(directory.standardizedFileURL.path.utf8))
        let suffix = digest.prefix(12).map { String(format: "%02x", $0) }.joined()
        path = preferred.utf8.count < 100 ? preferred : NSTemporaryDirectory() + "plum-\(suffix).sock"
        self.onMessage = onMessage
        self.onReport = onReport
    }

    deinit { stop() }

    public func start() throws {
        guard listener < 0 else { throw POSIXError(.EALREADY) }
        let lockPath = directory.appendingPathComponent("plum.sock.lock").path
        let heldLock = open(lockPath, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard heldLock >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { if lockFD < 0 { close(heldLock) } }
        guard flock(heldLock, LOCK_EX | LOCK_NB) == 0 else { throw POSIXError(.EADDRINUSE) }
        try removeStaleSocket()

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else { close(fd); throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { _ = strlcpy($0, path, capacity) }
        }
        // Create the socket file private to this user from the start.
        let previousMask = umask(0o177)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        umask(previousMask)
        guard bound == 0 else {
            let code = errno
            close(fd)
            throw POSIXError(.init(rawValue: code) ?? .EIO)
        }
        guard listen(fd, 16) == 0 else {
            let code = errno
            close(fd)
            unlink(path)
            throw POSIXError(.init(rawValue: code) ?? .EIO)
        }
        var details = stat()
        guard lstat(path, &details) == 0 else {
            let code = errno
            close(fd)
            throw POSIXError(.init(rawValue: code) ?? .EIO)
        }
        socketIdentity = (details.st_dev, details.st_ino)
        lockFD = heldLock
        listener = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptOne() }
        source.setCancelHandler { close(fd) }
        self.source = source
        source.resume()
    }

    public func stop() {
        source?.cancel()
        source = nil
        if let identity = socketIdentity {
            var details = stat()
            if lstat(path, &details) == 0,
               details.st_dev == identity.device, details.st_ino == identity.inode,
               (details.st_mode & S_IFMT) == S_IFSOCK {
                unlink(path)
            }
        }
        socketIdentity = nil
        listener = -1
        if lockFD >= 0 { close(lockFD); lockFD = -1 }
    }

    private func removeStaleSocket() throws {
        var original = stat()
        guard lstat(path, &original) == 0 else {
            if errno == ENOENT { return }
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        guard (original.st_mode & S_IFMT) == S_IFSOCK, original.st_uid == getuid() else {
            throw POSIXError(.EADDRINUSE)
        }
        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { close(probe) }
        _ = fcntl(probe, F_SETFL, O_NONBLOCK)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { _ = strlcpy($0, path, capacity) }
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connected == 0 || errno != ECONNREFUSED { throw POSIXError(.EADDRINUSE) }
        var current = stat()
        guard lstat(path, &current) == 0,
              current.st_dev == original.st_dev, current.st_ino == original.st_ino else {
            throw POSIXError(.EADDRINUSE)
        }
        guard unlink(path) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    }

    private func acceptOne() {
        let client = accept(listener, nil, nil)
        guard client >= 0 else { return }
        defer { close(client) }

        // A stuck or hostile client must not hold up the queue.
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var nosigpipe: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, socklen_t(MemoryLayout<Int32>.size))

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        let deadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
        // A Stop hook's line carries Claude's last answer: allow for a long one.
        while data.count < 1 << 20, !data.contains(0x0A) {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { break }
            var ready = pollfd(fd: client, events: Int16(POLLIN), revents: 0)
            guard poll(&ready, 1, Int32((deadline - now) / 1_000_000)) > 0 else { break }
            let n = read(client, &buffer, buffer.count)
            guard n > 0 else { break }
            data.append(buffer, count: n)
        }
        guard data.contains(0x0A) else { return }
        let text = String(decoding: data, as: UTF8.self)

        for line in text.split(separator: "\n").prefix(32).map(String.init) {
            if line.hasPrefix("debug ") { continue }
            if let said = AgentReport.parse(line) {
                DispatchQueue.main.async { [onReport] in onReport(said.tab, said.report) }
            } else if let message = StatusMessage.parse(line) {
                DispatchQueue.main.async { [onMessage] in onMessage(message.tab, message.status, message.message) }
            }
        }
    }
}
