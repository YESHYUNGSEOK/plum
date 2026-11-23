import AppKit
import CoreText
import Metal

/// Cell geometry in device pixels, derived from the font.
public struct CellMetrics: Equatable {
    public var cellWidth: Int
    public var cellHeight: Int
    /// Distance from the top of a cell to the text baseline.
    public var baseline: Int
    public var underlineOffset: Int
    public var strikeOffset: Int
    public var thickness: Int
}

public struct FontSpec: Hashable {
    /// PostScript or family name. Empty means the system monospaced font.
    public var name: String
    public var pointSize: Double
    public var scale: Double

    public init(name: String, pointSize: Double, scale: Double) {
        self.name = name
        self.pointSize = pointSize
        self.scale = scale
    }
}

extension FontSpec {
    /// The font a name stands for: a PostScript, full or family name. A name
    /// nothing matches gives the system monospaced font, not the proportional
    /// font Core Text would otherwise substitute.
    public static func font(named name: String, size: CGFloat) -> CTFont {
        let system = NSFont.monospacedSystemFont(ofSize: size, weight: .regular) as CTFont
        guard !name.isEmpty else { return system }
        let named = CTFontCreateWithName(name as CFString, size, nil)
        let names = [CTFontCopyPostScriptName(named), CTFontCopyFullName(named), CTFontCopyFamilyName(named)]
        if names.contains(where: { ($0 as String) == name }) { return named }
        let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: name] as CFDictionary)
        let family = CTFontCreateWithFontDescriptor(descriptor, size, nil)
        return (CTFontCopyFamilyName(family) as String) == name ? family : system
    }

    /// Families of the installed fixed-width fonts, by name. Takes a moment:
    /// call off the main thread.
    public static func monospacedFamilies() -> [String] {
        let collection = CTFontCollectionCreateFromAvailableFonts(nil)
        let descriptors = CTFontCollectionCreateMatchingFontDescriptors(collection) as? [CTFontDescriptor] ?? []
        var families = Set<String>()
        for descriptor in descriptors {
            let traits = CTFontDescriptorCopyAttribute(descriptor, kCTFontTraitsAttribute) as? [CFString: Any]
            let symbolic = (traits?[kCTFontSymbolicTrait] as? NSNumber)?.uint32Value ?? 0
            guard symbolic & CTFontSymbolicTraits.traitMonoSpace.rawValue != 0,
                  let family = CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String,
                  !family.hasPrefix(".") // system-private faces
            else { continue }
            families.insert(family)
        }
        return families.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

/// Rasterizes glyphs with CoreText into textures shared by every terminal
/// that uses the same font. Main thread only.
final class GlyphAtlas {
    struct Entry {
        var u: UInt16 = 0
        var v: UInt16 = 0
        var width: UInt16 = 0 // 0 = nothing to draw
        var height: UInt16 = 0
        var offsetX: Int16 = 0 // from the cell's left edge
        var offsetY: Int16 = 0 // from the cell's top edge
        var isColor = false
    }

    let metrics: CellMetrics
    private(set) var grayTexture: MTLTexture
    private(set) var colorTexture: MTLTexture?
    /// Bumped when the atlas is emptied; cached entries from before are stale.
    private(set) var generation = 0

    private let device: MTLDevice
    private let fonts: [CTFont] // indexed by (bold ? 1 : 0) | (italic ? 2 : 0)
    private var single: [UInt64: Entry] = [:]
    /// ASCII in each face and width, the bulk of most screens: found by
    /// index, without hashing (a dictionary lookup per glyph was the largest
    /// cost of building a frame).
    private var ascii = [Entry?](repeating: nil, count: 128 * 8)
    /// Other codepoints (box drawing, Hangul, symbols) found again by a
    /// cheap hash before the dictionary, which hashes far more slowly.
    /// Direct-mapped: a collision only means a trip to the dictionary.
    private static let recentSlots = 4096
    private var recentKeys = [UInt64](repeating: .max, count: recentSlots)
    private var recentEntries = [Entry](repeating: Entry(), count: recentSlots)
    private var clusters: [String: Entry] = [:]
    // Start small: most sessions never need more than a few hundred glyphs.
    private var graySize = 1024
    private var colorSize = 512
    private var grayPacker = ShelfPacker(size: 1024)
    private var colorPacker = ShelfPacker(size: 512)
    private let scratch: CGContext

    init(device: MTLDevice, spec: FontSpec) {
        self.device = device
        let size = CGFloat(spec.pointSize * spec.scale)
        let base = FontSpec.font(named: spec.name, size: size)
        func variant(_ traits: CTFontSymbolicTraits) -> CTFont {
            CTFontCreateCopyWithSymbolicTraits(base, size, nil, traits, traits) ?? base
        }
        fonts = [base, variant(.traitBold), variant(.traitItalic), variant([.traitBold, .traitItalic])]

        let ascent = CTFontGetAscent(base)
        let descent = CTFontGetDescent(base)
        let leading = CTFontGetLeading(base)
        var character: UniChar = 0x4D // "M"
        var glyph: CGGlyph = 0
        var advance = CGSize.zero
        CTFontGetGlyphsForCharacters(base, &character, &glyph, 1)
        CTFontGetAdvancesForGlyphs(base, .horizontal, &glyph, &advance, 1)

        let cellWidth = max(1, Int(advance.width.rounded()))
        let cellHeight = max(1, Int((ascent + descent + leading).rounded()))
        let baseline = Int(((CGFloat(cellHeight) - (ascent + descent)) / 2 + ascent).rounded())
        let thickness = max(1, Int(CTFontGetUnderlineThickness(base).rounded()))
        metrics = CellMetrics(
            cellWidth: cellWidth,
            cellHeight: cellHeight,
            baseline: baseline,
            underlineOffset: min(cellHeight - thickness, baseline + max(1, Int((-CTFontGetUnderlinePosition(base)).rounded()))),
            strikeOffset: baseline - Int((CTFontGetXHeight(base) / 2).rounded()),
            thickness: thickness)

        grayTexture = GlyphAtlas.makeTexture(device, .r8Unorm, 1024)
        scratch = CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 1,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    }

    private static func makeTexture(_ device: MTLDevice, _ format: MTLPixelFormat, _ size: Int) -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: size, height: size, mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        return device.makeTexture(descriptor: descriptor)!
    }

    /// The glyph for one codepoint. `span` is how many cells it covers.
    func entry(codepoint: UInt32, bold: Bool, italic: Bool, span: Int) -> Entry {
        let variant = (bold ? 1 : 0) | (italic ? 2 : 0) | (span > 1 ? 4 : 0)
        if codepoint < 128 {
            let index = Int(codepoint) | variant << 7
            if let hit = ascii[index] { return hit }
            let made = rasterize(String(UnicodeScalar(UInt8(codepoint))), variant & 3, span)
            ascii[index] = made
            return made
        }
        let key = UInt64(codepoint) | UInt64(variant) << 32
        let slot = Int(truncatingIfNeeded: (key &* 0x9E37_79B9_7F4A_7C15) >> 52)
        if recentKeys[slot] == key { return recentEntries[slot] }
        let found: Entry
        if let hit = single[key] {
            found = hit
        } else {
            found = UnicodeScalar(codepoint).map { rasterize(String($0), variant & 3, span) } ?? Entry()
            single[key] = found
        }
        recentKeys[slot] = key
        recentEntries[slot] = found
        return found
    }

    /// The glyph for one cell's text. `span` is how many cells it covers.
    func entry(codepoints: UnsafeBufferPointer<UInt32>, bold: Bool, italic: Bool, span: Int) -> Entry {
        let variant = UInt64((bold ? 1 : 0) | (italic ? 2 : 0) | (span > 1 ? 4 : 0))
        if codepoints.count == 1 { return entry(codepoint: codepoints[0], bold: bold, italic: italic, span: span) }
        let key = String(scalars: codepoints) + String(UnicodeScalar(UInt8(48 + variant)))
        if let hit = clusters[key] { return hit }
        let made = rasterize(String(scalars: codepoints), Int(variant & 3), span)
        clusters[key] = made
        return made
    }

    private func rasterize(_ text: String, _ fontIndex: Int, _ span: Int) -> Entry {
        guard !text.isEmpty else { return Entry() }
        if text.unicodeScalars.count == 1, let sprite = sprite(text.unicodeScalars.first!.value, span) { return sprite }
        let attributed = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): fonts[fontIndex],
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        let ink = CTLineGetImageBounds(line, scratch)
        guard ink.width > 0, ink.height > 0, !ink.isInfinite, !ink.isNull else { return Entry() }

        var isColor = false
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let attributes = CTRunGetAttributes(run) as NSDictionary
            if let font = attributes[kCTFontAttributeName as String] {
                if CTFontGetSymbolicTraits(font as! CTFont).contains(.traitColorGlyphs) { isColor = true }
            }
        }

        // Fallback fonts (Hangul, emoji) don't share our cell width. Shrink
        // what is too wide for its cells and center what is too narrow.
        let spanWidth = CGFloat(metrics.cellWidth * span)
        let advance = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        var scale: CGFloat = 1
        var shift: CGFloat = 0
        if advance > spanWidth + 0.5 {
            scale = spanWidth / advance
        } else if advance > 0, advance < spanWidth - 0.5 {
            shift = (spanWidth - advance) / 2
        }

        let minX = (ink.minX * scale + shift).rounded(.down) - 1
        let maxX = (ink.maxX * scale + shift).rounded(.up) + 1
        let minY = (ink.minY * scale).rounded(.down) - 1
        let maxY = (ink.maxY * scale).rounded(.up) + 1
        let width = Int(maxX - minX)
        let height = Int(maxY - minY)
        guard width > 0, height > 0, width <= 512, height <= 512 else { return Entry() }

        guard let context = isColor
            ? CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            : CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return Entry() }

        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        context.setAllowsFontSmoothing(false)
        context.setShouldSmoothFonts(false)
        context.setShouldSubpixelQuantizeFonts(false)
        context.setFillColor(gray: 1, alpha: 1)
        context.translateBy(x: shift - minX, y: -minY)
        context.scaleBy(x: scale, y: scale)
        context.textPosition = .zero
        CTLineDraw(line, context)

        guard let stored = store(context, width, height, isColor) else {
            reset(growColor: isColor)
            return rasterize(text, fontIndex, span)
        }
        var entry = stored
        entry.offsetX = Int16(minX)
        entry.offsetY = Int16(CGFloat(metrics.baseline) - maxY)
        return entry
    }

    /// Copies a finished bitmap into the atlas. Nil when the atlas is full.
    private func store(_ context: CGContext, _ width: Int, _ height: Int, _ isColor: Bool) -> Entry? {
        guard let pixels = context.data, let origin = place(width, height, isColor) else { return nil }
        let texture = isColor ? colorTexture! : grayTexture
        texture.replace(
            region: MTLRegionMake2D(origin.0, origin.1, width, height), mipmapLevel: 0,
            withBytes: pixels, bytesPerRow: context.bytesPerRow)
        return Entry(
            u: UInt16(origin.0), v: UInt16(origin.1), width: UInt16(width), height: UInt16(height), isColor: isColor)
    }

    /// Powerline symbols live in the private-use area, so no system font has
    /// them. Draw the common ones ourselves, exactly one cell tall, so prompt
    /// segments join without gaps.
    private func sprite(_ scalar: UInt32, _ span: Int) -> Entry? {
        guard scalar == 0xE0A0 || (0xE0B0...0xE0B3).contains(scalar) else { return nil }
        let width = metrics.cellWidth * span
        let height = metrics.cellHeight
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        let w = CGFloat(width)
        let h = CGFloat(height)
        let stroke = CGFloat(max(2, metrics.thickness))
        context.setFillColor(gray: 1, alpha: 1)
        context.setStrokeColor(gray: 1, alpha: 1)
        context.setLineWidth(stroke)
        context.setLineJoin(.round)
        context.setLineCap(.round)

        switch scalar {
        case 0xE0B0: // solid right-pointing separator
            context.addLines(between: [CGPoint(x: 0, y: 0), CGPoint(x: w, y: h / 2), CGPoint(x: 0, y: h)])
            context.fillPath()
        case 0xE0B2: // solid left-pointing separator
            context.addLines(between: [CGPoint(x: w, y: 0), CGPoint(x: 0, y: h / 2), CGPoint(x: w, y: h)])
            context.fillPath()
        case 0xE0B1:
            context.addLines(between: [CGPoint(x: 0, y: 0), CGPoint(x: w - stroke / 2, y: h / 2), CGPoint(x: 0, y: h)])
            context.strokePath()
        case 0xE0B3:
            context.addLines(between: [CGPoint(x: w, y: 0), CGPoint(x: stroke / 2, y: h / 2), CGPoint(x: w, y: h)])
            context.strokePath()
        default: // 0xE0A0, the git branch symbol
            let radius = w * 0.16
            let trunk = w * 0.3
            let branch = w * 0.72
            let top = h * 0.74
            let bottom = h * 0.26
            let fork = h * 0.6
            context.move(to: CGPoint(x: trunk, y: top - radius))
            context.addLine(to: CGPoint(x: trunk, y: bottom + radius))
            context.move(to: CGPoint(x: branch, y: fork - radius))
            context.addQuadCurve(to: CGPoint(x: trunk, y: bottom + radius * 2.2), control: CGPoint(x: branch, y: bottom + radius * 2.2))
            context.strokePath()
            for center in [CGPoint(x: trunk, y: top), CGPoint(x: trunk, y: bottom), CGPoint(x: branch, y: fork)] {
                context.strokeEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            }
        }
        if let stored = store(context, width, height, false) { return stored }
        reset(growColor: false)
        return store(context, width, height, false)
    }

    private func place(_ width: Int, _ height: Int, _ isColor: Bool) -> (Int, Int)? {
        if isColor {
            if colorTexture == nil { colorTexture = GlyphAtlas.makeTexture(device, .bgra8Unorm, colorSize) }
            return colorPacker.place(width, height)
        }
        return grayPacker.place(width, height)
    }

    /// A full atlas is emptied and refilled from whatever is on screen, one
    /// size larger if it can still grow.
    /// ponytail: glyphs are re-rasterized rather than copied across, and at
    /// the size cap the atlas just starts over. Evict by last use if a huge
    /// character set ever makes that visible as stutter.
    private func reset(growColor: Bool) {
        if growColor {
            colorSize = min(colorSize * 2, 2048)
            colorTexture = nil
        } else {
            graySize = min(graySize * 2, 4096)
            grayTexture = GlyphAtlas.makeTexture(device, .r8Unorm, graySize)
        }
        single.removeAll(keepingCapacity: true)
        clusters.removeAll(keepingCapacity: true)
        for i in ascii.indices { ascii[i] = nil }
        for i in recentKeys.indices { recentKeys[i] = .max }
        grayPacker = ShelfPacker(size: graySize)
        colorPacker = ShelfPacker(size: colorSize)
        generation += 1
    }
}

private struct ShelfPacker {
    let size: Int
    var x = 1
    var y = 1
    var rowHeight = 0

    init(size: Int) { self.size = size }

    mutating func place(_ width: Int, _ height: Int) -> (Int, Int)? {
        if x + width + 1 > size {
            x = 1
            y += rowHeight + 1
            rowHeight = 0
        }
        guard y + height + 1 <= size, width + 2 <= size else { return nil }
        defer {
            x += width + 1
            rowHeight = max(rowHeight, height)
        }
        return (x, y)
    }
}

private extension String {
    init(scalars: UnsafeBufferPointer<UInt32>) {
        var view = String.UnicodeScalarView()
        for value in scalars {
            view.append(UnicodeScalar(value) ?? "\u{FFFD}")
        }
        self = String(view)
    }
}
