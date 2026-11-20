#!/bin/zsh
# Makes Resources/AppIcon.icns: the README's plum on a dark square
# (PlumIconView in scripts/icon/AsciiPlum.swift), drawn at every icon size.
set -euo pipefail
ROOT=${0:A:h:h}
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/main.swift" <<'SWIFT'
import AppKit
extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
MainActor.assumeIsolated {
    let folder = CommandLine.arguments[1]
    for points in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let pixels = points * scale
            let view = PlumIconView(frame: NSRect(x: 0, y: 0, width: pixels, height: pixels))
            // A bitmap of exactly that many pixels, whatever the screen's scale.
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            rep.size = view.bounds.size
            view.cacheDisplay(in: view.bounds, to: rep)
            let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
            try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(folder)/\(name)"))
        }
    }
}
SWIFT
swiftc -O -o "$TMP/icon" "$ROOT/scripts/icon/AsciiPlum.swift" "$ROOT/scripts/icon/AsciiPlumFrames.swift" "$TMP/main.swift"
mkdir "$TMP/AppIcon.iconset"
"$TMP/icon" "$TMP/AppIcon.iconset"
iconutil -c icns -o "$ROOT/Resources/AppIcon.icns" "$TMP/AppIcon.iconset"
echo "$ROOT/Resources/AppIcon.icns"
