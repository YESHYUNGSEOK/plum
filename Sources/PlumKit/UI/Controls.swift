import AppKit
import SwiftUI

/// Plum's timings, kept short: the UI should answer, not perform.
enum Motion {
    /// A pointer moving over something.
    static let hover = Animation.easeOut(duration: 0.12)
    /// A selection or state settling.
    static let settle = Animation.easeOut(duration: 0.18)
    /// Rows arriving, leaving, or moving. Nil when the user asked for less motion.
    static func layout(_ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.2)
    }
}

/// Buttons in Plum's own sheets and panels.
struct PlumButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, danger, ghost }
    var kind: Kind = .secondary
    var height: CGFloat = 30

    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration, kind: kind, height: height)
    }

    private struct Styled: View {
        let configuration: Configuration
        let kind: Kind
        let height: CGFloat
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: kind == .primary || kind == .danger ? .semibold : .regular))
                .lineLimit(1)
                .padding(.horizontal, kind == .ghost ? 8 : 14)
                .frame(height: height)
                .foregroundStyle(kind == .ghost && hovering && isEnabled ? Theme.text : foreground)
                .background(RoundedRectangle(cornerRadius: 8).fill(background))
                .overlay(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(hovering && isEnabled ? 0.07 : 0)))
                .contentShape(Rectangle())
                .opacity(!isEnabled ? 0.45 : configuration.isPressed ? 0.75 : 1)
                .onHover { hovering = $0 }
                .animation(Motion.hover, value: hovering)
                .animation(Motion.hover, value: configuration.isPressed)
        }

        private var foreground: Color {
            switch kind {
            case .primary: Theme.onAccent
            case .secondary: Theme.text
            case .danger: Theme.danger
            case .ghost: Theme.secondary
            }
        }

        private var background: Color {
            switch kind {
            case .primary: Theme.accent
            case .secondary: Theme.control
            case .danger: Theme.danger.opacity(0.14)
            case .ghost: .clear
            }
        }
    }
}

/// A key shown as a small cap, e.g. ↵ next to the button it presses.
struct KeyHint: View {
    let key: String
    init(_ key: String) { self.key = key }

    var body: some View {
        Text(key)
            .font(.system(size: 11))
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 17)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color(hex: 0x2A2A30)))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color(hex: 0x36363C)))
            .foregroundStyle(Theme.secondary)
            .accessibilityHidden(true)
    }
}

/// The key that presses a button, shown faintly inside its label.
struct ButtonKey: View {
    let key: String
    init(_ key: String) { self.key = key }

    var body: some View {
        Text(key).font(.system(size: 11, weight: .medium)).opacity(0.65).accessibilityHidden(true)
    }
}

struct SectionLabel: View {
    let text: LocalizedStringKey
    init(_ text: LocalizedStringKey) { self.text = text }

    var body: some View {
        Text(text).font(.system(size: 11, weight: .semibold)).tracking(0.5).foregroundStyle(Theme.tertiary)
    }
}

extension View {
    /// The dark, rounded well that text fields and editors sit in.
    func fieldWell(focused: Bool, height: CGFloat? = 32) -> some View {
        padding(.horizontal, 10)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.well))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(focused ? Theme.accent : Theme.fieldBorder))
    }
}

/// A text field with its label above it.
struct PlumField: View {
    let label: LocalizedStringKey
    @Binding var text: String
    var prompt: LocalizedStringKey = ""
    var mono = false
    var hint: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 12)).foregroundStyle(Theme.secondary).accessibilityHidden(true)
            TextField(label, text: $text, prompt: Text(prompt).foregroundColor(Theme.tertiary))
                .textFieldStyle(.plain)
                .font(mono ? .system(size: 12.5, design: .monospaced) : .system(size: 13))
                .foregroundStyle(Theme.text)
                .focused($focused)
                .fieldWell(focused: focused)
            if let hint {
                Text(hint).font(.system(size: 11.5)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// An agent state told by shape as well as color, so the three read apart
/// without color: a turning arc (working), a pulsing dot (waiting), a check (done).
struct StatusMark: View {
    let status: AgentStatus

    var body: some View {
        StatusMarkLayer(status: status)
            .frame(width: 12, height: 12)
            .accessibilityElement()
            .accessibilityLabel(status.label)
            .accessibilityHidden(status == .idle)
            .help(status.label)
    }
}

/// Core Animation runs the motion in the render server, so a turning arc
/// costs the app no redraws.
private struct StatusMarkLayer: NSViewRepresentable {
    let status: AgentStatus
    func makeNSView(context: Context) -> StatusMarkView { StatusMarkView() }
    func updateNSView(_ view: StatusMarkView, context: Context) { view.status = status }
}

final class StatusMarkView: NSView {
    var status: AgentStatus = .idle {
        didSet {
            guard status != oldValue else { return }
            // One state fades into the next instead of blinking over.
            if window != nil {
                let fade = CATransition()
                fade.duration = 0.18
                layer?.add(fade, forKey: "fade")
            }
            rebuild()
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        rebuild()
    }

    private func rebuild() {
        guard let layer else { return }
        layer.sublayers?.forEach { $0.removeFromSuperlayer() }
        let box = bounds
        guard box.width > 0, status != .idle else { return }
        let color = NSColor(status.color).cgColor
        let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let unit = box.width / 12

        func shape(_ path: CGPath, fill: CGColor? = nil, stroke: CGColor? = nil, width: CGFloat = 0) -> CAShapeLayer {
            let shape = CAShapeLayer()
            shape.frame = box
            shape.path = path
            shape.fillColor = fill
            shape.strokeColor = stroke
            shape.lineWidth = width
            shape.lineCap = .round
            shape.lineJoin = .round
            layer.addSublayer(shape)
            return shape
        }
        func repeating(_ keyPath: String, from: Any, to: Any, duration: Double, reverses: Bool) -> CABasicAnimation {
            let animation = CABasicAnimation(keyPath: keyPath)
            animation.fromValue = from
            animation.toValue = to
            animation.duration = duration
            animation.autoreverses = reverses
            animation.repeatCount = .infinity
            animation.isRemovedOnCompletion = false
            return animation
        }

        switch status {
        case .idle:
            return
        case .working:
            let ring = CGPath(ellipseIn: box.insetBy(dx: unit * 1.5, dy: unit * 1.5), transform: nil)
            _ = shape(ring, stroke: NSColor(status.color).withAlphaComponent(0.3).cgColor, width: unit * 2)
            let arc = shape(ring, stroke: color, width: unit * 2)
            arc.strokeEnd = 0.28
            if !still { arc.add(repeating("transform.rotation.z", from: 0, to: -2 * Double.pi, duration: 0.9, reverses: false), forKey: "spin") }
        case .waiting:
            let halo = shape(CGPath(ellipseIn: box.insetBy(dx: unit * 0.5, dy: unit * 0.5), transform: nil),
                             fill: NSColor(status.color).withAlphaComponent(0.28).cgColor)
            _ = shape(CGPath(ellipseIn: box.insetBy(dx: unit * 3, dy: unit * 3), transform: nil), fill: color)
            if !still { halo.add(repeating("opacity", from: 1, to: 0.25, duration: 0.8, reverses: true), forKey: "pulse") }
        case .done:
            let check = CGMutablePath()
            check.move(to: CGPoint(x: unit * 2.3, y: unit * 6.1))
            check.addLine(to: CGPoint(x: unit * 4.9, y: unit * 3.4))
            check.addLine(to: CGPoint(x: unit * 9.8, y: unit * 8.8))
            _ = shape(check, stroke: color, width: unit * 2)
        }
    }
}

/// An error, shown at the bottom of the panel without blocking anything.
/// Its controller slides it in and out.
struct ToastView: View {
    var message = ""
    var close: () -> Void = {}

    var body: some View {
        if !message.isEmpty {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.danger)
                    .padding(.top, 1)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("문제가 생겼습니다").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).frame(width: 20, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.secondary)
                .accessibilityLabel("알림 닫기")
            }
            .padding(12)
            .frame(width: 320, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(hex: 0x26262C)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.1)))
            .shadow(color: .black.opacity(0.45), radius: 14, y: 6)
            .padding(14)
            .environment(\.colorScheme, .dark)
        }
    }
}
