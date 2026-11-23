import CPty
import AppKit
import Foundation
import GhosttyVt

/// What a program running in a terminal told us about itself.
public enum AgentStatus: String, Codable, Sendable {
    /// `monitoring`: the agent's turn is over, but work it started in the
    /// background (a command, a monitor, a scheduled wakeup) will bring it
    /// back. Nothing for the user to do; not done either.
    case idle, monitoring, working, waiting, done

    /// Which state wins when one workspace has several tabs.
    public var urgency: Int {
        switch self {
        case .idle: 0
        case .monitoring: 1
        case .working: 2
        case .done: 3
        case .waiting: 4
        }
    }
}

public enum TerminalSignal {
    /// A program reported its state in-band (OSC 7501).
    case status(AgentStatus, message: String)
    /// A program asked for a desktop notification (OSC 9 / OSC 777).
    case notification(title: String, body: String)
    case bell
}

public struct TerminalTheme {
    /// What new terminals get, and what every terminal is switched to when
    /// the accent changes.
    nonisolated(unsafe) public static var current = TerminalTheme()

    public static func dark(cursor: (UInt8, UInt8, UInt8)) -> TerminalTheme {
        var theme = TerminalTheme()
        theme.cursor = cursor
        theme.selection = mix(cursor, theme.background, 0.3)
        return theme
    }

    static func mix(_ a: (UInt8, UInt8, UInt8), _ b: (UInt8, UInt8, UInt8), _ amount: Double) -> (UInt8, UInt8, UInt8) {
        func channel(_ x: UInt8, _ y: UInt8) -> UInt8 { UInt8((Double(x) * amount + Double(y) * (1 - amount)).rounded()) }
        return (channel(a.0, b.0), channel(a.1, b.1), channel(a.2, b.2))
    }

    public var foreground: (UInt8, UInt8, UInt8) = (0xDC, 0xDC, 0xE2)
    public var background: (UInt8, UInt8, UInt8) = (0x1A, 0x1A, 0x1D)
    public var cursor: (UInt8, UInt8, UInt8) = (0xC5, 0x8A, 0xF9)
    public var selection: (UInt8, UInt8, UInt8) = (0x45, 0x39, 0x5A)
    /// The 16 ANSI colors; the other 240 palette entries keep the library defaults.
    public var ansi: [(UInt8, UInt8, UInt8)] = [
        (0x2A, 0x2A, 0x2F), (0xFF, 0x8E, 0x8E), (0x7B, 0xD8, 0x8F), (0xF5, 0xB4, 0x53),
        (0x7C, 0xB7, 0xFF), (0xC5, 0x8A, 0xF9), (0x7D, 0xD3, 0xFC), (0xDC, 0xDC, 0xE2),
        (0x6E, 0x6E, 0x78), (0xFF, 0xAA, 0xAA), (0x9B, 0xE3, 0xAA), (0xF8, 0xC7, 0x7E),
        (0xA3, 0xCC, 0xFF), (0xD6, 0xAA, 0xFC), (0xA5, 0xE1, 0xFD), (0xFF, 0xFF, 0xFF),
    ]
    public init() {}
}

/// One terminal: a pty, the program on it, and the VT state it draws into.
///
/// Threads: the pty is read and parsed on a thread of its own and written on
/// `writeQueue`. Everything public is called from the main thread.
/// `termLock` guards the terminal handle and `renderLock` guards the render
/// state; when both are needed, take `termLock` first.
public final class TerminalSession {
    public let id: UUID
    public private(set) var cols: UInt16
    public private(set) var rows: UInt16
    public private(set) var title = ""
    public private(set) var isRunning = false

    /// New output arrived and the screen should be redrawn. Main thread.
    public var onDirty: (() -> Void)?
    public var onTitle: ((String) -> Void)?
    public var onSignal: ((TerminalSignal) -> Void)?
    public var onExit: (() -> Void)?

    let termLock = NSLock()
    let renderLock = NSLock()
    private(set) var terminal: GhosttyTerminal
    private(set) var renderState: GhosttyRenderState
    private let keyEncoder: GhosttyKeyEncoder
    private let keyEvent: GhosttyKeyEvent
    // Made when first needed: most terminals never see a mouse or a search.
    private var mouseEncoder: GhosttyMouseEncoder?
    private var mouseEvent: GhosttyMouseEvent?
    private var search: GhosttySearch?

    /// The pty's master side. The reader thread and pending writes hold it
    /// too, so its descriptor is closed only once none of them can use it.
    private final class Pty {
        let fd: Int32
        /// The other end's device, for waking the reader (see deinit).
        let slavePath: String?
        init(fd: Int32, slavePath: String?) {
            self.fd = fd
            self.slavePath = slavePath
        }

        deinit { close(fd) }
    }

    /// A terminal the terminal host keeps (see `TerminalHost`): `pty` is a
    /// connection to the host, and resizing and ending go through it.
    public struct Remote {
        public let resize: (_ cols: UInt16, _ rows: UInt16, _ width: UInt16, _ height: UInt16) -> Void
        public let end: () -> Void
        public init(resize: @escaping (UInt16, UInt16, UInt16, UInt16) -> Void, end: @escaping () -> Void) {
            self.resize = resize
            self.end = end
        }
    }

    private var remote: Remote?
    public var isRemote: Bool { remote != nil }
    private var pty: Pty?
    private let writeQueue: DispatchQueue
    private var pid: pid_t = 0
    private var exitSource: DispatchSourceProcess?
    /// Output read from the pty so far, in bytes. Guarded by `termLock`: the reader
    /// thread adds to it, the main thread reads it.
    private var received = 0
    public var bytesReceived: Int {
        termLock.lock()
        defer { termLock.unlock() }
        return received
    }

    // Guarded by termLock.
    private var held = false
    private var holdStartedAt: UInt64 = 0
    private var holdCapturedAt: UInt64 = 0
    private var dirtyPosted = false
    private var cellWidthPx: UInt32 = 8
    private var cellHeightPx: UInt32 = 16

    /// The colors it draws with: dark or light, and the accent's cursor.
    public private(set) var theme: TerminalTheme

    public init(id: UUID = UUID(), cols: UInt16 = 80, rows: UInt16 = 24, theme: TerminalTheme = .current) {
        self.id = id
        self.theme = theme
        self.cols = cols
        self.rows = rows
        writeQueue = DispatchQueue(label: "plum.terminal.write", qos: .userInteractive)

        var term: GhosttyTerminal?
        var render: GhosttyRenderState?
        var encoder: GhosttyKeyEncoder?
        var event: GhosttyKeyEvent?
        guard ghostty_terminal_new(nil, &term, cols, rows) == GHOSTTY_SUCCESS, let term,
              ghostty_render_state_new(nil, &render) == GHOSTTY_SUCCESS, let render,
              ghostty_key_encoder_new(nil, &encoder) == GHOSTTY_SUCCESS, let encoder,
              ghostty_key_event_new(nil, &event) == GHOSTTY_SUCCESS, let event
        else { fatalError("libghostty-vt: out of memory creating a terminal") }
        terminal = term
        renderState = render
        keyEncoder = encoder
        keyEvent = event

        configure(theme: theme)
    }

    deinit {
        ghostty_search_free(search)
        ghostty_mouse_encoder_free(mouseEncoder)
        ghostty_mouse_event_free(mouseEvent)
        exitSource?.cancel()
        // The reader thread is asleep in read(2), which nothing else can
        // interrupt. A byte from the other end wakes it; it then finds the
        // session gone and ends, letting go of the pty. A host's terminal
        // is only let go of, not ended: the app is quitting, and the host
        // keeps it running.
        if remote != nil, let pty { shutdown(pty.fd, SHUT_RDWR) }
        if remote == nil, let path = pty?.slavePath {
            let slave = open(path, O_WRONLY | O_NOCTTY | O_NONBLOCK)
            if slave >= 0 {
                _ = Darwin.write(slave, "\n", 1)
                close(slave)
            }
        }
        if remote == nil, pid > 0 {
            kill(pid, SIGHUP)
            // Nobody is left to collect it later; don't leave a zombie.
            let child = pid
            DispatchQueue.global(qos: .utility).async {
                var status: Int32 = 0
                waitpid(child, &status, 0)
            }
        }
        ghostty_key_event_free(keyEvent)
        ghostty_key_encoder_free(keyEncoder)
        ghostty_render_state_free(renderState)
        ghostty_terminal_free(terminal)
    }

    // MARK: Setup

    private func set(_ option: GhosttyTerminalOption, _ value: UnsafeRawPointer?) {
        ghostty_terminal_set(terminal, option, value)
    }

    private func configure(theme: TerminalTheme) {
        set(GHOSTTY_TERMINAL_OPT_USERDATA, Unmanaged.passUnretained(self).toOpaque())

        // Ghostty's own default; the library default keeps only about one page.
        var scrollback = 10_000_000
        set(GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, &scrollback)

        "xterm-256color".withGhosttyString { set(GHOSTTY_TERMINAL_OPT_TERMINFO_NAME, $0) }

        // Treat a whole grapheme cluster (family emoji, flags, a heart with
        // its variation selector) as one cell, the way Ghostty does.
        var graphemes = GhosttyTerminalModeConfig(mode: ghostty_mode_new(2027, false), value: true)
        set(GHOSTTY_TERMINAL_OPT_MODE_DEFAULT, &graphemes)
        applyTheme(theme)

        let writePty: GhosttyTerminalWritePtyFn = { _, userdata, data, len in
            guard let userdata, let data, len > 0 else { return }
            TerminalSession.from(userdata).write(Data(bytes: data, count: len))
        }
        set(GHOSTTY_TERMINAL_OPT_WRITE_PTY, unsafeBitCast(writePty, to: UnsafeRawPointer.self))

        let bell: GhosttyTerminalBellFn = { _, userdata in
            guard let userdata else { return }
            TerminalSession.from(userdata).emit(.bell)
        }
        set(GHOSTTY_TERMINAL_OPT_BELL, unsafeBitCast(bell, to: UnsafeRawPointer.self))

        let titleChanged: GhosttyTerminalTitleChangedFn = { terminal, userdata in
            guard let userdata else { return }
            var value = GhosttyString()
            guard ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_TITLE, &value) == GHOSTTY_SUCCESS else { return }
            let title = sanitizeForDisplay(String(ghostty: value), limit: 200)
            let session = TerminalSession.from(userdata)
            DispatchQueue.main.async { [weak session] in session?.titleArrived(title) }
        }
        set(GHOSTTY_TERMINAL_OPT_TITLE_CHANGED, unsafeBitCast(titleChanged, to: UnsafeRawPointer.self))

        let notification: GhosttyTerminalDesktopNotificationFn = { _, userdata, note in
            guard let userdata, let note else { return }
            TerminalSession.from(userdata).emit(.notification(
                title: sanitizeForDisplay(String(ghostty: note.pointee.title), limit: 120),
                body: sanitizeForDisplay(String(ghostty: note.pointee.body), limit: 400)))
        }
        set(GHOSTTY_TERMINAL_OPT_DESKTOP_NOTIFICATION, unsafeBitCast(notification, to: UnsafeRawPointer.self))

        let programStatus: GhosttyTerminalProgramStatusFn = { _, userdata, report in
            guard let userdata, let report else { return }
            // Only the root record drives the tab's status; sub-records
            // (e.g. per-region deploys) would need a list UI we don't have.
            guard report.pointee.id.len == 0 else { return }
            let status: AgentStatus = switch report.pointee.state {
            case GHOSTTY_PROGRAM_STATUS_STATE_WORKING: .working
            case GHOSTTY_PROGRAM_STATUS_STATE_BLOCKED: .waiting
            case GHOSTTY_PROGRAM_STATUS_STATE_DONE, GHOSTTY_PROGRAM_STATUS_STATE_ERROR: .done
            default: .idle
            }
            TerminalSession.from(userdata).emit(.status(
                status, message: sanitizeForDisplay(String(ghostty: report.pointee.message), limit: 200)))
        }
        set(GHOSTTY_TERMINAL_OPT_PROGRAM_STATUS, unsafeBitCast(programStatus, to: UnsafeRawPointer.self))

        let renderHold: GhosttyTerminalRenderHoldFn = { terminal, userdata, held in
            guard let userdata else { return }
            // Runs inside a terminal call, so termLock is already held.
            let session = TerminalSession.from(userdata)
            if held {
                // The terminal holds exactly the frame the program wants left
                // on screen; capture it before anything newer is parsed. Not
                // at every hold: a program that wraps each repaint starts
                // thousands a second, and copying the screen for each was most
                // of the reading thread's work. The screen shows one frame per
                // refresh at most, so one capture per refresh is enough; until
                // the next, the last complete frame stays.
                let now = DispatchTime.now().uptimeNanoseconds
                if now &- session.holdCapturedAt >= 8_000_000 {
                    session.renderLock.lock()
                    ghostty_render_state_update(session.renderState, terminal)
                    session.renderLock.unlock()
                    session.holdCapturedAt = now
                }
                session.holdStartedAt = now
            }
            session.held = held
        }
        set(GHOSTTY_TERMINAL_OPT_RENDER_HOLD, unsafeBitCast(renderHold, to: UnsafeRawPointer.self))

        let size: GhosttyTerminalSizeFn = { _, userdata, out in
            guard let userdata, let out else { return false }
            let session = TerminalSession.from(userdata)
            out.pointee = GhosttySizeReportSize(
                rows: session.rows, columns: session.cols,
                cell_width: session.cellWidthPx, cell_height: session.cellHeightPx)
            return true
        }
        set(GHOSTTY_TERMINAL_OPT_SIZE, unsafeBitCast(size, to: UnsafeRawPointer.self))

        // OSC 52 and the like: vim's "+y, tmux, a program over ssh copying to
        // the Mac's clipboard. Only text is taken; reading the clipboard
        // back is never offered.
        let clipboardWrite: GhosttyTerminalClipboardWriteFn = { _, _, request in
            guard let request else { return }
            var reply = GhosttyClipboardWriteReply(
                size: MemoryLayout<GhosttyClipboardWriteReply>.size, result: GHOSTTY_CLIPBOARD_WRITE_RESULT_UNSUPPORTED, remember: false)
            let write = request.pointee
            let contents = (0..<write.contents_len).map { write.contents[$0] }
            if write.location == GHOSTTY_CLIPBOARD_LOCATION_STANDARD,
               let text = contents.first(where: { String(ghostty: $0.mime).hasPrefix("text/plain") }).map({ String(ghostty: $0.data) }) {
                DispatchQueue.main.async { TerminalSession.copyToClipboard(text) }
                reply.result = GHOSTTY_CLIPBOARD_WRITE_RESULT_SUCCESS
            }
            write.reply(request, &reply)
        }
        set(GHOSTTY_TERMINAL_OPT_CLIPBOARD_WRITE, unsafeBitCast(clipboardWrite, to: UnsafeRawPointer.self))

        let colorScheme: GhosttyTerminalColorSchemeFn = { _, _, out in
            out?.pointee = GHOSTTY_COLOR_SCHEME_DARK
            return true
        }
        set(GHOSTTY_TERMINAL_OPT_COLOR_SCHEME, unsafeBitCast(colorScheme, to: UnsafeRawPointer.self))
    }

    public func applyTheme(_ theme: TerminalTheme) {
        termLock.lock()
        defer { termLock.unlock() }
        self.theme = theme
        var fg = GhosttyColorRgb(r: theme.foreground.0, g: theme.foreground.1, b: theme.foreground.2)
        var bg = GhosttyColorRgb(r: theme.background.0, g: theme.background.1, b: theme.background.2)
        var cursor = GhosttyColorRgb(r: theme.cursor.0, g: theme.cursor.1, b: theme.cursor.2)
        set(GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, &fg)
        set(GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, &bg)
        set(GHOSTTY_TERMINAL_OPT_COLOR_CURSOR, &cursor)

        var palette = [GhosttyColorRgb](repeating: GhosttyColorRgb(), count: 256)
        if ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_COLOR_PALETTE_DEFAULT, &palette) == GHOSTTY_SUCCESS {
            for (i, c) in theme.ansi.prefix(16).enumerated() {
                palette[i] = GhosttyColorRgb(r: c.0, g: c.1, b: c.2)
            }
            set(GHOSTTY_TERMINAL_OPT_COLOR_PALETTE, &palette)
        }
    }

    // Main thread.
    private var pendingTitle: String?
    private var titleScheduled = false
    private var titleShownAt: UInt64 = 0

    /// Shows a new title, at most four a second. Agents animate a spinner in
    /// their title while they work; each new title redraws the tab bar, and
    /// nobody reads a label that changes ten times a second. The latest one
    /// is always shown, and the first after a quiet spell right away. Main thread.
    private func titleArrived(_ newTitle: String) {
        pendingTitle = newTitle
        guard !titleScheduled else { return }
        titleScheduled = true
        let since = Double(DispatchTime.now().uptimeNanoseconds - titleShownAt) / 1e9
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, 0.25 - since)) { [weak self] in
            guard let self, let newTitle = pendingTitle else { return }
            titleScheduled = false
            pendingTitle = nil
            titleShownAt = DispatchTime.now().uptimeNanoseconds
            title = newTitle
            onTitle?(newTitle)
        }
    }

    private static func from(_ userdata: UnsafeMutableRawPointer) -> TerminalSession {
        Unmanaged<TerminalSession>.fromOpaque(userdata).takeUnretainedValue()
    }

    private func emit(_ signal: TerminalSignal) {
        DispatchQueue.main.async { [weak self] in self?.onSignal?(signal) }
    }

    // MARK: Process

    /// Starts `shell` as a login shell in `cwd`. `environment` is the complete
    /// environment of the child.
    public func start(shell: String, cwd: String, environment: [String: String]) throws {
        precondition(pty == nil, "session already started")
        let shellName = "-" + (shell as NSString).lastPathComponent // leading "-" = login shell
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup(shellName), nil]
        let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }

        var child: pid_t = 0
        let fd = plum_pty_spawn(shell, argv, envp, cwd, cols, rows, &child)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let pty = Pty(fd: fd, slavePath: ptsname(fd).map { String(cString: $0) })
        self.pty = pty
        pid = child
        isRunning = true
        startReading(pty)

        // Collect the exit status when the shell ends, or it stays a zombie
        // for as long as the app runs.
        let exit = DispatchSource.makeProcessSource(identifier: child, eventMask: .exit, queue: .global(qos: .utility))
        exit.setEventHandler { [weak self, weak exit] in
            var status: Int32 = 0
            waitpid(child, &status, 0)
            exit?.cancel()
            DispatchQueue.main.async { self?.pid = 0 }
        }
        exitSource = exit
        exit.resume()
    }

    /// Takes over a terminal the host keeps. `fd` is the connection the host
    /// answered on: the terminal's screen arrives first, then its output.
    public func attach(fd: Int32, pid: pid_t, remote: Remote) {
        precondition(pty == nil, "session already started")
        let pty = Pty(fd: fd, slavePath: nil)
        self.pty = pty
        self.pid = pid
        self.remote = remote
        isRunning = true
        startReading(pty)
    }

    private func startReading(_ pty: Pty) {
        // Output is read on a thread of its own (TerminalIO.readOutput: why
        // it doesn't sleep in a blocking read). The thread has its own buffer:
        // the session may go away while it reads.
        let reader = Thread { [weak self] in
            TerminalIO.readOutput(from: pty.fd, batching: false) { bytes in
                guard let self else { return false } // gone; deinit woke the reader
                // Parsed here, between reads. Handing it to another thread
                // instead sped up output that is slow to parse (TUI redraws,
                // 1.4x) but slowed the rest (plain text 0.7x) and cost more
                // CPU per byte everywhere (1.1-2.4x): the wrong trade with
                // many sessions running at the modest rates agents write.
                self.consume(bytes)
                return true
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                isRunning = false
                onExit?()
            }
        }
        reader.name = "plum.terminal.read"
        reader.qualityOfService = .userInteractive
        reader.start()
    }

    /// The screen and its scrollback as VT sequences that recreate them in
    /// another terminal, with how many bytes of output it has read: what
    /// the terminal host needs to keep the screen once the app quits.
    public func snapshot() -> (screen: Data, received: Int) {
        termLock.lock()
        defer { termLock.unlock() }
        return (Self.formatVT(terminal), received)
    }

    /// `terminal`'s screen and scrollback as VT sequences, with the modes,
    /// cursor and keyboard state that differ from a new terminal's. Not the
    /// palette: the colors are the app's, not the screen's.
    static func formatVT(_ terminal: GhosttyTerminal) -> Data {
        var formatter: GhosttyFormatter?
        guard ghostty_formatter_terminal_new(nil, &formatter, terminal) == GHOSTTY_SUCCESS, let formatter else { return Data() }
        defer { ghostty_formatter_free(formatter) }
        var emit = GHOSTTY_FORMATTER_FORMAT_VT
        ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_EMIT, &emit)
        var extras = GhosttyFormatterExtras(GHOSTTY_FORMATTER_EXTRAS_ALL) & ~GhosttyFormatterExtras(GHOSTTY_FORMATTER_EXTRA_PALETTE)
        ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_EXTRAS, &extras)
        var bytes: UnsafeMutablePointer<UInt8>?
        var length = 0
        guard ghostty_formatter_format_alloc(formatter, nil, &bytes, &length) == GHOSTTY_SUCCESS, let bytes else { return Data() }
        defer { ghostty_free(nil, bytes, length) }
        var screen = Data(bytes: bytes, count: length)
        // The title a program gave its window isn't part of the screen; an
        // agent's names its conversation, so it comes along too.
        var title = GhosttyString()
        if ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_TITLE, &title) == GHOSTTY_SUCCESS {
            let text = String(ghostty: title).filter { $0 != "\u{1b}" && $0 != "\u{7}" }
            if !text.isEmpty { screen.append(contentsOf: Array("\u{1b}]2;\(text)\u{1b}\\".utf8)) }
        }
        return screen
    }

    /// Parses output read from the pty. Reader thread.
    private func consume(_ bytes: UnsafeRawBufferPointer) {
        termLock.lock()
        received += bytes.count
        ghostty_terminal_vt_write(terminal, bytes.baseAddress!.assumingMemoryBound(to: UInt8.self), bytes.count)
        let post = !dirtyPosted
        dirtyPosted = true
        termLock.unlock()
        if post { DispatchQueue.main.async { [weak self] in self?.onDirty?() } }
    }

    /// Queues bytes for the program. Safe from any thread; order is kept.
    public func write(_ data: Data) {
        guard !data.isEmpty, let pty else { return }
        writeQueue.async {
            // A blocking write: a program that isn't reading its input holds
            // the rest back, in order, while its output keeps being read on
            // the reader thread. Once the program is gone, writes fail and the
            // rest is dropped.
            _ = data.withUnsafeBytes { TerminalIO.write(pty.fd, $0) }
        }
    }

    public func write(_ text: String) { write(Data(text.utf8)) }

    /// Types `text` once the shell is at its prompt, reading input.
    /// Typing earlier works too, but the tty echoes the text above the prompt
    /// before the shell is ready to show it properly.
    public func writeWhenReady(_ text: String) {
        guard let pty, remote == nil else { return write(text) }
        let deadline = DispatchTime.now().uptimeNanoseconds + 4_000_000_000
        func check() {
            writeQueue.asyncAfter(deadline: .now() + 0.03) { [weak self] in
                guard let self else { return }
                // A shell's line editor switches the tty out of canonical
                // mode when it starts reading; that is the moment to type.
                var attributes = termios()
                let editing = tcgetattr(pty.fd, &attributes) == 0 && attributes.c_lflag & tcflag_t(ICANON) == 0
                if editing || DispatchTime.now().uptimeNanoseconds > deadline {
                    write(text)
                } else {
                    check()
                }
            }
        }
        check()
    }

    public func terminate() {
        if let remote { return remote.end() }
        if pid > 0 { kill(pid, SIGHUP) }
    }

    /// The program in the foreground (an agent, an editor, a build), or nil
    /// when the shell is at its prompt. Closing the tab would end it.
    /// TCP ports that programs started in this terminal listen on.
    public func listeningPorts() -> [UInt16] {
        pid > 0 ? ListeningPorts.under(pid) : []
    }

    public func foregroundProgram() -> String? {
        guard pid > 0 else { return nil }
        // The shell's terminal's foreground group, read from the process:
        // a terminal the host keeps has no pty here to ask.
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var query: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&query, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let group = info.kp_eproc.e_tpgid
        guard group > 0, group != pid else { return nil }
        return Self.programName(group) ?? String(localized: "알 수 없는 프로그램")
    }

    /// What a process runs. Claude Code's own installer runs it as
    /// `…/claude/versions/2.1.328`, a file named for its version: then the
    /// folder above `versions` names it.
    static func programName(_ pid: pid_t) -> String? {
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        if proc_pidpath(pid, &path, UInt32(path.count)) > 0 {
            let parts = String(cString: path).split(separator: "/")
            if parts.count >= 3, parts[parts.count - 2] == "versions" { return String(parts[parts.count - 3]) }
        }
        var name = [CChar](repeating: 0, count: 64)
        return proc_name(pid, &name, UInt32(name.count)) > 0 ? String(cString: name) : nil
    }

    // MARK: Size and scrolling

    public func resize(cols: UInt16, rows: UInt16, cellWidthPx: UInt32, cellHeightPx: UInt32) {
        guard cols > 0, rows > 0 else { return }
        termLock.lock()
        let changed = cols != self.cols || rows != self.rows
            || cellWidthPx != self.cellWidthPx || cellHeightPx != self.cellHeightPx
        self.cols = cols
        self.rows = rows
        self.cellWidthPx = cellWidthPx
        self.cellHeightPx = cellHeightPx
        if changed { ghostty_terminal_resize(terminal, cols, rows, cellWidthPx, cellHeightPx) }
        termLock.unlock()
        guard changed, let pty else { return }
        let clamp = { (v: UInt32) in UInt16(min(v, UInt32(UInt16.max))) }
        let (width, height) = (clamp(UInt32(cols) * cellWidthPx), clamp(UInt32(rows) * cellHeightPx))
        if let remote { return remote.resize(cols, rows, width, height) }
        _ = plum_pty_resize(pty.fd, cols, rows, width, height)
    }

    public func scroll(byRows delta: Int) {
        guard delta != 0 else { return }
        var behavior = GhosttyTerminalScrollViewport()
        behavior.tag = GHOSTTY_TERMINAL_SCROLL_VIEWPORT_DELTA
        behavior.value.delta = delta
        withTerminal { _ = ghostty_terminal_scroll_viewport($0, behavior) }
    }

    public func scrollToBottom() {
        var behavior = GhosttyTerminalScrollViewport()
        behavior.tag = GHOSTTY_TERMINAL_SCROLL_VIEWPORT_BOTTOM
        withTerminal { _ = ghostty_terminal_scroll_viewport($0, behavior) }
    }

    /// Runs `body` with exclusive access to the terminal.
    @discardableResult
    func withTerminal<T>(_ body: (GhosttyTerminal) -> T) -> T {
        termLock.lock()
        defer { termLock.unlock() }
        return body(terminal)
    }

    // MARK: Rendering

    /// Brings the render state up to date and runs `body` on it. Main thread.
    func withFrame<T>(_ body: (GhosttyRenderState) -> T) -> T {
        termLock.lock()
        dirtyPosted = false
        if held, DispatchTime.now().uptimeNanoseconds - holdStartedAt >= 1_000_000_000 {
            // A program that never releases its hold would freeze the screen.
            var mode = GhosttyTerminalModeConfig(mode: ghostty_mode_new(2026, false), value: false)
            ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_MODE, &mode)
            held = false
        }
        let update = !held
        renderLock.lock()
        if update { ghostty_render_state_begin_update(renderState, terminal) }
        termLock.unlock()
        if update { ghostty_render_state_end_update(renderState) }
        defer { renderLock.unlock() }
        return body(renderState)
    }

    // MARK: Input

    /// Where programs' clipboard writes go. Scripted checks swap it out so
    /// the user's clipboard is left alone.
    public static var copyToClipboard: (String) -> Void = { text in
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// ⌥ is Meta (Esc before the key) rather than macOS's way to type
    /// symbols. The same for every terminal: a setting.
    public static var optionAsMeta = false

    public struct Key {
        public var key: GhosttyKey
        public var action: GhosttyKeyAction = GHOSTTY_KEY_ACTION_PRESS
        public var mods: GhosttyMods = 0
        public var consumedMods: GhosttyMods = 0
        public var text: String?
        public var unshiftedCodepoint: UInt32 = 0
        public var composing = false
        public init(key: GhosttyKey) { self.key = key }
    }

    /// Encodes a key for the terminal's current modes and sends it.
    /// Returns false if the key produces nothing (e.g. a lone modifier).
    @discardableResult
    public func send(_ key: Key) -> Bool {
        ghostty_key_event_set_action(keyEvent, key.action)
        ghostty_key_event_set_key(keyEvent, key.key)
        ghostty_key_event_set_mods(keyEvent, key.mods)
        ghostty_key_event_set_consumed_mods(keyEvent, key.consumedMods)
        ghostty_key_event_set_composing(keyEvent, key.composing)
        ghostty_key_event_set_unshifted_codepoint(keyEvent, key.unshiftedCodepoint)

        withTerminal { _ = ghostty_key_encoder_set_from_terminal(keyEncoder, $0) }
        var optionAsAlt = Self.optionAsMeta ? GHOSTTY_OPTION_AS_ALT_TRUE : GHOSTTY_OPTION_AS_ALT_FALSE
        ghostty_key_encoder_set(keyEncoder, GHOSTTY_KEY_ENCODER_OPT_MACOS_OPTION_AS_ALT, &optionAsAlt)

        // The event borrows the text, so encode while the bytes are alive.
        var utf8 = Array((key.text ?? "").utf8)
        var out = [UInt8](repeating: 0, count: 256)
        var written = 0
        let result = utf8.withUnsafeMutableBufferPointer { text -> GhosttyResult in
            ghostty_key_event_set_utf8(keyEvent, GhosttyString(ptr: text.baseAddress, len: key.text == nil ? 0 : text.count))
            var r = ghostty_key_encoder_encode(keyEncoder, keyEvent, &out, out.count, &written)
            if r == GHOSTTY_OUT_OF_SPACE {
                out = [UInt8](repeating: 0, count: written)
                r = ghostty_key_encoder_encode(keyEncoder, keyEvent, &out, out.count, &written)
            }
            return r
        }
        ghostty_key_event_set_utf8(keyEvent, GhosttyString(ptr: nil, len: 0))
        guard result == GHOSTTY_SUCCESS, written > 0 else { return false }
        write(Data(out[0..<written]))
        return true
    }

    public enum PasteResult { case pasted, nothing, needsConfirmation }

    /// Pastes text the way the running program expects (bracketed or not).
    /// Text that could run commands is refused unless `allowUnsafe` is set.
    public func paste(_ text: String, allowUnsafe: Bool = false) -> PasteResult {
        final class Source { let bytes: [UInt8]; init(_ s: String) { bytes = Array(s.utf8) } }
        let source = Source(text)
        let mime = Array("text/plain".utf8)

        let reader: @convention(c) (UnsafeMutableRawPointer?, GhosttyString, GhosttyWriter) -> Bool = { userdata, _, writer in
            guard let userdata, let write = writer.write else { return false }
            let source = Unmanaged<Source>.fromOpaque(userdata).takeUnretainedValue()
            return source.bytes.withUnsafeBufferPointer { write(writer.userdata, $0.baseAddress, $0.count) }
        }

        return mime.withUnsafeBufferPointer { mimeBytes in
            var mimes = [GhosttyString(ptr: mimeBytes.baseAddress, len: mimeBytes.count)]
            return mimes.withUnsafeMutableBufferPointer { mimeList in
                var paste = GhosttyPaste()
                paste.size = MemoryLayout<GhosttyPaste>.size
                paste.location = GHOSTTY_CLIPBOARD_LOCATION_STANDARD
                paste.source = GHOSTTY_PASTE_SOURCE_CLIPBOARD
                paste.mimes = UnsafePointer(mimeList.baseAddress)
                paste.mimes_len = 1
                paste.reader = GhosttyMimeReader(read: reader, userdata: Unmanaged.passUnretained(source).toOpaque())
                paste.allow_unsafe = allowUnsafe
                var pasted = false
                let result = withTerminal { ghostty_terminal_paste($0, &paste, &pasted) }
                if result == GHOSTTY_REJECTED { return .needsConfirmation }
                return result == GHOSTTY_SUCCESS && pasted ? .pasted : .nothing
            }
        }
    }

    // MARK: Selection and text

    /// Selects from one viewport cell to another. Both are (column, row).
    public func select(from: (Int, Int), to: (Int, Int)) {
        withTerminal { terminal in
            guard let a = gridRef(terminal, viewport: from), let b = gridRef(terminal, viewport: to) else { return }
            var selection = GhosttySelection(start: a, end: b, rectangle: false)
            ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SELECTION, &selection)
        }
    }

    public enum SelectionUnit { case word, line }

    public func select(_ unit: SelectionUnit, at point: (Int, Int)) {
        withTerminal { terminal in
            guard let ref = gridRef(terminal, viewport: point) else { return }
            var selection = GhosttySelection()
            let result: GhosttyResult
            switch unit {
            case .word:
                var options = GhosttyTerminalSelectWordOptions()
                options.size = MemoryLayout<GhosttyTerminalSelectWordOptions>.size
                options.ref = ref
                result = ghostty_terminal_select_word(terminal, &options, &selection)
            case .line:
                var options = GhosttyTerminalSelectLineOptions()
                options.size = MemoryLayout<GhosttyTerminalSelectLineOptions>.size
                options.ref = ref
                result = ghostty_terminal_select_line(terminal, &options, &selection)
            }
            if result == GHOSTTY_SUCCESS {
                ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SELECTION, &selection)
            }
        }
    }

    /// The logical line under a viewport cell (rows joined where the text
    /// wrapped) and the UTF-16 offset of that cell's character in it.
    public func line(at point: (Int, Int)) -> (text: String, offset: Int)? {
        withTerminal { terminal in
            guard let ref = gridRef(terminal, viewport: point) else { return nil }
            var options = GhosttyTerminalSelectLineOptions()
            options.size = MemoryLayout<GhosttyTerminalSelectLineOptions>.size
            options.ref = ref
            var line = GhosttySelection()
            guard ghostty_terminal_select_line(terminal, &options, &line) == GHOSTTY_SUCCESS else { return nil }
            let text = format(terminal, selection: &line)
            // From the line's start through the cell: its length places the
            // cell in the text, whatever the widths of the characters before.
            var upToCell = GhosttySelection(start: line.start, end: ref, rectangle: false)
            let before = format(terminal, selection: &upToCell)
            return (text, max(0, (before as NSString).length - 1))
        }
    }

    /// Everything: what scrolled away, and the screen.
    public func selectAll() {
        withTerminal { terminal in
            var total = 0
            ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_TOTAL_ROWS, &total)
            func ref(_ x: UInt16, _ y: Int) -> GhosttyGridRef? {
                var p = GhosttyPoint()
                p.tag = GHOSTTY_POINT_TAG_SCREEN
                p.value.coordinate = GhosttyPointCoordinate(x: x, y: UInt32(max(0, y)))
                var ref = GhosttyGridRef()
                return ghostty_terminal_grid_ref(terminal, p, &ref) == GHOSTTY_SUCCESS ? ref : nil
            }
            guard let a = ref(0, 0), let b = ref(cols - 1, total - 1) else { return }
            var selection = GhosttySelection(start: a, end: b, rectangle: false)
            ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SELECTION, &selection)
        }
    }

    public func clearSelection() {
        withTerminal { _ = ghostty_terminal_set($0, GHOSTTY_TERMINAL_OPT_SELECTION, nil) }
    }

    public func selectedText() -> String? {
        withTerminal { terminal in
            var selection = GhosttySelection()
            guard ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_SELECTION, &selection) == GHOSTTY_SUCCESS else { return nil }
            let text = format(terminal, selection: &selection)
            return text.isEmpty ? nil : text
        }
    }

    /// The visible screen as plain text. Used by tests and debugging.
    public func screenText() -> String {
        withTerminal { format($0, selection: nil) }
    }

    private func gridRef(_ terminal: GhosttyTerminal, viewport point: (Int, Int)) -> GhosttyGridRef? {
        var p = GhosttyPoint()
        p.tag = GHOSTTY_POINT_TAG_VIEWPORT
        p.value.coordinate = GhosttyPointCoordinate(
            x: UInt16(max(0, min(point.0, Int(cols) - 1))),
            y: UInt32(max(0, min(point.1, Int(rows) - 1))))
        var ref = GhosttyGridRef()
        return ghostty_terminal_grid_ref(terminal, p, &ref) == GHOSTTY_SUCCESS ? ref : nil
    }

    private func format(_ terminal: GhosttyTerminal, selection: UnsafeMutablePointer<GhosttySelection>?) -> String {
        var formatter: GhosttyFormatter?
        guard ghostty_formatter_terminal_new(nil, &formatter, terminal) == GHOSTTY_SUCCESS, let formatter else { return "" }
        defer { ghostty_formatter_free(formatter) }
        var emit = GHOSTTY_FORMATTER_FORMAT_PLAIN
        ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_EMIT, &emit)
        var on = true
        ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_TRIM, &on)
        ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_UNWRAP, &on)
        if let selection { ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_SELECTION, selection) }
        var buffer: UnsafeMutablePointer<UInt8>?
        var length = 0
        guard ghostty_formatter_format_alloc(formatter, nil, &buffer, &length) == GHOSTTY_SUCCESS, let buffer else { return "" }
        defer { ghostty_free(nil, buffer, length) }
        return String(decoding: UnsafeBufferPointer(start: buffer, count: length), as: UTF8.self)
    }

    /// Feeds bytes straight into the terminal, as if the program had printed
    /// them. For tests.
    public func feed(_ text: String) {
        Array(text.utf8).withUnsafeBytes { feed($0) }
    }

    // MARK: Mouse

    /// A program asked to be told about the mouse (vim, htop, tmux).
    public var wantsMouse: Bool {
        withTerminal { terminal in
            var tracking = false
            ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING, &tracking)
            return tracking
        }
    }

    /// A full-screen program is up (a pager, an editor): there is no
    /// scrollback to move through.
    public var isAlternateScreen: Bool {
        withTerminal { terminal in
            var screen = GHOSTTY_TERMINAL_SCREEN_PRIMARY
            ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &screen)
            return screen == GHOSTTY_TERMINAL_SCREEN_ALTERNATE
        }
    }

    /// The Kitty keyboard protocol is on: the program tells keys such as
    /// Shift+Return apart itself.
    public var usesKittyKeyboard: Bool {
        withTerminal { terminal in
            var flags: UInt8 = 0
            ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_KITTY_KEYBOARD_FLAGS, &flags)
            return flags != 0
        }
    }

    public struct Mouse {
        public var action: GhosttyMouseAction
        /// Nil for motion with no button held.
        public var button: GhosttyMouseButton?
        public var mods: GhosttyMods = 0
        /// Pixels from the view's top left.
        public var x: Float
        public var y: Float
        public var anyButtonPressed = false
        public init(action: GhosttyMouseAction, button: GhosttyMouseButton?, x: Float, y: Float) {
            self.action = action
            self.button = button
            self.x = x
            self.y = y
        }
    }

    /// Reports a mouse event in the form the program asked for. Returns
    /// false when the program isn't listening for it.
    @discardableResult
    public func send(_ mouse: Mouse, viewWidth: UInt32, viewHeight: UInt32, padding: UInt32) -> Bool {
        if mouseEncoder == nil {
            ghostty_mouse_encoder_new(nil, &mouseEncoder)
            ghostty_mouse_event_new(nil, &mouseEvent)
            var track = true // motion within one cell is reported once
            ghostty_mouse_encoder_set(mouseEncoder, GHOSTTY_MOUSE_ENCODER_OPT_TRACK_LAST_CELL, &track)
        }
        guard let mouseEncoder, let mouseEvent else { return false }
        withTerminal { _ = ghostty_mouse_encoder_set_from_terminal(mouseEncoder, $0) }
        var size = GhosttyMouseEncoderSize(
            size: MemoryLayout<GhosttyMouseEncoderSize>.size, screen_width: viewWidth, screen_height: viewHeight,
            cell_width: cellWidthPx, cell_height: cellHeightPx,
            padding_top: padding, padding_bottom: padding, padding_right: padding, padding_left: padding)
        ghostty_mouse_encoder_set(mouseEncoder, GHOSTTY_MOUSE_ENCODER_OPT_SIZE, &size)
        var pressed = mouse.anyButtonPressed
        ghostty_mouse_encoder_set(mouseEncoder, GHOSTTY_MOUSE_ENCODER_OPT_ANY_BUTTON_PRESSED, &pressed)
        ghostty_mouse_event_set_action(mouseEvent, mouse.action)
        if let button = mouse.button {
            ghostty_mouse_event_set_button(mouseEvent, button)
        } else {
            ghostty_mouse_event_clear_button(mouseEvent)
        }
        ghostty_mouse_event_set_mods(mouseEvent, mouse.mods)
        ghostty_mouse_event_set_position(mouseEvent, GhosttyMousePosition(x: mouse.x, y: mouse.y))
        var out = [UInt8](repeating: 0, count: 64)
        var written = 0
        guard ghostty_mouse_encoder_encode(mouseEncoder, mouseEvent, &out, out.count, &written) == GHOSTTY_SUCCESS,
              written > 0 else { return false }
        write(Data(out[0..<written]))
        return true
    }

    // MARK: Prompts, links, folder

    /// Moves the view by whole commands: -1 shows the previous prompt at
    /// the top. Needs a shell that marks its prompts (OSC 133).
    public func scrollToPrompt(_ delta: Int) {
        var behavior = GhosttyTerminalScrollViewport()
        behavior.tag = GHOSTTY_TERMINAL_SCROLL_VIEWPORT_DELTA_PROMPT
        behavior.value.delta_prompt = delta
        withTerminal { _ = ghostty_terminal_scroll_viewport($0, behavior) }
    }

    /// The address of an OSC 8 link at a cell (text whose link isn't the
    /// text itself: `ls --hyperlink`, gh, many CLIs).
    public func hyperlink(at point: (Int, Int)) -> String? {
        withTerminal { terminal in
            guard var ref = gridRef(terminal, viewport: point) else { return nil }
            var length = 0
            guard ghostty_grid_ref_hyperlink_uri(&ref, nil, 0, &length) == GHOSTTY_OUT_OF_SPACE, length > 0, length < 8192 else { return nil }
            var bytes = [UInt8](repeating: 0, count: length)
            guard ghostty_grid_ref_hyperlink_uri(&ref, &bytes, length, &length) == GHOSTTY_SUCCESS else { return nil }
            return String(decoding: bytes.prefix(length), as: UTF8.self)
        }
    }

    /// The folder the shell is in now: where a new tab beside it starts.
    public func currentDirectory() -> String? {
        guard pid > 0 else { return nil }
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        return path.isEmpty ? nil : path
    }

    // MARK: Preferences

    public enum CursorShape: String, Codable, CaseIterable, Sendable { case block, bar, underline }

    /// The cursor a program gets unless it asks for another, and how much
    /// output is kept to scroll back to.
    public func applyPreferences(cursor: CursorShape, blink: Bool, scrollbackMB: Int) {
        withTerminal { terminal in
            var style = switch cursor {
            case .block: GHOSTTY_CURSOR_STYLE_BLOCK
            case .bar: GHOSTTY_CURSOR_STYLE_BAR
            case .underline: GHOSTTY_CURSOR_STYLE_UNDERLINE
            }
            ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_DEFAULT_CURSOR_STYLE, &style)
            var blinks = blink
            ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_DEFAULT_CURSOR_BLINK, &blinks)
            var bytes = max(1, scrollbackMB) * 1_000_000
            ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, &bytes)
            // Back to the default now, as a program's own "CSI 0 q" would.
            let reset = Array("\u{1b}[0 q".utf8)
            ghostty_terminal_vt_write(terminal, reset, reset.count)
        }
        onDirty?()
    }

    // MARK: Clearing

    /// ⌘K: the screen and everything scrolled off it go, and the program
    /// is asked to draw again (a shell prints its prompt).
    public func clear() {
        guard !isAlternateScreen else { return write("\u{0c}") } // a full-screen program just redraws
        feed("\u{1b}[H\u{1b}[2J\u{1b}[3J")
        write("\u{0c}")
    }

    // MARK: Search

    /// Looks for `needle` in the screen and the scrollback and selects the
    /// nearest match from the bottom. Returns which match is selected
    /// (1 is the newest) and how many there are.
    public func find(_ needle: String) -> (selected: Int, total: Int) {
        withTerminal { terminal in
            if search == nil { ghostty_search_new(nil, &search, terminal) }
            guard let search else { return (0, 0) }
            _ = needle.withGhosttyString { ghostty_search_set(search, GHOSTTY_SEARCH_OPT_NEEDLE, $0) }
            // ponytail: runs to the end under the terminal lock; 10 MB of
            // scrollback is searched in one go. Tick it across frames if a
            // search ever stalls typing.
            ghostty_search_run(search)
            var selected = 0
            if ghostty_search_get(search, GHOSTTY_SEARCH_DATA_SELECTED_INDEX, &selected) != GHOSTTY_SUCCESS {
                ghostty_search_select_next(search)
            }
            return showMatch(search, in: terminal)
        }
    }

    /// Moves to the next match up into history, or back down.
    public func findNext(backward: Bool = false) -> (selected: Int, total: Int) {
        withTerminal { terminal in
            guard let search else { return (0, 0) }
            _ = backward ? ghostty_search_select_prev(search) : ghostty_search_select_next(search)
            return showMatch(search, in: terminal)
        }
    }

    public func endFind() {
        withTerminal { terminal in
            guard let search else { return }
            ghostty_search_set(search, GHOSTTY_SEARCH_OPT_NEEDLE, nil)
            ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SELECTION, nil)
        }
    }

    /// The selected match is shown as the selection: drawn like one, and ⌘C copies it.
    private func showMatch(_ search: GhosttySearch, in terminal: GhosttyTerminal) -> (selected: Int, total: Int) {
        var total = 0
        ghostty_search_get(search, GHOSTTY_SEARCH_DATA_TOTAL_MATCHES, &total)
        var index = 0
        var match = GhosttySelection()
        guard ghostty_search_get(search, GHOSTTY_SEARCH_DATA_SELECTED_INDEX, &index) == GHOSTTY_SUCCESS,
              ghostty_search_get(search, GHOSTTY_SEARCH_DATA_SELECTED_MATCH, &match) == GHOSTTY_SUCCESS else {
            ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SELECTION, nil)
            return (0, total)
        }
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SELECTION, &match)
        return (index + 1, total)
    }

    public func feed(_ bytes: UnsafeRawBufferPointer) {
        withTerminal { ghostty_terminal_vt_write($0, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count) }
    }
}

// MARK: - Helpers

extension String {
    init(ghostty value: GhosttyString) {
        guard let ptr = value.ptr, value.len > 0 else { self = ""; return }
        self = String(decoding: UnsafeBufferPointer(start: ptr, count: value.len), as: UTF8.self)
    }

    func withGhosttyString<T>(_ body: (UnsafePointer<GhosttyString>) -> T) -> T {
        var bytes = Array(utf8)
        return bytes.withUnsafeMutableBufferPointer { buffer in
            var value = GhosttyString(ptr: buffer.baseAddress, len: buffer.count)
            return body(&value)
        }
    }
}

/// Text from a program is untrusted: strip control and invisible direction
/// characters before it reaches a tab label or a notification.
public func sanitizeForDisplay(_ text: String, limit: Int) -> String {
    let cleaned = text.unicodeScalars.filter { scalar in
        switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator, .surrogate, .privateUse, .unassigned: false
        default: true
        }
    }
    return String(String(String.UnicodeScalarView(cleaned)).prefix(limit))
}
