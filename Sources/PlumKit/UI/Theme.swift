import AppKit
import SwiftUI

/// The app's look: a dark gray ground, a darker terminal panel floating on
/// it, and one accent color, the user's choice. Terminal colors live in
/// `TerminalTheme`.
enum Theme {
    /// Set from the settings; the accent colors below read it.
    static var accentChoice = AccentChoice.plum

    static let backdrop = NSColor(hex: 0x232327)
    static let panel = NSColor(hex: 0x1A1A1D)
    static let panelColor = Color(nsColor: panel)

    static let text = Color(hex: 0xECECEF)
    /// The selected row's and the open tab's name: the strongest text.
    static let strongText = Color(hex: 0xFFFFFF)
    static let rowText = Color(hex: 0xD0D0D6)
    static let secondary = Color(hex: 0xA0A0AB)
    static let tertiary = Color(nsColor: tertiaryNS)
    static var accentNS: NSColor { accentChoice.color }
    static var accent: Color { Color(nsColor: accentNS) }
    static var selectedRow: Color { Color(nsColor: accentNS.withAlphaComponent(0.2)) }
    static let hoveredRow = Color(hex: 0xFFFFFF, opacity: 0.05)
    /// A highlighted menu row, a pressed control.
    static let highlight = Color(hex: 0xFFFFFF, opacity: 0.08)
    /// Thin lines: card edges, separators in menus.
    static let hairline = Color(hex: 0xFFFFFF, opacity: 0.08)
    static let selectedTab = Color(hex: 0x2E2E34)
    static let divider = Color(hex: 0x2E2E33)
    static let chip = Color(hex: 0x26262B)
    /// The strip the tabs sit in, and the branch name in it.
    static let tabBar = Color(hex: 0x111113)
    static let tabBarChip = Color(hex: 0x1C1C20)
    /// An empty ring: a tab with no state yet.
    static let ring = Color(hex: 0x4A4A52)

    // Plum's own sheets and overlays.
    static let card = Color(hex: 0x1F1F23)
    static let menu = Color(hex: 0x1E1E22)
    static let toast = Color(hex: 0x26262C)
    static let well = Color(hex: 0x141416)
    static let control = Color(hex: 0x2E2E35)
    static let focusRow = Color(hex: 0x28282E)
    static let fieldBorder = Color(hex: 0x34343A)
    static let keycap = Color(hex: 0x2A2A30)
    static let keycapBorder = Color(hex: 0x36363C)
    static let onAccent = Color(hex: 0x17131C)
    static let danger = Color(hex: 0xFF8E8E)
    /// Text drawn as the terminal draws it (previews, diffs).
    static let terminalText = Color(hex: 0xDCDCE2)

    static let workingNS = NSColor(hex: 0x7CB7FF)
    static let monitoringNS = NSColor(hex: 0x6FD1C6)
    static let waitingNS = NSColor(hex: 0xF5B453)
    static let doneNS = NSColor(hex: 0x7BD88F)
    static let working = Color(nsColor: workingNS)
    static let monitoring = Color(nsColor: monitoringNS)
    static let waiting = Color(nsColor: waitingNS)
    static let done = Color(nsColor: doneNS)
    static let tertiaryNS = NSColor(hex: 0x8E8E99)

    static let shadowOpacity = 0.4

    static let sidebarWidth: CGFloat = 236
    static let panelRadius: CGFloat = 14
}

extension AccentChoice {
    var color: NSColor {
        switch self {
        case .plum: NSColor(hex: 0xC58AF9)
        case .blue: NSColor(hex: 0x7CB2FF)
        case .green: NSColor(hex: 0x6FD49A)
        case .orange: NSColor(hex: 0xFFAA5C)
        case .pink: NSColor(hex: 0xFF8FC4)
        case .graphite: NSColor(hex: 0xB4B4BE)
        }
    }
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
