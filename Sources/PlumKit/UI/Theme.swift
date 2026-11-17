import AppKit
import SwiftUI

/// The app's look: a dark gray ground, a darker terminal panel floating on
/// it, and one plum accent. Terminal colors live in `TerminalTheme`.
enum Theme {
    static let backdrop = NSColor(hex: 0x232327)
    static let panel = NSColor(hex: 0x1A1A1D)
    static let panelColor = Color(hex: 0x1A1A1D)

    static let text = Color(hex: 0xECECEF)
    static let rowText = Color(hex: 0xD0D0D6)
    static let secondary = Color(hex: 0xA0A0AB)
    static let tertiary = Color(hex: 0x8E8E99)
    static let accent = Color(hex: 0xC58AF9)
    static let selectedRow = Color(hex: 0xC58AF9, opacity: 0.2)
    static let hoveredRow = Color.white.opacity(0.05)
    static let selectedTab = Color(hex: 0x2E2E34)
    static let divider = Color(hex: 0x2E2E33)
    static let chip = Color(hex: 0x26262B)

    // Plum's own sheets and overlays.
    static let card = Color(hex: 0x1F1F23)
    static let well = Color(hex: 0x141416)
    static let control = Color(hex: 0x2E2E35)
    static let fieldBorder = Color(hex: 0x34343A)
    static let onAccent = Color(hex: 0x17131C)
    static let danger = Color(hex: 0xFF8E8E)

    static let working = Color(hex: 0x7CB7FF)
    static let waiting = Color(hex: 0xF5B453)
    static let done = Color(hex: 0x7BD88F)

    static let sidebarWidth: CGFloat = 236
    static let panelRadius: CGFloat = 14
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
