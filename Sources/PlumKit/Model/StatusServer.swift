import Foundation

/// One line from an agent hook: `<tab id> <state> [message]`.
public enum StatusMessage {
    public static func parse(_ line: String) -> (tab: UUID, status: AgentStatus, message: String)? {
        let parts = line.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2, let tab = UUID(uuidString: parts[0]), let status = AgentStatus(rawValue: parts[1]) else { return nil }
        return (tab, status, sanitizeForDisplay(parts.count > 2 ? parts[2] : "", limit: 200))
    }
}

/// The settings file handed to Claude Code with `--settings`, so its hooks
/// report to Plum without touching the user's own configuration.
public enum HookSettings {
    static func command(_ state: String) -> String {
        // Outside Plum the variables are unset and the hook does nothing.
        "[ -n \"$PLUM_TAB_ID\" ] && [ -S \"$PLUM_SOCKET\" ] && printf '%s \(state)\\n' \"$PLUM_TAB_ID\" | /usr/bin/nc -w 1 -U \"$PLUM_SOCKET\" >/dev/null 2>&1; true"
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
            "Stop": group("done"),
            "StopFailure": group("done"),
            "SessionEnd": group("idle"),
        ]]
        return try! JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
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
        while data.count < 64 * 1024, !data.contains(0x0A) {
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
