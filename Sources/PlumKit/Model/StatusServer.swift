import Foundation

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
        guard let status = AgentStatus(rawValue: parts[1]) else { return nil }
        return (tab, status, sanitizeForDisplay(parts.count > 2 ? parts[2] : "", limit: 200))
    }

    /// The turn is over. Done, unless Claude Code still has work in flight
    /// that will wake it: a subagent means it is still working; a command,
    /// a monitor, a workflow or a scheduled wakeup means it is monitoring.
    /// The final answer comes along, for the notification.
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

    public static func claudeSettings() -> Data {
        func group(_ state: String, matcher: String? = nil) -> [[String: Any]] {
            var entry: [String: Any] = ["hooks": [["type": "command", "command": command(state)]]]
            if let matcher { entry["matcher"] = matcher }
            return [entry]
        }
        let settings: [String: Any] = ["hooks": [
            "UserPromptSubmit": group("working"),
            "PreToolUse": group("working"),
            "PostToolUse": group("working"),
            "PostToolUseFailure": group("working"),
            "Notification": group("waiting", matcher: "permission_prompt|elicitation_dialog|agent_needs_input"),
            "Stop": [["hooks": [["type": "command", "command": stopCommand]]]],
            "StopFailure": group("done"),
            "SessionEnd": group("idle"),
        ]]
        return try! JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
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
        var root: [String: Any] = [:]
        if let data = manager.contents(atPath: file) {
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
    private let queue = DispatchQueue(label: "plum.status-server")
    private var listener: Int32 = -1
    private var source: DispatchSourceRead?
    private let onMessage: (UUID, AgentStatus, String) -> Void
    /// Test hook: answers lines starting with "debug ". Runs on the main thread.
    private let debugHandler: ((String) -> String)?

    public init(
        directory: URL,
        onMessage: @escaping (UUID, AgentStatus, String) -> Void,
        debugHandler: ((String) -> String)? = nil
    ) {
        // sun_path holds 104 bytes; fall back to the per-user temp folder.
        let preferred = directory.appendingPathComponent("plum.sock").path
        path = preferred.utf8.count < 100 ? preferred : NSTemporaryDirectory() + "plum.sock"
        self.onMessage = onMessage
        self.debugHandler = debugHandler
    }

    deinit { stop() }

    public func start() throws {
        unlink(path)
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
        guard bound == 0, listen(fd, 16) == 0 else {
            let code = errno
            close(fd)
            throw POSIXError(.init(rawValue: code) ?? .EIO)
        }
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
        if listener >= 0 { unlink(path) }
        listener = -1
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
        // A Stop hook's line carries Claude's last answer: allow for a long one.
        while data.count < 1 << 20, !data.contains(0x0A) {
            let n = read(client, &buffer, buffer.count)
            guard n > 0 else { break }
            data.append(buffer, count: n)
        }
        let text = String(decoding: data, as: UTF8.self)

        for line in text.split(separator: "\n").prefix(32).map(String.init) {
            if line.hasPrefix("debug "), let debugHandler {
                let reply = DispatchQueue.main.sync { debugHandler(String(line.dropFirst(6))) } + "\n"
                _ = reply.withCString { write(client, $0, strlen($0)) }
            } else if let message = StatusMessage.parse(line) {
                DispatchQueue.main.async { [onMessage] in onMessage(message.tab, message.status, message.message) }
            }
        }
    }
}
