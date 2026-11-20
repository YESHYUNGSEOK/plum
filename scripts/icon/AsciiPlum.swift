import AppKit

/// The README's ASCII plum, small, for the app icon (scripts/make-icon.sh).
/// The frames are made by scripts/readme-plum.py, in AsciiPlumFrames.swift.
struct AsciiPlum {
    struct Run {
        let column: Int
        let text: String
        let color: NSColor
    }

    let cols: Int
    let rows: Int
    /// Frame, then row, then runs of one color.
    let frames: [[[Run]]]

    init(cols: Int, rows: Int, palette: [UInt32], text: String) {
        let colors = palette.map { NSColor(hex: $0) }
        let codes = Array("0123456789abcdefghijklmnopqrstuvwxyz")
        let lines = text.split(separator: "\n").map { line -> [Run] in
            let halves = line.split(separator: "\t", omittingEmptySubsequences: false)
            var runs: [Run] = []
            var start = 0, chars = "", code: Character = "."
            for (column, (ch, c)) in zip(halves[0], halves[1]).enumerated() {
                if c != code || c == "." {
                    if code != ".", let i = codes.firstIndex(of: code) { runs.append(Run(column: start, text: chars, color: colors[i])) }
                    start = column
                    chars = ""
                    code = c
                }
                chars.append(ch)
            }
            if code != ".", let i = codes.firstIndex(of: code) { runs.append(Run(column: start, text: chars, color: colors[i])) }
            return runs
        }
        self.cols = cols
        self.rows = rows
        frames = stride(from: 0, to: lines.count, by: rows).map { Array(lines[$0..<$0 + rows]) }
    }

    /// Draws a frame as large as fits in `rect`, centered, into the current
    /// graphics context, which must be flipped.
    func draw(frame index: Int, in rect: CGRect) {
        let cell = min(rect.width / CGFloat(cols), rect.height / CGFloat(rows * 2)) // a cell is twice as tall as wide
        let size = cell / 0.602 // Menlo's advance is 0.602 em
        let font = NSFont(name: "Menlo", size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        let left = rect.midX - cell * CGFloat(cols) / 2
        let top = rect.midY - cell * CGFloat(rows) + (cell * 2 - font.ascender + font.descender) / 2
        for (row, runs) in frames[index % frames.count].enumerated() {
            for run in runs {
                NSAttributedString(string: run.text, attributes: [.font: font, .foregroundColor: run.color])
                    .draw(at: CGPoint(x: left + CGFloat(run.column) * cell, y: top + CGFloat(row) * cell * 2))
            }
        }
    }
}

/// Plum's icon: the plum on a dark square, larger than the square and cut
/// off by it, at an angle where neither leaf nor stem shows.
final class PlumIconView: NSView {
    static let frameIndex = 32

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        // A macOS icon's square: 824 of 1024, corners 185.
        let side = min(bounds.width, bounds.height)
        let square = bounds.insetBy(dx: side * 100 / 1024, dy: side * 100 / 1024)
        let shape = NSBezierPath(roundedRect: square, xRadius: side * 185 / 1024, yRadius: side * 185 / 1024)
        NSColor(hex: 0x0E0B12).setFill()
        shape.fill()
        // Toward the square's top right, cut off by its edge, with room at the bottom left.
        shape.addClip()
        let size = square.width * 1.5
        AsciiPlum.shared.draw(frame: Self.frameIndex, in: CGRect(
            x: square.midX - size / 2 + side * 0.11, y: square.midY - size / 2 - side * 0.13, width: size, height: size))
    }
}
