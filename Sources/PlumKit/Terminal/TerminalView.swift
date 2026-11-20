import AppKit
import GhosttyVt
import QuartzCore

/// Draws a `TerminalSession` and feeds it keyboard, mouse and IME input.
///
/// One view serves every tab: switching tabs swaps `session`. A Metal layer
/// keeps full-window drawables alive (tens of megabytes), so one layer per
/// tab would multiply that by the number of tabs.
public final class TerminalView: NSView, NSTextInputClient {
    /// The terminal on screen. Nil shows nothing.
    public var session: TerminalSession? {
        didSet {
            guard oldValue !== session else { return }
            oldValue?.onDirty = nil
            if focused {
                reportFocus(false, to: oldValue)
                reportFocus(true, to: session)
            }
            markedText = ""
            inputContext?.discardMarkedText()
            selectionAnchor = nil
            scrollRemainder = 0
            session?.onDirty = { [weak self] in self?.requestFrame() }
            updateGeometry()
        }
    }

    /// The user typed or pasted something into the given terminal.
    public var onUserInput: ((TerminalSession) -> Void)?

    private let renderer: TerminalRenderer
    private var fontName: String
    private var fontSize: Double
    private var scale: Double = 2

    private var link: CADisplayLink?
    private var needsDraw = false
    private var fallbackScheduled = false
    private var idleFrames = 0
    private var focused = false
    private var blinkOn = true
    private var blinkTimer: Timer?

    private var markedText = ""
    private var keyTextAccumulator: [String]?
    private var sawCommand = false
    private var scrollRemainder: CGFloat = 0
    private var selectionAnchor: (Int, Int)?

    public init(fontName: String, fontSize: Double, theme: TerminalTheme = .current) {
        self.fontName = fontName
        self.fontSize = fontSize
        scale = Double(NSScreen.main?.backingScaleFactor ?? 2)
        renderer = TerminalRenderer(font: FontSpec(name: fontName, pointSize: fontSize, scale: scale))
        renderer.theme = theme
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
        registerForDraggedTypes([.fileURL, .string])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        link?.invalidate()
        blinkTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: Layer and geometry

    override public func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.device = RenderContext.shared.device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.isOpaque = true
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer.maximumDrawableCount = 2 // each one is a full-window buffer
        // Hand each frame to the window server as soon as it is drawn. With
        // display sync on, a frame waits for a refresh before it is even
        // submitted and then another to be composited: one extra frame of
        // typing latency. The window server composites whole frames, so
        // nothing tears.
        layer.displaySyncEnabled = false
        // Shown until the first frame, which waits for the window to be visible.
        let bg = TerminalTheme.current.background
        layer.backgroundColor = CGColor(
            srgbRed: CGFloat(bg.0) / 255, green: CGFloat(bg.1) / 255, blue: CGFloat(bg.2) / 255, alpha: 1)
        return layer
    }

    private var metalLayer: CAMetalLayer? { layer as? CAMetalLayer }
    override public var isFlipped: Bool { true }
    override public var isOpaque: Bool { true }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        link?.invalidate()
        link = nil
        NotificationCenter.default.removeObserver(self)
        guard let window else { return }

        let link = displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        link.isPaused = true
        self.link = link

        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(windowKeyChanged), name: name, object: window)
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(occlusionChanged), name: NSWindow.didChangeOcclusionStateNotification, object: window)
        updateGeometry()
    }

    override public func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateGeometry()
    }

    override public func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateGeometry()
    }

    override public func viewDidUnhide() {
        super.viewDidUnhide()
        requestFrame()
    }

    override public func viewWillDraw() {
        super.viewWillDraw()
        // AppKit is putting the view on screen. A frame skipped while the
        // window was still hidden is drawn as soon as this pass finishes.
        guard needsDraw else { return }
        DispatchQueue.main.async { [weak self] in
            if self?.needsDraw == true { self?.requestFrame() }
        }
    }

    /// New colors: the appearance or the accent changed.
    public func setTheme(_ theme: TerminalTheme) {
        renderer.theme = theme
        renderer.needsFullRebuild = true
        let bg = theme.background
        metalLayer?.backgroundColor = CGColor(srgbRed: CGFloat(bg.0) / 255, green: CGFloat(bg.1) / 255, blue: CGFloat(bg.2) / 255, alpha: 1)
        requestFrame()
    }

    public func setFont(name: String, size: Double) {
        fontName = name
        fontSize = size
        renderer.setFont(FontSpec(name: name, pointSize: size, scale: scale))
        updateGeometry()
    }

    private func updateGeometry() {
        guard let metalLayer, bounds.width > 0, bounds.height > 0 else { return }
        let newScale = Double(window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2)
        if newScale != scale {
            scale = newScale
            renderer.setFont(FontSpec(name: fontName, pointSize: fontSize, scale: scale))
        }
        let width = Int((bounds.width * scale).rounded(.down))
        let height = Int((bounds.height * scale).rounded(.down))
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: width, height: height)
        renderer.padding = Int((14 * scale).rounded())

        let m = renderer.metrics
        let cols = max(2, (width - 2 * renderer.padding) / m.cellWidth)
        let rows = max(1, (height - 2 * renderer.padding) / m.cellHeight)
        session?.resize(
            cols: UInt16(min(cols, 1000)), rows: UInt16(min(rows, 500)),
            cellWidthPx: UInt32(m.cellWidth), cellHeightPx: UInt32(m.cellHeight))
        renderer.needsFullRebuild = true
        if isOnScreen { drawNow() } else { needsDraw = true }
    }

    /// Nothing is drawn (and no drawable is allocated) while nobody can see it.
    private var isOnScreen: Bool {
        // isVisible: while a window is being set up its views pass through
        // several sizes, and drawing at each would allocate a full set of
        // drawables per size.
        guard let window, window.isVisible, !isHiddenOrHasHiddenAncestor else { return false }
        return TerminalView.drawsWhileOccluded || window.occlusionState.contains(.visible)
    }

    /// Scripted checks capture the window while it sits behind others.
    static var drawsWhileOccluded = false
    /// Frames drawn since launch, for checking that an idle terminal stays idle.
    static var framesDrawn = 0

    @objc private func occlusionChanged() {
        if needsDraw { requestFrame() }
    }

    // MARK: Drawing

    /// Asks for a redraw. Cheap to call often: frames are capped at the
    /// display's refresh rate and nothing runs while the screen is unchanged.
    public func requestFrame() {
        guard isOnScreen else {
            needsDraw = true
            return
        }
        if let link, !link.isPaused {
            needsDraw = true
            scheduleFallbackDraw()
            return
        }
        // Idle: draw right away instead of waiting for the next refresh, so
        // the first keystroke after a pause isn't a frame late.
        drawNow()
        idleFrames = 0
        link?.isPaused = false
    }

    /// The display link normally draws within one refresh. It stops ticking
    /// when the system decides the view isn't showing, and a terminal stuck on
    /// an old frame is worse than a slow one, so draw anyway after a moment.
    private func scheduleFallbackDraw() {
        guard !fallbackScheduled else { return }
        fallbackScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            fallbackScheduled = false
            if needsDraw, isOnScreen { drawNow() }
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        if needsDraw {
            idleFrames = 0
            drawNow()
        } else {
            idleFrames += 1
            if idleFrames > 2 { link.isPaused = true }
        }
    }

    private func drawNow() {
        guard let metalLayer, let session else { return }
        needsDraw = false
        TerminalView.framesDrawn += 1
        let overlay = TerminalRenderer.Overlay(focused: focused, blinkOn: blinkOn, preedit: markedText)
        session.withFrame { renderer.update(from: $0, overlay: overlay) }
        renderer.draw(to: metalLayer)
        updateBlinkTimer()
    }

    private func updateBlinkTimer() {
        let shouldBlink = renderer.cursorBlinks && focused
        if shouldBlink, blinkTimer == nil {
            blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
                guard let self else { return }
                blinkOn.toggle()
                requestFrame()
            }
        } else if !shouldBlink, blinkTimer != nil {
            blinkTimer?.invalidate()
            blinkTimer = nil
            blinkOn = true
        }
    }

    // MARK: Focus

    override public var acceptsFirstResponder: Bool { true }

    /// It took the keyboard (a click in a pane of a split).
    public var onFocus: ((TerminalSession) -> Void)?

    override public func becomeFirstResponder() -> Bool {
        if let session { onFocus?(session) }
        setFocused(window?.isKeyWindow ?? false)
        return true
    }

    override public func resignFirstResponder() -> Bool {
        setFocused(false)
        return true
    }

    @objc private func windowKeyChanged() {
        setFocused(window?.isKeyWindow == true && window?.firstResponder === self)
    }

    private func setFocused(_ value: Bool) {
        guard value != focused else { return }
        focused = value
        blinkOn = true
        reportFocus(value, to: session)
        requestFrame()
    }

    /// Programs that asked for focus events (mode 1004) get told.
    private func reportFocus(_ gained: Bool, to session: TerminalSession?) {
        guard let session else { return }
        let wantsFocusEvents = session.withTerminal { terminal -> Bool in
            var config = GhosttyTerminalModeConfig(mode: ghostty_mode_new(1004, false), value: false)
            ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_MODE, &config)
            return config.value
        }
        if wantsFocusEvents { session.write(gained ? "\u{1b}[I" : "\u{1b}[O") }
    }

    // MARK: Keyboard

    override public func keyDown(with event: NSEvent) {
        guard let session else { return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // The line-editing shortcuts every macOS terminal user expects.
        if flags.subtracting([.numericPad, .function]) == .command {
            switch event.keyCode {
            case 0x7B: return sendRaw("\u{01}") // ⌘← start of line
            case 0x7C: return sendRaw("\u{05}") // ⌘→ end of line
            case 0x33: return sendRaw("\u{15}") // ⌘⌫ delete line
            default: break
            }
        }
        if flags.subtracting([.numericPad, .function]) == .option, markedText.isEmpty {
            switch event.keyCode {
            case 0x7B: return sendRaw("\u{1b}b") // ⌥← back one word
            case 0x7C: return sendRaw("\u{1b}f") // ⌥→ forward one word
            default: break
            }
        }
        if flags.contains(.command) { return } // unclaimed ⌘ shortcuts are not terminal input

        // Shift+Return is a new line in Claude Code and Codex. Programs on
        // the Kitty keyboard protocol tell it from Return themselves; for
        // the rest it would be a plain Return, so it goes as Esc Return,
        // which they (and zsh) take as "new line, don't send".
        if event.keyCode == 0x24, flags.subtracting(.numericPad) == .shift, markedText.isEmpty, !session.usesKittyKeyboard {
            return sendRaw("\u{1b}\r")
        }
        // ⌥ as Meta: the key goes as itself with Alt held, not as the
        // symbol macOS would type.
        if TerminalSession.optionAsMeta, flags.contains(.option), !flags.contains(.control), markedText.isEmpty,
           let plain = KeyMap.asciiCharacters(keyCode: event.keyCode, shift: flags.contains(.shift)),
           let scalar = plain.unicodeScalars.first, scalar.value >= 0x20, scalar.value != 0x7F, !(0xF700...0xF8FF).contains(scalar.value) {
            var key = TerminalSession.Key(key: KeyMap.key(forKeyCode: event.keyCode))
            key.action = event.isARepeat ? GHOSTTY_KEY_ACTION_REPEAT : GHOSTTY_KEY_ACTION_PRESS
            key.mods = KeyMap.mods(flags)
            key.unshiftedCodepoint = KeyMap.asciiCharacters(keyCode: event.keyCode, shift: false)?.unicodeScalars.first?.value ?? 0
            key.text = plain
            key.consumedMods = key.mods & (1 << 0) // shift shaped the text; Alt is still held
            return send(key)
        }

        let wasComposing = !markedText.isEmpty
        keyTextAccumulator = []
        sawCommand = false
        interpretKeyEvents([event])
        let texts = keyTextAccumulator ?? []
        keyTextAccumulator = nil

        var key = TerminalSession.Key(key: KeyMap.key(forKeyCode: event.keyCode))
        key.action = event.isARepeat ? GHOSTTY_KEY_ACTION_REPEAT : GHOSTTY_KEY_ACTION_PRESS
        key.mods = KeyMap.mods(flags)
        key.unshiftedCodepoint = event.characters(byApplyingModifiers: [])?.unicodeScalars.first?.value ?? 0
        let textMods = key.mods & (1 << 0 | 1 << 2) // shift and option shape the text

        if texts.count == 1, !sawCommand {
            key.text = texts[0]
            key.consumedMods = textMods
            send(key)
        } else if !texts.isEmpty {
            // The input method committed text and the key still has its own
            // job, e.g. Enter right after a Hangul syllable.
            for text in texts { session.write(text) }
            if sawCommand { send(key) } else { didInput() }
        } else {
            // While composing, keys edit the pending text and must not
            // reach the program.
            key.composing = wasComposing || !markedText.isEmpty
            if !key.composing, let scalar = event.characters?.unicodeScalars.first,
               scalar.value >= 0x20, scalar.value != 0x7F, !(0xF700...0xF8FF).contains(scalar.value) {
                key.text = flags.contains(.control)
                    ? event.characters(byApplyingModifiers: flags.subtracting(.control))
                    : event.characters
                key.consumedMods = textMods
            }
            send(key)
        }
    }

    override public func keyUp(with event: NSEvent) {
        // Only programs using the Kitty keyboard protocol see releases; the
        // encoder produces nothing otherwise.
        var key = TerminalSession.Key(key: KeyMap.key(forKeyCode: event.keyCode))
        key.action = GHOSTTY_KEY_ACTION_RELEASE
        key.mods = KeyMap.mods(event.modifierFlags)
        session?.send(key)
    }

    private func send(_ key: TerminalSession.Key) {
        if session?.send(key) == true { didInput() }
    }

    private func sendRaw(_ text: String) {
        session?.write(text)
        didInput()
    }

    private func didInput() {
        guard let session else { return }
        session.scrollToBottom()
        onUserInput?(session)
    }

    override public func doCommand(by selector: Selector) {
        sawCommand = true // the key is a command (Enter, arrows…), not text
    }

    // MARK: NSTextInputClient

    public func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        markedText = ""
        if keyTextAccumulator != nil {
            keyTextAccumulator?.append(text)
        } else if !text.isEmpty {
            sendRaw(text) // emoji picker, dictation: not tied to a key press
        }
        requestFrame()
    }

    public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        markedText = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        requestFrame()
    }

    public func unmarkText() {
        markedText = ""
        requestFrame()
    }

    public func hasMarkedText() -> Bool { !markedText.isEmpty }
    public func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    public func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    public func characterIndex(for point: NSPoint) -> Int { 0 }

    public func markedRange() -> NSRange {
        markedText.isEmpty ? NSRange(location: NSNotFound, length: 0) : NSRange(location: 0, length: markedText.utf16.count)
    }

    public func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }

    /// Where the input method should put its candidate window: at the cursor.
    public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let (x, y) = session?.withTerminal { terminal -> (Int, Int) in
            var x: UInt16 = 0
            var y: UInt16 = 0
            ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_CURSOR_X, &x)
            ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_CURSOR_Y, &y)
            return (Int(x), Int(y))
        } ?? (0, 0)
        let m = renderer.metrics
        let rect = NSRect(
            x: Double(renderer.padding + x * m.cellWidth) / scale,
            y: Double(renderer.padding + y * m.cellHeight) / scale,
            width: Double(m.cellWidth) / scale, height: Double(m.cellHeight) / scale)
        return window?.convertToScreen(convert(rect, to: nil)) ?? rect
    }

    // MARK: Mouse

    private func cell(at event: NSEvent) -> (Int, Int) {
        cell(atViewPoint: convert(event.locationInWindow, from: nil))
    }

    private func cell(atViewPoint point: NSPoint) -> (Int, Int) {
        let m = renderer.metrics
        let column = Int((point.x * scale - Double(renderer.padding)) / Double(m.cellWidth))
        let row = Int((point.y * scale - Double(renderer.padding)) / Double(m.cellHeight))
        return (max(0, min(column, Int(session?.cols ?? 1) - 1)), max(0, min(row, Int(session?.rows ?? 1) - 1)))
    }

    /// Tells the program about a mouse event if it asked to hear of them.
    /// Shift keeps the mouse for Plum (selecting), as in other terminals.
    /// True means the event is the program's, whether or not it wanted
    /// this particular one.
    private func report(_ event: NSEvent, _ action: GhosttyMouseAction, _ button: GhosttyMouseButton?) -> Bool {
        guard let session, !event.modifierFlags.contains(.shift), session.wantsMouse else { return false }
        let point = convert(event.locationInWindow, from: nil)
        var mouse = TerminalSession.Mouse(action: action, button: button, x: Float(point.x * scale), y: Float(point.y * scale))
        mouse.mods = KeyMap.mods(event.modifierFlags.intersection(.deviceIndependentFlagsMask))
        mouse.anyButtonPressed = NSEvent.pressedMouseButtons != 0
        session.send(
            mouse, viewWidth: UInt32(bounds.width * scale), viewHeight: UInt32(bounds.height * scale),
            padding: UInt32(renderer.padding))
        return true
    }

    /// The press went to the program, so its drag and release do too.
    private var programHasMouse = false

    override public func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let session else { return }
        programHasMouse = !event.modifierFlags.contains(.command) && report(event, GHOSTTY_MOUSE_ACTION_PRESS, GHOSTTY_MOUSE_BUTTON_LEFT)
        if programHasMouse { return }
        let cell = cell(at: event)
        // ⌘-click opens a link, as in other macOS terminals.
        if event.modifierFlags.contains(.command), event.clickCount == 1, let url = link(at: cell) {
            if url.isFileURL {
                // A file a program linked to is shown, never opened: opening
                // could run it.
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } else {
                TerminalView.openLink(url)
            }
            return
        }
        switch event.clickCount {
        case 1:
            session.clearSelection()
            selectionAnchor = cell
        case 2: session.select(.word, at: cell)
        default: session.select(.line, at: cell)
        }
        selectionChanged()
    }

    /// The link at a cell: a program's own (OSC 8), else a web address in
    /// the text. Only web pages and files.
    private func link(at cell: (Int, Int)) -> URL? {
        guard let session else { return nil }
        if let address = session.hyperlink(at: cell), let url = URL(string: address),
           ["http", "https", "file"].contains(url.scheme?.lowercased() ?? "") {
            return url
        }
        guard let line = session.line(at: cell) else { return nil }
        return webLink(in: line.text, at: line.offset)
    }

    // A pointing hand over a link while ⌘ is down, the I-beam otherwise.
    override public func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .cursorUpdate, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override public func cursorUpdate(with event: NSEvent) { updatePointer(event) }

    override public func mouseMoved(with event: NSEvent) {
        // Programs that follow every move (mode 1003) are told; the encoder
        // drops it for those that don't.
        _ = report(event, GHOSTTY_MOUSE_ACTION_MOTION, nil)
        updatePointer(event)
    }

    override public func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        updatePointer(event)
    }

    private func updatePointer(_ event: NSEvent) {
        guard let window else { return }
        let inside = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard bounds.contains(inside) else { return }
        let overLink = event.modifierFlags.contains(.command) && link(at: cell(atViewPoint: inside)) != nil
        (overLink ? NSCursor.pointingHand : NSCursor.iBeam).set()
    }

    /// ⌘↑ and ⌘↓: the view jumps to the previous or next command's prompt.
    public func scrollToPrompt(_ delta: Int) {
        session?.scrollToPrompt(delta)
        requestFrame()
    }

    override public func mouseDragged(with event: NSEvent) {
        if programHasMouse { _ = report(event, GHOSTTY_MOUSE_ACTION_MOTION, GHOSTTY_MOUSE_BUTTON_LEFT); return }
        // ponytail: the anchor is a viewport cell, so it drifts if output
        // scrolls mid-drag. Track it in screen coordinates if that bites.
        guard let anchor = selectionAnchor else { return }
        session?.select(from: anchor, to: cell(at: event))
        selectionChanged()
    }

    override public func mouseUp(with event: NSEvent) {
        if programHasMouse {
            programHasMouse = false
            _ = report(event, GHOSTTY_MOUSE_ACTION_RELEASE, GHOSTTY_MOUSE_BUTTON_LEFT)
            return
        }
        selectionAnchor = nil
    }

    /// ⌘F in the menu and "찾기…" here both open the find bar.
    public var onFind: (() -> Void)?
    /// "오른쪽으로 나누기" and "아래로 나누기" here.
    public var onSplit: ((SplitNode.Axis) -> Void)?

    override public func rightMouseDown(with event: NSEvent) {
        if report(event, GHOSTTY_MOUSE_ACTION_PRESS, GHOSTTY_MOUSE_BUTTON_RIGHT) { return }
        guard let window, let session else { return }
        window.makeFirstResponder(self)
        let items: [DropdownItem] = [
            .command(String(localized: "복사"), symbol: "doc.on.doc", enabled: session.selectedText() != nil) { [weak self] in self?.copy(nil) },
            .command(String(localized: "붙여넣기"), symbol: "doc.on.clipboard") { [weak self] in self?.paste(nil) },
            .command(String(localized: "전체 선택"), symbol: "selection.pin.in.out") { [weak self] in self?.selectAll(nil) },
            .separator(),
            .command(String(localized: "찾기…"), symbol: "magnifyingglass") { [weak self] in self?.onFind?() },
            .command(String(localized: "화면 지우기"), symbol: "eraser") { [weak self] in self?.clear() },
            .separator(),
            .command(String(localized: "오른쪽으로 나누기"), symbol: "rectangle.split.2x1") { [weak self] in self?.onSplit?(.horizontal) },
            .command(String(localized: "아래로 나누기"), symbol: "rectangle.split.1x2") { [weak self] in self?.onSplit?(.vertical) },
        ]
        DropdownPanel.showMenu(items, at: window.convertPoint(toScreen: event.locationInWindow), in: window)
    }

    override public func rightMouseUp(with event: NSEvent) {
        _ = report(event, GHOSTTY_MOUSE_ACTION_RELEASE, GHOSTTY_MOUSE_BUTTON_RIGHT)
    }

    override public func otherMouseDown(with event: NSEvent) {
        _ = report(event, GHOSTTY_MOUSE_ACTION_PRESS, GHOSTTY_MOUSE_BUTTON_MIDDLE)
    }

    override public func otherMouseUp(with event: NSEvent) {
        _ = report(event, GHOSTTY_MOUSE_ACTION_RELEASE, GHOSTTY_MOUSE_BUTTON_MIDDLE)
    }

    override public func selectAll(_ sender: Any?) {
        session?.selectAll()
        selectionChanged()
    }

    /// ⌘K.
    public func clear() {
        session?.clear()
        selectionChanged()
    }

    // MARK: Dropped files

    override public func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        session == nil ? [] : .copy
    }

    /// A file dropped on the terminal types its path, quoted for the
    /// shell; dropped text is pasted.
    override public func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let board = sender.draggingPasteboard
        let files = (board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        let text = files.isEmpty
            ? board.string(forType: .string) ?? ""
            : files.map { Self.shellQuoted($0.path) }.joined(separator: " ") + " "
        guard !text.isEmpty else { return false }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeFirstResponder(self)
        insert(text)
        return true
    }

    /// A path as the shell reads it back: everything that isn't plainly
    /// safe gets a backslash, as Terminal does for dropped files.
    static func shellQuoted(_ path: String) -> String {
        var quoted = ""
        for scalar in path.unicodeScalars {
            let safe = scalar.value > 0x7F || CharacterSet.alphanumerics.contains(scalar) || "_./-+:@%,=".unicodeScalars.contains(scalar)
            if !safe { quoted.append("\\") }
            quoted.unicodeScalars.append(scalar)
        }
        return quoted
    }

    func selectionChanged() {
        renderer.needsFullRebuild = true
        requestFrame()
    }

    override public func scrollWheel(with event: NSEvent) {
        let cellPoints = Double(renderer.metrics.cellHeight) / scale
        scrollRemainder += event.hasPreciseScrollingDeltas
            ? event.scrollingDeltaY / cellPoints
            : event.scrollingDeltaY
        let rows = Int(scrollRemainder.rounded(.towardZero))
        guard rows != 0, let session else { return }
        scrollRemainder -= CGFloat(rows)
        let up = rows > 0
        if !event.modifierFlags.contains(.shift), session.wantsMouse {
            // The program scrolls itself (vim, tmux, htop): wheel buttons 4 and 5.
            for _ in 0..<min(abs(rows), 20) {
                _ = report(event, GHOSTTY_MOUSE_ACTION_PRESS, up ? GHOSTTY_MOUSE_BUTTON_FOUR : GHOSTTY_MOUSE_BUTTON_FIVE)
            }
        } else if session.isAlternateScreen {
            // A full-screen program that doesn't follow the mouse (less,
            // git's pager, man): the wheel presses ↑ and ↓ for it.
            for _ in 0..<min(abs(rows), 20) {
                session.send(TerminalSession.Key(key: up ? GHOSTTY_KEY_ARROW_UP : GHOSTTY_KEY_ARROW_DOWN))
            }
        } else {
            session.scroll(byRows: -rows) // wheel up shows older lines
            requestFrame()
        }
    }

    // MARK: Links

    /// Opens a clicked link. Scripted checks swap it out so nothing opens.
    static var openLink: (URL) -> Void = { NSWorkspace.shared.open($0) }
    /// Where paste reads from. Scripted checks use their own, so the user's
    /// clipboard is never touched.
    static var pasteboard = NSPasteboard.general

    /// The middle of a viewport cell, in window coordinates.
    func windowPoint(column: Int, row: Int) -> NSPoint {
        let m = renderer.metrics
        let point = NSPoint(
            x: (Double(renderer.padding) + (Double(column) + 0.5) * Double(m.cellWidth)) / scale,
            y: (Double(renderer.padding) + (Double(row) + 0.5) * Double(m.cellHeight)) / scale)
        return convert(point, to: nil)
    }

    /// The http(s) link covering a UTF-16 offset in a line of terminal text.
    /// Other schemes are left alone: a file link in program output could
    /// point at something that runs.
    static func webLink(in text: String, at offset: Int) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return detector.matches(in: text, range: range)
            .first { NSLocationInRange(offset, $0.range) }
            .flatMap(\.url)
            .flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil }
    }

    private func webLink(in text: String, at offset: Int) -> URL? { Self.webLink(in: text, at: offset) }

    // MARK: Accessibility

    // VoiceOver reads the visible screen as one text area.
    // ponytail: no per-line navigation or change announcements yet; add
    // NSAccessibilityNavigableStaticText when someone relies on it.
    override public func isAccessibilityElement() -> Bool { true }
    override public func accessibilityRole() -> NSAccessibility.Role? { .textArea }
    override public func accessibilityLabel() -> String? { String(localized: "터미널") }
    override public func accessibilityValue() -> Any? { session?.screenText() }

    // MARK: Clipboard

    @objc public func copy(_ sender: Any?) {
        guard let text = session?.selectedText() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Asks before a paste that could run commands (lines, no bracketed
    /// paste); calls back with the answer. Without it such pastes are refused.
    public var confirmPaste: ((String, @escaping (Bool) -> Void) -> Void)?

    @objc public func paste(_ sender: Any?) {
        guard let text = TerminalView.pasteboard.string(forType: .string) else { return }
        insert(text)
    }

    private func insert(_ text: String) {
        guard let session, !text.isEmpty else { return }
        guard session.paste(text) == .needsConfirmation else { return didInput() }
        confirmPaste?(text) { [weak self] confirmed in
            guard confirmed else { return }
            _ = session.paste(text, allowUnsafe: true)
            self?.didInput()
        }
    }
}
