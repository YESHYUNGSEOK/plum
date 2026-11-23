import AppKit
import GhosttyVt
import Metal
import QuartzCore

/// GPU objects shared by every terminal view.
public final class RenderContext {
    static let shared = RenderContext()

    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
    private var atlases: [FontSpec: GlyphAtlas] = [:]

    private init() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            fatalError("Metal is not available on this Mac")
        }
        self.device = device
        self.queue = queue
        do {
            // The app bundle carries the shader precompiled; compiling it
            // here costs time and a large burst of memory at launch.
            let library: MTLLibrary = if let compiled = Bundle.main.url(forResource: "default", withExtension: "metallib") {
                try device.makeLibrary(URL: compiled)
            } else {
                try device.makeLibrary(source: RenderContext.shaderSource, options: nil)
            }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "cell_vertex")
            descriptor.fragmentFunction = library.makeFunction(name: "cell_fragment")
            let attachment = descriptor.colorAttachments[0]!
            attachment.pixelFormat = .bgra8Unorm
            attachment.isBlendingEnabled = true
            // Colors leave the fragment shader premultiplied.
            attachment.sourceRGBBlendFactor = .one
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            fatalError("Could not build the terminal shader: \(error)")
        }
    }

    func atlas(for spec: FontSpec) -> GlyphAtlas {
        if let existing = atlases[spec] { return existing }
        // Font size changes leave old atlases behind; keep only the current
        // few so zooming in and out doesn't pile up textures.
        if atlases.count >= 3 { atlases.removeAll() }
        let atlas = GlyphAtlas(device: device, spec: spec)
        atlases[spec] = atlas
        return atlas
    }

    /// Also written out by `Plum --print-shader` for the bundle script.
    public static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Instance {
        short2 position;
        ushort2 size;
        ushort2 uv;
        ushort mode;      // 0 = solid, 1 = glyph mask, 2 = color glyph
        ushort unused;
        uint color;       // RGBA, straight alpha
    };

    struct Varyings {
        float4 position [[position]];
        float2 uv;
        float4 color;
        uint mode [[flat]];
    };

    vertex Varyings cell_vertex(uint vertexID [[vertex_id]],
                                uint instanceID [[instance_id]],
                                const device Instance *instances [[buffer(0)]],
                                constant float2 &viewport [[buffer(1)]]) {
        Instance instance = instances[instanceID];
        float2 corner = float2(vertexID & 1, vertexID >> 1);
        float2 pixel = float2(instance.position) + corner * float2(instance.size);

        Varyings out;
        out.position = float4(pixel.x / viewport.x * 2.0 - 1.0, 1.0 - pixel.y / viewport.y * 2.0, 0.0, 1.0);
        out.uv = float2(instance.uv) + corner * float2(instance.size);
        uint c = instance.color;
        float4 color = float4(c & 0xFF, (c >> 8) & 0xFF, (c >> 16) & 0xFF, c >> 24) / 255.0;
        out.color = float4(color.rgb * color.a, color.a);
        out.mode = instance.mode;
        return out;
    }

    fragment float4 cell_fragment(Varyings in [[stage_in]],
                                  texture2d<float> mask [[texture(0)]],
                                  texture2d<float> colored [[texture(1)]]) {
        if (in.mode == 0) return in.color;
        uint2 texel = uint2(in.uv);
        if (in.mode == 1) return in.color * mask.read(texel).r;
        return colored.read(texel) * in.color.a;
    }
    """
}

/// Turns a terminal's render state into GPU instances and draws them.
/// One per terminal view. Main thread only.
final class TerminalRenderer {
    struct Instance {
        var x: Int16
        var y: Int16
        var width: UInt16
        var height: UInt16
        var u: UInt16 = 0
        var v: UInt16 = 0
        var mode: UInt16 = 0
        var unused: UInt16 = 0
        var color: UInt32
    }

    struct Overlay: Equatable {
        var focused = true
        var blinkOn = true
        var preedit = ""
    }

    private struct Row {
        var backgrounds: [Instance] = []
        var glyphs: [Instance] = []
        var decorations: [Instance] = []
    }

    private struct CursorState: Equatable {
        var x = -1
        var y = -1
        var style = GHOSTTY_CURSOR_STYLE_BLOCK.rawValue
        var wideTail = false
        var overlay = Overlay()
    }

    private let context = RenderContext.shared
    private var atlas: GlyphAtlas
    private var atlasGeneration: Int
    private var rows: [Row] = []
    private var cursor = CursorState()
    private var palette = Palette()
    private var extras: [Instance] = []
    private var buffers: [MTLBuffer?] = [nil, nil, nil]
    private var bufferIndex = 0
    private var rowIterator: GhosttyRenderStateRowIterator?
    private var rowCells: GhosttyRenderStateRowCells?
    /// A grapheme cluster's codepoints, read into the same memory every time.
    private static let clusterCapacity = 16
    private let codepoints = UnsafeMutablePointer<UInt32>.allocate(capacity: clusterCapacity)

    /// Padding around the grid, in pixels.
    var padding = 8
    var theme = TerminalTheme()
    /// Set to redraw every row on the next frame.
    var needsFullRebuild = true
    /// What the last frame reported; the view uses it to drive blinking.
    private(set) var cursorBlinks = false

    var metrics: CellMetrics { atlas.metrics }

    init(font: FontSpec) {
        atlas = context.atlas(for: font)
        atlasGeneration = atlas.generation
        ghostty_render_state_row_iterator_new(nil, &rowIterator)
        ghostty_render_state_row_cells_new(nil, &rowCells)
    }

    deinit {
        codepoints.deallocate()
        ghostty_render_state_row_cells_free(rowCells)
        ghostty_render_state_row_iterator_free(rowIterator)
    }

    func setFont(_ font: FontSpec) {
        atlas = context.atlas(for: font)
        atlasGeneration = atlas.generation
        needsFullRebuild = true
    }

    // MARK: Building a frame

    private struct Palette: Equatable {
        var foreground: UInt32 = 0
        var background: UInt32 = 0
        var cursor: UInt32 = 0
    }

    private static func pack(_ c: GhosttyColorRgb, alpha: UInt32 = 255) -> UInt32 {
        UInt32(c.r) | UInt32(c.g) << 8 | UInt32(c.b) << 16 | alpha << 24
    }

    private static func pack(_ c: (UInt8, UInt8, UInt8)) -> UInt32 {
        UInt32(c.0) | UInt32(c.1) << 8 | UInt32(c.2) << 16 | 255 << 24
    }

    /// Reads the render state and rebuilds whatever changed.
    /// Call inside `TerminalSession.withFrame`.
    func update(from state: GhosttyRenderState, overlay: Overlay) {
        var newPalette = Palette()
        var color = GhosttyColorRgb()
        ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_COLOR_FOREGROUND, &color)
        newPalette.foreground = Self.pack(color)
        ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_COLOR_BACKGROUND, &color)
        newPalette.background = Self.pack(color)
        newPalette.cursor = ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_COLOR_CURSOR, &color) == GHOSTTY_SUCCESS
            ? Self.pack(color) : newPalette.foreground

        var cursorInfo = GhosttyRenderStateCursor()
        cursorInfo.size = MemoryLayout<GhosttyRenderStateCursor>.size
        ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_CURSOR, &cursorInfo)
        cursorBlinks = cursorInfo.visible && cursorInfo.blinking
        var newCursor = CursorState(overlay: overlay)
        if cursorInfo.visible, cursorInfo.viewport_has_value, overlay.blinkOn || !overlay.focused || !cursorInfo.blinking {
            newCursor.x = Int(cursorInfo.viewport_x)
            newCursor.y = Int(cursorInfo.viewport_y)
            newCursor.style = cursorInfo.visual_style.rawValue
            newCursor.wideTail = cursorInfo.wide_tail
        }

        var rowCount: UInt16 = 0
        ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_ROWS, &rowCount)
        var dirty = GHOSTTY_RENDER_STATE_DIRTY_FALSE
        ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_DIRTY, &dirty)

        // Rebuilding can empty a full atlas, which invalidates rows built
        // earlier in the same pass; in that case go around once more.
        for _ in 0..<2 {
            let full = needsFullRebuild || dirty == GHOSTTY_RENDER_STATE_DIRTY_FULL
                || rows.count != Int(rowCount) || newPalette != palette || atlasGeneration != atlas.generation
            atlasGeneration = atlas.generation
            if rows.count != Int(rowCount) { rows = Array(repeating: Row(), count: Int(rowCount)) }

            var iterator = rowIterator
            ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &iterator)
            var y = 0
            while ghostty_render_state_row_iterator_next(rowIterator), y < rows.count {
                var rowDirty = false
                ghostty_render_state_row_get(rowIterator, GHOSTTY_RENDER_STATE_ROW_DATA_DIRTY, &rowDirty)
                if full || rowDirty || y == cursor.y || y == newCursor.y {
                    buildRow(y, colors: newPalette, cursor: newCursor)
                }
                y += 1
            }
            if atlasGeneration == atlas.generation { break }
            needsFullRebuild = true
        }

        palette = newPalette
        cursor = newCursor
        needsFullRebuild = false
        ghostty_render_state_clean(state)
        buildExtras(overlay: overlay)
    }

    private func buildRow(_ y: Int, colors: Palette, cursor: CursorState) {
        let atlas = atlas
        let m = atlas.metrics
        let top = padding + y * m.cellHeight
        // Rebuilt in place: taken out of `rows`, its arrays are uniquely
        // held and keep their capacity instead of being allocated again.
        var row = Row()
        swap(&row, &rows[y])
        defer { rows[y] = row }
        row.backgrounds.removeAll(keepingCapacity: true)
        row.glyphs.removeAll(keepingCapacity: true)
        row.decorations.removeAll(keepingCapacity: true)

        var selection = GhosttyRenderStateRowSelection()
        selection.size = MemoryLayout<GhosttyRenderStateRowSelection>.size
        let hasSelection = ghostty_render_state_row_get(rowIterator, GHOSTTY_RENDER_STATE_ROW_DATA_SELECTION, &selection) == GHOSTTY_SUCCESS
        let selectionColor = Self.pack(theme.selection)

        // A block cursor is baked into the row: its cell gets the cursor
        // color and the glyph is drawn in the background color.
        let blockCursor = cursor.y == y && cursor.overlay.focused && cursor.overlay.preedit.isEmpty
            && cursor.style == GHOSTTY_CURSOR_STYLE_BLOCK.rawValue
        let cursorColumn = cursor.wideTail ? cursor.x - 1 : cursor.x

        // The row's raw cells in one call. Most cells are plain text in the
        // default colors, and those need nothing more: only a styled cell, a
        // colored blank or a grapheme cluster asks the render state for its
        // colors, style or text.
        var cells = rowCells
        ghostty_render_state_row_get(rowIterator, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &cells)
        var view = GhosttyCellsView()
        guard ghostty_render_state_row_get(rowIterator, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS_RAW, &view) == GHOSTTY_SUCCESS,
              let raw = view.ptr else { return }

        let layout = CellLayout.current
        // Text in one style comes in runs; a run's colors are asked for once.
        // (Style ids belong to the page a row is on, so only within a row.)
        var run: (style: UInt64, flags: UInt16, underline: UInt32?, foreground: UInt32, background: UInt32?)?
        for x in 0..<view.len {
            let cell = raw[x]
            var wide = GHOSTTY_CELL_WIDE_NARROW
            var content = GHOSTTY_CELL_CONTENT_CODEPOINT
            var styled = false
            var codepoint: UInt32 = 0
            if let layout {
                wide = GhosttyCellWide(rawValue: UInt32(layout.wide(cell)))
                content = GhosttyCellContentTag(rawValue: UInt32(layout.contentTag(cell)))
                styled = layout.styleID(cell) != 0 // style 0 is the default
                codepoint = UInt32(layout.codepoint(cell))
            } else {
                ghostty_cell_get(cell, GHOSTTY_CELL_DATA_WIDE, &wide)
                ghostty_cell_get(cell, GHOSTTY_CELL_DATA_CONTENT_TAG, &content)
                ghostty_cell_get(cell, GHOSTTY_CELL_DATA_HAS_STYLING, &styled)
                ghostty_cell_get(cell, GHOSTTY_CELL_DATA_CODEPOINT, &codepoint)
            }
            // The second half of a wide character is drawn by the first.
            if wide == GHOSTTY_CELL_WIDE_SPACER_TAIL { continue }
            let span = wide == GHOSTTY_CELL_WIDE_WIDE ? 2 : 1
            let plain = !styled && content == GHOSTTY_CELL_CONTENT_CODEPOINT

            var flags: UInt16 = 0
            var underlineColor: UInt32?
            var foreground = colors.foreground
            var background: UInt32?
            let style = layout.map { $0.styleID(cell) } ?? 0
            if styled, content == GHOSTTY_CELL_CONTENT_CODEPOINT, style != 0, let run, run.style == style {
                (flags, underlineColor, foreground, background) = (run.flags, run.underline, run.foreground, run.background)
            } else if !plain {
                ghostty_render_state_row_cells_select(rowCells, UInt16(x))
                if styled {
                    var attributes = GhosttyStyle()
                    ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &attributes)
                    flags = attributes.flags
                    if attributes.underline_color.tag == UInt8(GHOSTTY_STYLE_COLOR_RGB.rawValue) {
                        underlineColor = Self.pack(attributes.underline_color.value.rgb)
                    }
                }
                var color = GhosttyColorRgb()
                if styled, ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, &color) == GHOSTTY_SUCCESS {
                    foreground = Self.pack(color)
                }
                if ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &color) == GHOSTTY_SUCCESS {
                    background = Self.pack(color)
                }
                if styled, content == GHOSTTY_CELL_CONTENT_CODEPOINT, style != 0 {
                    run = (style, flags, underlineColor, foreground, background)
                }
            }
            if flags & StyleFlag.inverse != 0 {
                (foreground, background) = (background ?? colors.background, foreground)
            }
            if hasSelection, x >= Int(selection.start_x), x <= Int(selection.end_x) {
                background = selectionColor
            }
            if blockCursor, x == cursorColumn {
                foreground = background ?? colors.background
                background = colors.cursor
            }
            if flags & StyleFlag.faint != 0 {
                foreground = foreground & 0x00FF_FFFF | 0x8000_0000
            }

            let left = padding + x * m.cellWidth
            let width = span * m.cellWidth
            if let background {
                // Extend the previous run when it is the same color and adjacent.
                if let last = row.backgrounds.indices.last, row.backgrounds[last].color == background,
                   Int(row.backgrounds[last].x) + Int(row.backgrounds[last].width) == left {
                    row.backgrounds[last].width += UInt16(width)
                } else {
                    row.backgrounds.append(Instance(
                        x: Int16(left), y: Int16(top), width: UInt16(width), height: UInt16(m.cellHeight), color: background))
                }
            }

            if flags & StyleFlag.invisible == 0 {
                let bold = flags & StyleFlag.bold != 0, italic = flags & StyleFlag.italic != 0
                var entry = GlyphAtlas.Entry()
                if content == GHOSTTY_CELL_CONTENT_CODEPOINT {
                    if codepoint != 0, codepoint != 0x20 {
                        entry = atlas.entry(codepoint: codepoint, bold: bold, italic: italic, span: span)
                    }
                } else if content == GHOSTTY_CELL_CONTENT_CODEPOINT_GRAPHEME {
                    var graphemes = GhosttyCodepointBuffer(ptr: codepoints, cap: Self.clusterCapacity, len: 0)
                    ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF, &graphemes)
                    let count = min(graphemes.len, Self.clusterCapacity)
                    if count > 0 {
                        entry = atlas.entry(
                            codepoints: UnsafeBufferPointer(start: codepoints, count: count), bold: bold, italic: italic, span: span)
                    }
                }
                if entry.width > 0 {
                    row.glyphs.append(Instance(
                        x: Int16(left + Int(entry.offsetX)), y: Int16(top + Int(entry.offsetY)),
                        width: entry.width, height: entry.height, u: entry.u, v: entry.v,
                        mode: entry.isColor ? 2 : 1, color: foreground))
                }
            }

            let underline = (flags & StyleFlag.underlineMask) >> StyleFlag.underlineShift
            if flags & StyleFlag.decorationMask != 0 {
                func line(at offset: Int, _ lineColor: UInt32) {
                    row.decorations.append(Instance(
                        x: Int16(left), y: Int16(top + offset), width: UInt16(width), height: UInt16(m.thickness), color: lineColor))
                }
                if underline != 0 {
                    // ponytail: curly, dotted and dashed underlines are drawn as
                    // plain lines; draw real shapes when a program relies on them.
                    line(at: m.underlineOffset, underlineColor ?? foreground)
                    if underline == 2 { line(at: max(0, m.underlineOffset - 2 * m.thickness), underlineColor ?? foreground) }
                }
                if flags & StyleFlag.strikethrough != 0 { line(at: m.strikeOffset, foreground) }
                if flags & StyleFlag.overline != 0 { line(at: 0, foreground) }
            }
        }
    }

    /// Things drawn over the grid that aren't worth caching per row.
    private func buildExtras(overlay: Overlay) {
        extras.removeAll(keepingCapacity: true)
        guard cursor.y >= 0, cursor.x >= 0 else { return }
        let m = atlas.metrics
        let column = cursor.wideTail ? cursor.x - 1 : cursor.x
        let left = padding + column * m.cellWidth
        let top = padding + cursor.y * m.cellHeight
        let width = (cursor.wideTail ? 2 : 1) * m.cellWidth
        func rect(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ color: UInt32) {
            extras.append(Instance(x: Int16(x), y: Int16(y), width: UInt16(max(0, w)), height: UInt16(max(0, h)), color: color))
        }

        if !overlay.preedit.isEmpty {
            // Text being composed by the input method, shown where it will land.
            var x = left
            for character in overlay.preedit {
                let scalars = character.unicodeScalars.map(\.value)
                var cellSpan: UInt8 = 1
                _ = ghostty_unicode_grapheme_width(scalars, scalars.count, &cellSpan)
                let span = max(1, Int(cellSpan))
                rect(x, top, span * m.cellWidth, m.cellHeight, palette.background)
                let entry = scalars.withUnsafeBufferPointer {
                    atlas.entry(codepoints: $0, bold: false, italic: false, span: span)
                }
                if entry.width > 0 {
                    extras.append(Instance(
                        x: Int16(x + Int(entry.offsetX)), y: Int16(top + Int(entry.offsetY)),
                        width: entry.width, height: entry.height, u: entry.u, v: entry.v,
                        mode: entry.isColor ? 2 : 1, color: palette.foreground))
                }
                rect(x, top + m.underlineOffset, span * m.cellWidth, m.thickness, palette.foreground)
                x += span * m.cellWidth
            }
            rect(x, top, max(2, m.thickness), m.cellHeight, palette.cursor)
            return
        }

        let t = max(2, m.thickness)
        if !overlay.focused {
            rect(left, top, width, t, palette.cursor)
            rect(left, top + m.cellHeight - t, width, t, palette.cursor)
            rect(left, top, t, m.cellHeight, palette.cursor)
            rect(left + width - t, top, t, m.cellHeight, palette.cursor)
            return
        }
        switch cursor.style {
        case GHOSTTY_CURSOR_STYLE_BAR.rawValue: rect(left, top, t, m.cellHeight, palette.cursor)
        case GHOSTTY_CURSOR_STYLE_UNDERLINE.rawValue: rect(left, top + m.cellHeight - t, width, t, palette.cursor)
        case GHOSTTY_CURSOR_STYLE_BLOCK_HOLLOW.rawValue:
            rect(left, top, width, t, palette.cursor)
            rect(left, top + m.cellHeight - t, width, t, palette.cursor)
            rect(left, top, t, m.cellHeight, palette.cursor)
            rect(left + width - t, top, t, m.cellHeight, palette.cursor)
        default: break // block: baked into the row
        }
    }

    // MARK: Drawing

    func draw(to layer: CAMetalLayer) {
        let size = layer.drawableSize
        guard size.width >= 1, size.height >= 1, let drawable = layer.nextDrawable() else { return }

        var count = extras.count
        for row in rows { count += row.backgrounds.count + row.glyphs.count + row.decorations.count }
        let stride = MemoryLayout<Instance>.stride
        bufferIndex = (bufferIndex + 1) % buffers.count
        if count > 0, (buffers[bufferIndex]?.length ?? 0) < count * stride {
            buffers[bufferIndex] = context.device.makeBuffer(
                length: max(4096, count * stride * 3 / 2), options: .storageModeShared)
        }
        if count > 0, let buffer = buffers[bufferIndex] {
            var destination = buffer.contents()
            func copy(_ instances: [Instance]) {
                guard !instances.isEmpty else { return }
                instances.withUnsafeBytes { destination.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
                destination += instances.count * stride
            }
            // Layer by layer, so a tall glyph is never hidden by the
            // background of the row below it.
            for row in rows { copy(row.backgrounds) }
            for row in rows { copy(row.glyphs) }
            for row in rows { copy(row.decorations) }
            copy(extras)
        }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let bg = palette.background
        pass.colorAttachments[0].clearColor = MTLClearColor(
            red: Double(bg & 0xFF) / 255, green: Double((bg >> 8) & 0xFF) / 255,
            blue: Double((bg >> 16) & 0xFF) / 255, alpha: 1)

        guard let commands = context.queue.makeCommandBuffer(),
              let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        if count > 0, let buffer = buffers[bufferIndex] {
            var viewport = SIMD2<Float>(Float(size.width), Float(size.height))
            encoder.setRenderPipelineState(context.pipeline)
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.setVertexBytes(&viewport, length: MemoryLayout<SIMD2<Float>>.size, index: 1)
            encoder.setFragmentTexture(atlas.grayTexture, index: 0)
            encoder.setFragmentTexture(atlas.colorTexture ?? atlas.grayTexture, index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: count)
        }
        encoder.endEncoding()
        commands.present(drawable)
        commands.commit()
    }
}

/// `GhosttyStyle.flags` bits. The header defines these as casting macros,
/// which Swift does not import.
private enum StyleFlag {
    static let bold: UInt16 = 1 << 0
    static let italic: UInt16 = 1 << 1
    static let faint: UInt16 = 1 << 2
    static let inverse: UInt16 = 1 << 4
    static let invisible: UInt16 = 1 << 5
    static let strikethrough: UInt16 = 1 << 6
    static let overline: UInt16 = 1 << 7
    static let underlineShift: UInt16 = 8
    static let underlineMask: UInt16 = 0x7 << 8
    /// Anything drawn as a line: underline, strikethrough, overline.
    static let decorationMask: UInt16 = underlineMask | strikethrough | overline
}

/// Where a GhosttyCell keeps the fields a frame needs, read once from the
/// library's own description of the layout (`ghostty_type_json`, which the
/// header recommends where a call per field costs too much: four calls a
/// cell were a large part of building a frame). Nil if the description
/// lacks them; cells are then read with `ghostty_cell_get`.
struct CellLayout {
    struct Field {
        let shift: UInt64
        let mask: UInt64
        func callAsFunction(_ cell: GhosttyCell) -> UInt64 { (cell >> shift) & mask }
    }

    let contentTag: Field
    let codepoint: Field
    let styleID: Field
    let wide: Field

    static let current: CellLayout? = {
        guard let json = ghostty_type_json(),
              let root = try? JSONSerialization.jsonObject(with: Data(String(cString: json).utf8)) as? [String: Any],
              let types = root["types"] as? [String: Any], let cell = types["GhosttyCell"] as? [String: Any],
              let bits = cell["bits"] as? [String: [String: Any]] else { return nil }
        func field(_ spec: [String: Any]?, offset: Int = 0) -> Field? {
            guard let lsb = spec?["lsb"] as? Int, let width = spec?["width"] as? Int, width < 64 else { return nil }
            return Field(shift: UInt64(lsb + offset), mask: (1 << UInt64(width)) - 1)
        }
        let content = bits["content"]
        let arms = content?["arms"] as? [String: [String: Any]]
        let codepoint = (arms?["CODEPOINT"]?["bits"] as? [String: [String: Any]])?["codepoint"]
        guard let contentLSB = content?["lsb"] as? Int,
              let tag = field(bits["content_tag"]), let cp = field(codepoint, offset: contentLSB),
              let style = field(bits["style_id"]), let wide = field(bits["wide"]) else { return nil }
        return CellLayout(contentTag: tag, codepoint: cp, styleID: style, wide: wide)
    }()
}
