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

    public init(fontName: String, fontSize: Double, theme: TerminalTheme = .init()) {
        self.fontName = fontName
        self.fontSize = fontSize
        scale = Double(NSScreen.main?.backingScaleFactor ?? 2)
        renderer = TerminalRenderer(font: FontSpec(name: fontName, pointSize: fontSize, scale: scale))
        renderer.theme = theme
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
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
        let bg = TerminalTheme().background
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
        renderer.padding = Int((4 * scale).rounded())

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

    override public func becomeFirstResponder() -> Bool {
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
        let point = convert(event.locationInWindow, from: nil)
        let m = renderer.metrics
        let column = Int((point.x * scale - Double(renderer.padding)) / Double(m.cellWidth))
        let row = Int((point.y * scale - Double(renderer.padding)) / Double(m.cellHeight))
        return (max(0, min(column, Int(session?.cols ?? 1) - 1)), max(0, min(row, Int(session?.rows ?? 1) - 1)))
    }

    override public func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let session else { return }
        let cell = cell(at: event)
        switch event.clickCount {
        case 1:
            session.clearSelection()
            selectionAnchor = cell
        case 2: session.select(.word, at: cell)
        default: session.select(.line, at: cell)
        }
        selectionChanged()
    }

    override public func mouseDragged(with event: NSEvent) {
        // ponytail: the anchor is a viewport cell, so it drifts if output
        // scrolls mid-drag. Track it in screen coordinates if that bites.
        guard let anchor = selectionAnchor else { return }
        session?.select(from: anchor, to: cell(at: event))
        selectionChanged()
    }

    override public func mouseUp(with event: NSEvent) {
        selectionAnchor = nil
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
        guard rows != 0 else { return }
        scrollRemainder -= CGFloat(rows)
        session?.scroll(byRows: -rows) // wheel up shows older lines
        requestFrame()
    }

    // MARK: Accessibility

    // VoiceOver reads the visible screen as one text area.
    // ponytail: no per-line navigation or change announcements yet; add
    // NSAccessibilityNavigableStaticText when someone relies on it.
    override public func isAccessibilityElement() -> Bool { true }
    override public func accessibilityRole() -> NSAccessibility.Role? { .textArea }
    override public func accessibilityLabel() -> String? { "터미널" }
    override public func accessibilityValue() -> Any? { session?.screenText() }

    // MARK: Clipboard

    @objc public func copy(_ sender: Any?) {
        guard let text = session?.selectedText() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc public func paste(_ sender: Any?) {
        guard let session, let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        if session.paste(text) == .needsConfirmation {
            let alert = NSAlert()
            alert.messageText = "여러 줄을 붙여 넣을까요?"
            alert.informativeText = "붙여 넣는 내용에 줄바꿈이 있어 명령이 바로 실행될 수 있습니다.\n\n\(text.prefix(300))"
            alert.addButton(withTitle: "붙여넣기")
            alert.addButton(withTitle: "취소")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            _ = session.paste(text, allowUnsafe: true)
        }
        didInput()
    }
}
