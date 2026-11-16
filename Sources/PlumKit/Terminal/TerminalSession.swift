import CPty
import Foundation
import GhosttyVt

/// What a program running in a terminal told us about itself.
public enum AgentStatus: String, Codable, Sendable {
    case idle, working, waiting, done

    /// Which state wins when one workspace has several tabs.
    public var urgency: Int {
        switch self {
        case .idle: 0
        case .working: 1
        case .done: 2
        case .waiting: 3
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
    public var foreground: (UInt8, UInt8, UInt8) = (0xdc, 0xdf, 0xe4)
    public var background: (UInt8, UInt8, UInt8) = (0x16, 0x18, 0x1d)
    public var cursor: (UInt8, UInt8, UInt8) = (0xdc, 0xdf, 0xe4)
    public var selection: (UInt8, UInt8, UInt8) = (0x3a, 0x4a, 0x6b)
    /// The 16 ANSI colors; the other 240 palette entries keep the library defaults.
    public var ansi: [(UInt8, UInt8, UInt8)] = [
        (0x1d, 0x1f, 0x21), (0xe0, 0x6c, 0x75), (0x98, 0xc3, 0x79), (0xe5, 0xc0, 0x7b),
        (0x61, 0xaf, 0xef), (0xc6, 0x78, 0xdd), (0x56, 0xb6, 0xc2), (0xab, 0xb2, 0xbf),
        (0x5c, 0x63, 0x70), (0xe8, 0x82, 0x8a), (0xa9, 0xd1, 0x8a), (0xeb, 0xcb, 0x8b),
        (0x7a, 0xbb, 0xf2), (0xd1, 0x8c, 0xe6), (0x6c, 0xc4, 0xcf), (0xf2, 0xf4, 0xf8),
    ]
    public init() {}
}

/// One terminal: a pty, the program on it, and the VT state it draws into.
///
/// Threads: the pty is read and parsed on `ioQueue`. Everything public is
/// called from the main thread. `termLock` guards the terminal handle and
/// `renderLock` guards the render state; when both are needed, take
/// `termLock` first.
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

    private let ioQueue: DispatchQueue
    private var masterFD: Int32 = -1
    private var pid: pid_t = 0
    private var readSource: DispatchSourceRead?
    private var exitSource: DispatchSourceProcess?
    private var writeSource: DispatchSourceWrite?
    private var writeSourceActive = false
    private var pendingWrite = Data() // ioQueue only
    private var pendingWriteOffset = 0 // ioQueue only
    /// Bytes received from the program so far. Diagnostic; read loosely.
    public private(set) var bytesReceived = 0

    // Guarded by termLock.
    private var held = false
    private var holdStartedAt: UInt64 = 0
    private var dirtyPosted = false
    private var cellWidthPx: UInt32 = 8
    private var cellHeightPx: UInt32 = 16

    public init(id: UUID = UUID(), cols: UInt16 = 80, rows: UInt16 = 24, theme: TerminalTheme = .init()) {
        self.id = id
        self.cols = cols
        self.rows = rows
        ioQueue = DispatchQueue(label: "plum.terminal.io", qos: .userInteractive)

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
        readSource?.cancel()
        exitSource?.cancel()
        if writeSource != nil, !writeSourceActive { writeSource?.resume() }
        writeSource?.cancel()
        if pid > 0 {
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
            DispatchQueue.main.async { [weak session] in
                session?.title = title
                session?.onTitle?(title)
            }
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
                // on screen; capture it before anything newer is parsed.
                session.renderLock.lock()
                ghostty_render_state_update(session.renderState, terminal)
                session.renderLock.unlock()
                session.holdStartedAt = DispatchTime.now().uptimeNanoseconds
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

        let colorScheme: GhosttyTerminalColorSchemeFn = { _, _, out in
            out?.pointee = GHOSTTY_COLOR_SCHEME_DARK
            return true
        }
        set(GHOSTTY_TERMINAL_OPT_COLOR_SCHEME, unsafeBitCast(colorScheme, to: UnsafeRawPointer.self))
    }

    public func applyTheme(_ theme: TerminalTheme) {
        termLock.lock()
        defer { termLock.unlock() }
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
        precondition(masterFD < 0, "session already started")
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
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        masterFD = fd
        pid = child
        isRunning = true

        let read = DispatchSource.makeReadSource(fileDescriptor: fd, queue: ioQueue)
        read.setEventHandler { [weak self] in self?.drainPty() }
        read.setCancelHandler { close(fd) }
        readSource = read
        read.resume()

        // Collect the exit status when the shell ends, or it stays a zombie
        // for as long as the app runs.
        let exit = DispatchSource.makeProcessSource(identifier: child, eventMask: .exit, queue: ioQueue)
        exit.setEventHandler { [weak self] in
            var status: Int32 = 0
            waitpid(child, &status, 0)
            self?.pid = 0
            self?.exitSource?.cancel()
            self?.exitSource = nil
        }
        exitSource = exit
        exit.resume()

        let write = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: ioQueue)
        write.setEventHandler { [weak self] in self?.flushWrites() }
        writeSource = write // stays suspended until a write would block
    }

    private func drainPty() {
        let capacity = 128 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { buffer.deallocate() }

        // Bounded so a flood of output can't starve writes queued behind us.
        var budget = 4 * 1024 * 1024
        while budget > 0 {
            let n = read(masterFD, buffer, capacity)
            if n > 0 {
                budget -= n
                bytesReceived += n
                termLock.lock()
                ghostty_terminal_vt_write(terminal, buffer, n)
                let post = !dirtyPosted
                dirtyPosted = true
                termLock.unlock()
                if post { DispatchQueue.main.async { [weak self] in self?.onDirty?() } }
            } else if n < 0, errno == EINTR {
                continue
            } else if n < 0, errno == EAGAIN {
                return
            } else {
                childExited() // EOF, or EIO once the last slave fd closes
                return
            }
        }
    }

    /// The pty closed: nothing more can be read or written.
    private func childExited() {
        readSource?.cancel()
        readSource = nil
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            isRunning = false
            onExit?()
        }
    }

    /// Queues bytes for the program. Safe from any thread; order is kept.
    public func write(_ data: Data) {
        guard !data.isEmpty else { return }
        ioQueue.async { [weak self] in
            guard let self, masterFD >= 0, readSource != nil else { return }
            pendingWrite.append(data)
            flushWrites()
        }
    }

    public func write(_ text: String) { write(Data(text.utf8)) }

    /// Types `text` once the shell is at its prompt, reading input.
    /// Typing earlier works too, but the tty echoes the text above the prompt
    /// before the shell is ready to show it properly.
    public func writeWhenReady(_ text: String) {
        let deadline = DispatchTime.now().uptimeNanoseconds + 4_000_000_000
        func check() {
            ioQueue.asyncAfter(deadline: .now() + 0.03) { [weak self] in
                guard let self, readSource != nil else { return }
                // A shell's line editor switches the tty out of canonical
                // mode when it starts reading; that is the moment to type.
                var attributes = termios()
                let editing = tcgetattr(masterFD, &attributes) == 0 && attributes.c_lflag & tcflag_t(ICANON) == 0
                if editing || DispatchTime.now().uptimeNanoseconds > deadline {
                    pendingWrite.append(Data(text.utf8))
                    flushWrites()
                } else {
                    check()
                }
            }
        }
        check()
    }

    private func flushWrites() {
        while pendingWriteOffset < pendingWrite.count {
            let n = pendingWrite.withUnsafeBytes { raw in
                Darwin.write(masterFD, raw.baseAddress! + pendingWriteOffset, raw.count - pendingWriteOffset)
            }
            if n > 0 {
                pendingWriteOffset += n
            } else if n < 0, errno == EINTR {
                continue
            } else if n < 0, errno == EAGAIN {
                // The program isn't reading. Wait for room without blocking
                // the queue, so its output keeps being read meanwhile.
                if !writeSourceActive { writeSourceActive = true; writeSource?.resume() }
                return
            } else {
                break
            }
        }
        pendingWrite.removeAll(keepingCapacity: pendingWrite.count < 1 << 20)
        pendingWriteOffset = 0
        if writeSourceActive { writeSourceActive = false; writeSource?.suspend() }
    }

    public func terminate() {
        if pid > 0 { kill(pid, SIGHUP) }
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
        guard changed, masterFD >= 0 else { return }
        let clamp = { (v: UInt32) in UInt16(min(v, UInt32(UInt16.max))) }
        _ = plum_pty_resize(masterFD, cols, rows, clamp(UInt32(cols) * cellWidthPx), clamp(UInt32(rows) * cellHeightPx))
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
        let bytes = Array(text.utf8)
        withTerminal { ghostty_terminal_vt_write($0, bytes, bytes.count) }
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
