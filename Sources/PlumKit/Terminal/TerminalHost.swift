import CPty
import Foundation
import GhosttyVt
import Security

@_silgen_name("csops_audittoken")
private func csopsAuditToken(_ pid: pid_t, _ ops: UInt32, _ data: UnsafeMutableRawPointer,
                             _ size: Int, _ token: UnsafeMutablePointer<audit_token_t>) -> Int32

/// The process that keeps terminals alive while Plum isn't running.
///
/// Plum starts it once (the same executable, `--terminal-host <socket>`).
/// It owns every pty: shells, agents and dev servers keep running when the
/// app quits, and the app attaches to them again when it starts.
///
/// While the app is attached, the host only passes bytes along; the app's
/// own terminal parses them. When the app quits it hands each terminal's
/// screen over (`park`), and from then on the host parses the output into a
/// terminal of its own. Attaching again sends that screen back as VT
/// sequences, scrollback and modes included, and the host stops parsing.
/// Nothing is parsed twice while the app runs.
///
/// Protocol: a connection starts with one JSON line. `open` and `attach`
/// answer with one JSON line and then carry the terminal: output from the
/// host, input to it. Every other request is answered with one JSON line,
/// and more requests may follow on the same connection.
public final class TerminalHost {
    /// Bumped whenever the protocol or what the host does changes: a host
    /// started by an older Plum keeps its own socket and its own terminals.
    public static let version = 5

    private let socketPath: String
    private let lock = NSLock()
    private var sessions: [String: HostSession] = [:]
    private var connectedClients = 0
    private var lastActivity = Date()

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    /// The socket a store's host listens on. In the per-user temporary
    /// folder (a socket path must stay under 104 bytes), named after the
    /// store so a test instance never reaches the user's terminals.
    public static func socketPath(for store: Store) -> String {
        socketPath(for: store, version: version, codeHash: ownCodeHash())
    }

    public static func legacySocketPath(for store: Store) -> String {
        socketPath(for: store, version: 1)
    }

    private static func socketPath(for store: Store, version: Int, codeHash: String? = nil) -> String {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325 // FNV-1a: the same every launch, unlike hashValue
        for byte in store.directory.standardizedFileURL.path.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100_0000_01B3
        }
        let suffix = codeHash.map { "-\($0.prefix(12))" } ?? ""
        return NSTemporaryDirectory() + "plum-host-\(version)-\(String(hash, radix: 16))\(suffix).sock"
    }

    /// Runs the host until it has had no terminals for a minute.
    public static func run(socketPath: String) -> Never {
        guard sameCode(as: getppid()) else { exit(1) }
        signal(SIGPIPE, SIG_IGN) // a vanished app is noticed by its writes failing
        signal(SIGHUP, SIG_IGN)
        let host = TerminalHost(socketPath: socketPath)
        do { try host.listen() } catch { exit(1) }
        while true {
            sleep(15)
            if host.idle(for: 60) { exit(0) }
        }
    }

    func idle(for seconds: TimeInterval) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return sessions.isEmpty && connectedClients == 0 && Date().timeIntervalSince(lastActivity) > seconds
    }

    /// Starts accepting connections on a thread of its own.
    public func listen() throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        guard socketPath.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            socketPath.withCString { _ = strcpy(raw.baseAddress!.assumingMemoryBound(to: CChar.self), $0) }
        }
        let lockFD = open(socketPath + ".lock", O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lockFD >= 0 else { throw POSIXError(.EIO) }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { close(lockFD); throw POSIXError(.EADDRINUSE) }
        let server = socket(AF_UNIX, SOCK_STREAM, 0)
        guard server >= 0 else { close(lockFD); throw POSIXError(.EIO) }
        var listening = false
        defer {
            if !listening { close(server); close(lockFD) }
        }
        _ = fcntl(server, F_SETFD, FD_CLOEXEC)
        _ = fcntl(lockFD, F_SETFD, FD_CLOEXEC)
        var existing = stat()
        if lstat(socketPath, &existing) == 0 {
            guard existing.st_mode & S_IFMT == S_IFSOCK else { throw POSIXError(.EEXIST) }
            let probe = socket(AF_UNIX, SOCK_STREAM, 0)
            guard probe >= 0 else { throw POSIXError(.EIO) }
            guard fcntl(probe, F_SETFL, O_NONBLOCK) >= 0 else { close(probe); throw POSIXError(.EIO) }
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            let error = errno
            close(probe)
            guard connected != 0, error == ECONNREFUSED else { throw POSIXError(.EADDRINUSE) }
            guard unlink(socketPath) == 0 else { throw POSIXError(.EIO) }
        } else if errno != ENOENT {
            throw POSIXError(.EIO)
        }
        let previous = umask(0o077) // the terminals are the user's alone
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(server, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        umask(previous)
        guard bound == 0, Darwin.listen(server, 16) == 0 else { throw POSIXError(.EADDRINUSE) }
        let acceptor = Thread { [weak self] in
            defer { close(server); close(lockFD) }
            while true {
                let connection = accept(server, nil, nil)
                if connection < 0 { if errno == EINTR { continue }; return }
                _ = fcntl(connection, F_SETFD, FD_CLOEXEC)
                var on: Int32 = 1
                setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                var timeout = timeval(tv_sec: 2, tv_usec: 0)
                guard setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0 else {
                    close(connection)
                    continue
                }
                Connection.widen(connection)
                guard let self else { close(connection); return }
                let handler = Thread { self.serve(Connection(fd: connection)) }
                handler.name = "plum.host.connection"
                handler.start()
            }
        }
        acceptor.name = "plum.host.accept"
        acceptor.start()
        listening = true
    }

    // MARK: Requests

    private func serve(_ connection: Connection) {
        var authenticated = false
        defer {
            if authenticated {
                lock.lock()
                connectedClients -= 1
                lock.unlock()
            }
        }
        while let line = connection.readLine() {
            // An agent's hook: `<tab id> <state> [message]`, kept for the app.
            guard let request = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                if let status = StatusMessage.parse(String(decoding: line, as: UTF8.self)) {
                    session(status.tab.uuidString)?.report(status.status, message: status.message)
                }
                return connection.close()
            }
            // Only Plum's GUI may control shells; agent hooks send plain status lines.
            if !authenticated {
                guard Self.isPlumProcess(connection.fd) else { return connection.close() }
                authenticated = true
                lock.lock()
                connectedClients += 1
                lock.unlock()
            }
            var noTimeout = timeval(tv_sec: 0, tv_usec: 0)
            guard setsockopt(connection.fd, SOL_SOCKET, SO_RCVTIMEO, &noTimeout, socklen_t(MemoryLayout<timeval>.size)) == 0 else {
                return connection.close()
            }
            lock.lock()
            lastActivity = Date()
            lock.unlock()
            let op = request["op"] as? String ?? ""
            let id = request["id"] as? String ?? ""
            switch op {
            case "open", "attach":
                // From here on the connection carries the terminal.
                return carry(connection, request: request, id: id, open: op == "open")
            case "resize":
                session(id)?.resize(cols: request.uint16("cols"), rows: request.uint16("rows"),
                                    width: request.uint16("width"), height: request.uint16("height"))
                connection.writeJSON(["ok": true])
            case "park":
                let length = request["length"] as? Int ?? 0
                guard let snapshot = connection.read(count: length) else { return connection.close() }
                session(id)?.park(snapshot: snapshot, received: request["received"] as? Int ?? 0)
                // The app's view of the agent's state, read or not: newer than the last hook's.
                session(id)?.report((request["status"] as? String).flatMap(AgentStatus.init(rawValue:)) ?? .idle,
                                    message: request["message"] as? String ?? "")
                connection.writeJSON(["ok": true])
            case "close":
                session(id)?.hangUp()
                connection.writeJSON(["ok": true])
            case "list":
                lock.lock()
                let list = sessions.values.sorted { $0.started < $1.started }.map {
                    ["id": $0.id, "workspace": $0.workspace, "cols": Int($0.size.cols), "rows": Int($0.size.rows)] as [String: Any]
                }
                lock.unlock()
                connection.writeJSON(["ok": true, "sessions": list])
            case "hello":
                connection.writeJSON(["ok": true, "version": Self.version])
            default:
                connection.writeJSON(["ok": false])
            }
        }
        connection.close()
    }

    fileprivate static func isPlumProcess(_ fd: Int32, legacy: (hash: String, pid: pid_t, version: UInt32)? = nil) -> Bool {
        if let legacy {
            var token = audit_token_t()
            var size = socklen_t(MemoryLayout<audit_token_t>.size)
            guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &size) == 0,
                  size == MemoryLayout<audit_token_t>.size,
                  pid_t(bitPattern: token.val.5) == legacy.pid,
                  token.val.7 == legacy.version else { return false }
            var hash = [UInt8](repeating: 0, count: 20)
            let result = hash.withUnsafeMutableBytes {
                csopsAuditToken(pid_t(bitPattern: token.val.5), 5, $0.baseAddress!, $0.count, &token)
            }
            return result == 0 && hash.map { String(format: "%02x", $0) }.joined() == legacy.hash
        }
        var peer: pid_t = 0
        var size = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &peer, &size) == 0,
              size == MemoryLayout<pid_t>.size else { return false }
        return sameCode(as: peer)
    }

    private static func sameCode(as pid: pid_t) -> Bool {
        guard let hash = ownCodeHash(), matchesCode(as: getpid(), hash: hash) else { return false }
        return matchesCode(as: pid, hash: hash)
    }

    static func ownCodeHash() -> String? {
        let flags = SecCSFlags(rawValue: 0)
        var owner: SecCode?
        var staticOwner: SecStaticCode?
        var information: CFDictionary?
        guard SecCodeCopySelf(flags, &owner) == errSecSuccess, let owner,
              SecCodeCopyStaticCode(owner, flags, &staticOwner) == errSecSuccess, let staticOwner,
              SecCodeCopySigningInformation(staticOwner, flags, &information) == errSecSuccess,
              let details = information as? [String: Any],
              let identity = details[kSecCodeInfoUnique as String] as? Data else { return nil }
        return identity.map { String(format: "%02x", $0) }.joined()
    }

    private static func matchesCode(as pid: pid_t, hash: String) -> Bool {
        let flags = SecCSFlags(rawValue: 0)
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString("cdhash H\"\(hash)\"" as CFString, flags, &requirement) == errSecSuccess,
              let requirement else { return false }
        let attributes = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
        var peer: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, flags, &peer) == errSecSuccess,
              let peer else { return false }
        return SecCodeCheckValidity(peer, flags, requirement) == errSecSuccess
    }

    private func session(_ id: String) -> HostSession? {
        lock.lock()
        defer { lock.unlock() }
        return sessions[id]
    }

    private func carry(_ connection: Connection, request: [String: Any], id: String, open: Bool) {
        var session = self.session(id)
        if session == nil, open {
            let environment = request["env"] as? [String: String] ?? [:]
            session = try? HostSession(
                id: id, workspace: request["workspace"] as? String ?? "",
                shell: request["shell"] as? String ?? "/bin/zsh", cwd: request["cwd"] as? String ?? NSHomeDirectory(),
                environment: environment, cols: request.uint16("cols"), rows: request.uint16("rows"),
                command: request["command"] as? String
            ) { [weak self] ended in
                guard let self else { return }
                lock.lock()
                if sessions[ended.id] === ended { sessions[ended.id] = nil }
                lastActivity = Date()
                lock.unlock()
            }
            if let session {
                lock.lock()
                sessions[id] = session
                lock.unlock()
            }
        }
        guard let session else {
            connection.writeJSON(["ok": false])
            return connection.close()
        }
        session.attach(connection)
    }
}

/// One terminal the host keeps: its pty, the program on it, and whoever is
/// attached to it.
private final class HostSession {
    let id: String
    let workspace: String
    let started = Date()
    private let master: Int32
    private let pid: pid_t
    /// Guards everything below. Output is written to the app while holding
    /// it, so bytes reach the app in the order the program wrote them.
    private let lock = NSLock()
    private var cols: UInt16
    private var rows: UInt16
    private var client: Connection?
    /// Bytes sent on the current connection since it attached, the screen
    /// it was sent first included.
    private var streamed = 0
    /// The latest output, for what was in flight when the app parked the
    /// terminal, or for a screen to start from if the app went away without
    /// parking (it crashed).
    private var tail = Tail(capacity: 512 * 1024)
    /// The terminal the host parses into while no app is attached.
    private var parked: GhosttyTerminal?
    /// The program has ended; nothing can attach any more.
    private var finished = false
    /// What its agent last reported through a hook, for an app that wasn't
    /// running to hear it.
    private var status: (state: AgentStatus, message: String) = (.idle, "")

    var size: (cols: UInt16, rows: UInt16) {
        lock.lock()
        defer { lock.unlock() }
        return (cols, rows)
    }

    init(id: String, workspace: String, shell: String, cwd: String, environment: [String: String],
         cols: UInt16, rows: UInt16, command: String?, ended: @escaping (HostSession) -> Void) throws {
        self.id = id
        self.workspace = workspace
        self.cols = max(cols, 1)
        self.rows = max(rows, 1)
        let shellName = "-" + (shell as NSString).lastPathComponent // leading "-" = login shell
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup(shellName), nil]
        let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var child: pid_t = 0
        let fd = plum_pty_spawn(shell, argv, envp, cwd, self.cols, self.rows, &child)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        master = fd
        pid = child

        let reader = Thread { [self] in
            // Batches go to the app in one write each: one wakeup of the app
            // per batch, not per kilobyte the pty hands over.
            TerminalIO.readOutput(from: master, batching: true) { bytes in
                output(bytes)
                return true
            }
            // The program ended: so does the app's tab.
            lock.lock()
            finished = true
            client?.shutdown()
            client = nil
            if let parked { ghostty_terminal_free(parked) }
            parked = nil
            lock.unlock()
            close(master)
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            ended(self)
        }
        reader.name = "plum.host.read"
        reader.qualityOfService = .userInteractive
        reader.start()

        if let command, !command.isEmpty { type(command + "\n") }
    }

    private func output(_ bytes: UnsafeRawBufferPointer) {
        lock.lock()
        defer { lock.unlock() }
        tail.append(bytes)
        streamed += bytes.count
        if let parked { ghostty_terminal_vt_write(parked, bytes.baseAddress!.assumingMemoryBound(to: UInt8.self), bytes.count) }
        if let client, !client.write(bytes) { detachLocked(client) }
    }

    /// Types `text` once the shell's line editor is reading, as the app
    /// does for a tab it starts itself.
    private func type(_ text: String) {
        let deadline = Date().addingTimeInterval(4)
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            while Date() < deadline {
                var attributes = termios()
                if tcgetattr(master, &attributes) == 0, attributes.c_lflag & tcflag_t(ICANON) == 0 { break }
                usleep(30_000)
            }
            writeInput(Data(text.utf8))
        }
    }

    private func writeInput(_ data: Data) {
        _ = data.withUnsafeBytes { TerminalIO.write(master, $0) }
    }

    /// Hands the terminal to `connection`: the answer line, then the parked
    /// screen if there is one, then output as it comes. Input read from the
    /// connection goes to the program until it closes.
    func attach(_ connection: Connection) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            connection.writeJSON(["ok": false])
            return connection.close()
        }
        if let previous = client { previous.shutdown() } // another app instance had it: this one takes over
        let screen = parked.map(Self.screen) ?? Data()
        if let parked { ghostty_terminal_free(parked) }
        parked = nil
        client = connection
        streamed = screen.count
        connection.writeJSON(["ok": true, "pid": Int(pid), "cols": Int(cols), "rows": Int(rows),
                              "status": status.state.rawValue, "message": status.message])
        _ = screen.withUnsafeBytes { connection.write($0) }
        lock.unlock()

        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 16 * 1024, alignment: 16)
        defer { buffer.deallocate() }
        while true {
            let n = read(connection.fd, buffer.baseAddress, buffer.count)
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { break }
            writeInput(Data(buffer[..<n]))
        }
        lock.lock()
        if client === connection { detachLocked(connection) }
        lock.unlock()
        connection.close()
    }

    /// The app went away without parking (it crashed, or was killed): start
    /// from the latest output kept, which is the best there is.
    private func detachLocked(_ connection: Connection) {
        guard client === connection else { return }
        client = nil
        connection.shutdown()
        if parked == nil {
            parked = makeTerminal()
            tail.withBytes { feed(parked, $0) }
        }
    }

    /// The app is quitting and hands over its screen: `received` is how many
    /// bytes of this connection it had parsed into it. What it hadn't read
    /// yet is still in `tail`.
    func park(snapshot: Data, received: Int) {
        lock.lock()
        defer { lock.unlock() }
        if let parked { ghostty_terminal_free(parked) }
        let terminal = makeTerminal()
        snapshot.withUnsafeBytes { feed(terminal, $0) }
        let missing = max(0, streamed - received)
        tail.withBytes { feed(terminal, UnsafeRawBufferPointer(rebasing: $0.suffix(missing))) }
        parked = terminal
    }

    func resize(cols: UInt16, rows: UInt16, width: UInt16, height: UInt16) {
        guard cols > 0, rows > 0 else { return }
        lock.lock()
        self.cols = cols
        self.rows = rows
        if let parked { ghostty_terminal_resize(parked, cols, rows, UInt32(width / max(cols, 1)), UInt32(height / max(rows, 1))) }
        lock.unlock()
        _ = plum_pty_resize(master, cols, rows, width, height)
    }

    func report(_ state: AgentStatus, message: String) {
        lock.lock()
        status = (state, message)
        lock.unlock()
    }

    /// Closing a tab ends its shell, and with it the programs it started.
    func hangUp() {
        kill(pid, SIGHUP)
    }

    private func makeTerminal() -> GhosttyTerminal? {
        var terminal: GhosttyTerminal?
        guard ghostty_terminal_new(nil, &terminal, cols, rows) == GHOSTTY_SUCCESS, let terminal else { return nil }
        // As the app sets up its own (TerminalSession.configure).
        var scrollback = 10_000_000
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, &scrollback)
        var kittyImageBytes: UInt64 = 0
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_STORAGE_LIMIT, &kittyImageBytes)
        var graphemes = GhosttyTerminalModeConfig(mode: ghostty_mode_new(2027, false), value: true)
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_MODE_DEFAULT, &graphemes)
        return terminal
    }

    private func feed(_ terminal: GhosttyTerminal?, _ bytes: UnsafeRawBufferPointer) {
        guard let terminal, let base = bytes.baseAddress, bytes.count > 0 else { return }
        ghostty_terminal_vt_write(terminal, base.assumingMemoryBound(to: UInt8.self), bytes.count)
    }

    /// The screen and its scrollback as VT sequences, with the modes,
    /// cursor and keyboard state that differ from a new terminal's. Not the
    /// palette: the app's colors are the app's.
    static func screen(_ terminal: GhosttyTerminal) -> Data {
        TerminalSession.formatVT(terminal)
    }
}

/// The most recent bytes, up to a capacity.
private struct Tail {
    private var bytes: [UInt8] = []
    private var start = 0
    let capacity: Int

    init(capacity: Int) { self.capacity = capacity }

    mutating func append(_ new: UnsafeRawBufferPointer) {
        if new.count >= capacity {
            bytes = Array(new.suffix(capacity))
            start = 0
            return
        }
        bytes.append(contentsOf: new)
        start += max(0, bytes.count - start - capacity)
        // Drop what fell off the front now and then, not on every append.
        if start > capacity { bytes.removeFirst(start); start = 0 }
    }

    func withBytes(_ body: (UnsafeRawBufferPointer) -> Void) {
        bytes[start...].withUnsafeBytes(body)
    }
}

/// A socket connection, read and written whole.
final class Connection {
    let fd: Int32
    private var closed = false

    init(fd: Int32) { self.fd = fd }

    /// A local socket's buffers start at 8 KB: output faster than that
    /// would stop the host at every few kilobytes, waiting for the app.
    static func widen(_ fd: Int32) {
        var size: Int32 = 256 * 1024
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Reads one line of JSON; nil once the other end has closed.
    func readJSON() -> [String: Any]? {
        readLine().flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    /// Reads one line, without its newline; nil once the other end has closed.
    func readLine() -> Data? {
        var line = Data()
        var byte: UInt8 = 0
        while true {
            let n = Darwin.read(fd, &byte, 1)
            if n < 0, errno == EINTR { continue }
            guard n == 1 else { return nil }
            if byte == 10 { break }
            line.append(byte)
            if line.count > 1 << 20 { return nil }
        }
        return line
    }

    func read(count: Int) -> Data? {
        guard (0...64 * 1024 * 1024).contains(count) else { return nil }
        var data = Data(count: count)
        var offset = 0
        let ok = data.withUnsafeMutableBytes { raw -> Bool in
            while offset < count {
                let n = Darwin.read(fd, raw.baseAddress! + offset, count - offset)
                if n > 0 { offset += n } else if n < 0, errno == EINTR { continue } else { return false }
            }
            return true
        }
        return ok ? data : nil
    }

    @discardableResult
    func writeJSON(_ object: [String: Any]) -> Bool {
        guard var line = try? JSONSerialization.data(withJSONObject: object) else { return false }
        line.append(10)
        return line.withUnsafeBytes { write($0) }
    }

    @discardableResult
    func write(_ bytes: UnsafeRawBufferPointer) -> Bool {
        var offset = 0
        while offset < bytes.count {
            let n = Darwin.write(fd, bytes.baseAddress! + offset, bytes.count - offset)
            if n > 0 { offset += n } else if n < 0, errno == EINTR { continue } else { return false }
        }
        return true
    }

    /// Wakes whoever reads it; the reading thread closes it.
    func shutdown() { Darwin.shutdown(fd, SHUT_RDWR) }

    func close() {
        guard !closed else { return }
        closed = true
        Darwin.close(fd)
    }
}

private extension [String: Any] {
    func uint16(_ key: String) -> UInt16 {
        UInt16(clamping: self[key] as? Int ?? 0)
    }
}

// MARK: - The app's side

/// The app's way to the terminal host: starts it when it isn't running,
/// and asks it for terminals.
public final class TerminalHostClient: @unchecked Sendable {
    public struct Session {
        public let id: UUID
        public let workspace: UUID
        public let cols: UInt16
        public let rows: UInt16
    }

    private let socketPath: String
    private let expectedVersion: Int
    private let trustedLegacy: (hash: String, pid: pid_t, version: UInt32)?
    /// One connection for requests; terminals get connections of their own.
    private var control: Connection?
    private var rejectedHost = false
    private let lock = NSLock()

    /// Connects to the host for `socketPath`, starting it from `executable`
    /// if none is listening. Nil if it can't be reached.
    public init?(socketPath: String, executable: String) {
        self.socketPath = socketPath
        expectedVersion = TerminalHost.version
        trustedLegacy = nil
        if hello() { return }
        if rejectedHost { return nil }
        Self.launch(executable: executable, socketPath: socketPath)
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if hello() { return }
            usleep(20_000)
        }
        return nil
    }

    /// Only reconnects to the known legacy host; never launches one.
    public init?(legacySocketPath: String, codeHash: String, pid: pid_t, pidVersion: UInt32) {
        socketPath = legacySocketPath
        expectedVersion = 1
        trustedLegacy = (codeHash, pid, pidVersion)
        guard hello() else { return nil }
    }

    private func hello() -> Bool {
        guard let reply = request(["op": "hello"]) else { return false }
        return reply["version"] as? Int == expectedVersion
    }

    /// Starts the host in a session of its own, so it outlives the app and
    /// no terminal's hangup reaches it.
    private static func launch(executable: String, socketPath: String) {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        for fd: Int32 in 0...2 { posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", fd == 0 ? O_RDONLY : O_WRONLY, 0) }
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup(executable), strdup("--terminal-host"), strdup(socketPath), nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        posix_spawn(&pid, executable, &actions, &attributes, argv, environ)
        posix_spawn_file_actions_destroy(&actions)
        posix_spawnattr_destroy(&attributes)
    }

    private func connect() -> Connection? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        Connection.widen(fd)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            socketPath.withCString { _ = strncpy(raw.baseAddress!.assumingMemoryBound(to: CChar.self), $0, raw.count - 1) }
        }
        let originalFlags = fcntl(fd, F_GETFL)
        guard originalFlags >= 0, fcntl(fd, F_SETFL, originalFlags | O_NONBLOCK) >= 0 else {
            Darwin.close(fd)
            return nil
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if connected != 0 {
            guard errno == EINPROGRESS else { Darwin.close(fd); return nil }
            var ready = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            var error: Int32 = 0
            var size = socklen_t(MemoryLayout<Int32>.size)
            guard poll(&ready, 1, 200) > 0,
                  getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0,
                  error == 0 else { Darwin.close(fd); return nil }
        }
        guard fcntl(fd, F_SETFL, originalFlags) >= 0 else { Darwin.close(fd); return nil }
        guard TerminalHost.isPlumProcess(fd, legacy: trustedLegacy) else {
            rejectedHost = true
            Darwin.close(fd)
            return nil
        }
        return Connection(fd: fd)
    }

    /// One request on the shared connection, and its answer.
    private func request(_ object: [String: Any], payload: Data? = nil) -> [String: Any]? {
        lock.lock()
        defer { lock.unlock() }
        for _ in 0..<2 { // once more on a fresh connection if the old one broke
            if control == nil { control = connect() }
            guard let control else { return nil }
            if control.writeJSON(object),
               payload.map({ data in data.withUnsafeBytes { control.write($0) } }) ?? true,
               let reply = control.readJSON() {
                return reply
            }
            control.close()
            self.control = nil
        }
        return nil
    }

    /// Starts a shell, or attaches if a terminal with this id is still
    /// running. The descriptor carries the terminal from then on.
    public func open(id: UUID, workspace: UUID, shell: String, cwd: String, environment: [String: String],
                     cols: UInt16, rows: UInt16, command: String?) -> Carried? {
        carry(["op": "open", "id": id.uuidString, "workspace": workspace.uuidString, "shell": shell, "cwd": cwd,
               "env": environment, "cols": Int(cols), "rows": Int(rows), "command": command ?? ""])
    }

    /// Attaches to a terminal still running; its screen comes first.
    public func attach(id: UUID) -> Carried? {
        carry(["op": "attach", "id": id.uuidString])
    }

    /// A terminal's connection, the shell's pid and the terminal's size.
    public struct Carried {
        public let fd: Int32
        public let pid: pid_t
        public let cols: UInt16
        public let rows: UInt16
        /// What the terminal's agent last reported, while the app was away too.
        public let status: AgentStatus
        public let message: String
    }

    private func carry(_ object: [String: Any]) -> Carried? {
        guard let connection = connect() else { return nil }
        guard connection.writeJSON(object), let reply = connection.readJSON(), reply["ok"] as? Bool == true else {
            connection.close()
            return nil
        }
        return Carried(fd: connection.fd, pid: pid_t(reply["pid"] as? Int ?? 0),
                       cols: UInt16(clamping: reply["cols"] as? Int ?? 80), rows: UInt16(clamping: reply["rows"] as? Int ?? 24),
                       status: (reply["status"] as? String).flatMap(AgentStatus.init(rawValue:)) ?? .idle,
                       message: reply["message"] as? String ?? "")
    }

    /// The terminals the host keeps, oldest first.
    public func list() -> [Session] {
        guard let reply = request(["op": "list"]), let list = reply["sessions"] as? [[String: Any]] else { return [] }
        return list.compactMap { item in
            guard let id = (item["id"] as? String).flatMap(UUID.init(uuidString:)),
                  let workspace = (item["workspace"] as? String).flatMap(UUID.init(uuidString:)) else { return nil }
            return Session(id: id, workspace: workspace,
                           cols: UInt16(clamping: item["cols"] as? Int ?? 80), rows: UInt16(clamping: item["rows"] as? Int ?? 24))
        }
    }

    public func resize(_ id: UUID, cols: UInt16, rows: UInt16, width: UInt16, height: UInt16) {
        _ = request(["op": "resize", "id": id.uuidString, "cols": Int(cols), "rows": Int(rows), "width": Int(width), "height": Int(height)])
    }

    /// Hands a terminal's screen, and its agent's state as the app saw it,
    /// to the host as the app quits.
    public func park(_ id: UUID, snapshot: Data, received: Int, status: AgentStatus = .idle) {
        _ = request(["op": "park", "id": id.uuidString, "received": received, "length": snapshot.count,
                     "status": status.rawValue], payload: snapshot)
    }

    /// Ends the terminal's shell.
    public func close(_ id: UUID) {
        _ = request(["op": "close", "id": id.uuidString])
    }
}
