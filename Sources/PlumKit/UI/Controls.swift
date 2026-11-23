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
                .overlay(RoundedRectangle(cornerRadius: 8).fill(hovering && isEnabled ? Theme.highlight : .clear))
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
            .background(RoundedRectangle(cornerRadius: 4).fill(Theme.keycap))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.keycapBorder))
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
    var size: CGFloat = 12

    var body: some View {
        StatusMarkLayer(status: status)
            .frame(width: size, height: size)
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
        guard box.width > 0 else { return }
        let color = status.nsColor.cgColor
        let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        // Drawn on a 16-unit grid, y up. Every state is a ring, told apart
        // by its weight, its fill and its motion as well as its color.
        let unit = box.width / 16
        func circle(_ radius: CGFloat) -> CGPath {
            CGPath(ellipseIn: CGRect(x: box.midX - radius * unit, y: box.midY - radius * unit,
                                     width: 2 * radius * unit, height: 2 * radius * unit), transform: nil)
        }

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
            // A faint ring: an agent with nothing to say.
            _ = shape(circle(5.5), stroke: Theme.tertiaryNS.withAlphaComponent(0.55).cgColor, width: unit * 1.5)
        case .monitoring:
            // A pulse line traced across a faint ring: watching work it
            // started, like a monitor's trace.
            _ = shape(circle(6.25), stroke: status.nsColor.withAlphaComponent(0.35).cgColor, width: unit * 1.4)
            let trace = CGMutablePath()
            let points: [(CGFloat, CGFloat)] = [(3, 7.6), (5.2, 7.6), (6.5, 10.4), (8.5, 5), (9.9, 8.6), (10.8, 7.6), (13, 7.6)]
            trace.addLines(between: points.map { CGPoint(x: unit * $0.0, y: unit * $0.1) })
            let line = shape(trace, stroke: color, width: unit * 1.5)
            if !still {
                // Drawn from the left, then wiped from the left, over and over.
                func sweep(_ keyPath: String, _ values: [Double]) -> CAKeyframeAnimation {
                    let animation = CAKeyframeAnimation(keyPath: keyPath)
                    animation.values = values
                    animation.keyTimes = [0, 0.5, 1]
                    animation.duration = 1.8
                    animation.repeatCount = .infinity
                    animation.isRemovedOnCompletion = false
                    return animation
                }
                line.add(sweep("strokeEnd", [0, 1, 1]), forKey: "draw")
                line.add(sweep("strokeStart", [0, 0, 1]), forKey: "wipe")
            }
        case .working:
            // A gap running round the ring.
            _ = shape(circle(5.5), stroke: status.nsColor.withAlphaComponent(0.25).cgColor, width: unit * 2)
            let arc = shape(circle(5.5), stroke: color, width: unit * 2)
            arc.strokeEnd = 0.25
            if !still { arc.add(repeating("transform.rotation.z", from: 0, to: -2 * Double.pi, duration: 0.9, reverses: false), forKey: "spin") }
        case .waiting:
            // A thick ring, breathing.
            let ring = shape(circle(5), stroke: color, width: unit * 3)
            if !still {
                let breath = repeating("opacity", from: 1, to: 0.35, duration: 0.8, reverses: true)
                breath.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                ring.add(breath, forKey: "pulse")
            }
        case .done:
            // Filled, with a check cut into it.
            _ = shape(circle(6.5), fill: color)
            let check = CGMutablePath()
            check.move(to: CGPoint(x: unit * 5, y: unit * 7.75))
            check.addLine(to: CGPoint(x: unit * 7, y: unit * 5.75))
            check.addLine(to: CGPoint(x: unit * 11, y: unit * 10))
            _ = shape(check, stroke: Theme.panel.cgColor, width: unit * 1.8)
        }
    }
}

/// An error, or how something is going (`isError` false), shown at the
/// bottom of the panel without blocking anything. Its controller slides it in and out.
struct ToastView: View {
    var message = ""
    var isError = true
    var close: () -> Void = {}

    var body: some View {
        if !message.isEmpty {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isError ? "exclamationmark.triangle" : "info.circle")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isError ? Theme.danger : Theme.secondary)
                    .padding(.top, 1)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    if isError {
                        Text("문제가 생겼습니다").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                    }
                    Text(message)
                        .font(.system(size: isError ? 12 : 13))
                        .foregroundStyle(isError ? Theme.secondary : Theme.text)
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
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.toast))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.hairline))
            .shadow(color: .black.opacity(Theme.shadowOpacity), radius: 14, y: 6)
            .padding(14)
        }
    }
}

// MARK: - What a new tab starts

extension TabProgram {
    /// An agent's name as it calls itself; for a plain terminal, "terminal".
    var name: String {
        switch self {
        case .terminal: String(localized: "터미널")
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .terminal: "빈 터미널"
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }

    /// The agents' own marks, as Orca shows them, and a ">_" drawn to match.
    /// Claude and OpenAI paths: Simple Icons 15.22 (CC0), simpleicons.org.
    /// The marks are trademarks of Anthropic and OpenAI.
    private static let icons: [TabProgram: NSImage] = {
        func image(_ body: String) -> NSImage {
            let svg = #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">"# + body + "</svg>"
            let image = NSImage(data: Data(svg.utf8)) ?? NSImage()
            image.size = NSSize(width: 14, height: 14)
            image.isTemplate = false // keep the colors: menus tint template images
            return image
        }
        return [
            .terminal: image(##"<path d="M4.5 7l5 5-5 5M12.5 17.5h7" fill="none" stroke="#A0A0AB" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"/>"##),
            .claude: image(##"<path fill="#D97757" d="m4.7144 15.9555 4.7174-2.6471.079-.2307-.079-.1275h-.2307l-.7893-.0486-2.6956-.0729-2.3375-.0971-2.2646-.1214-.5707-.1215-.5343-.7042.0546-.3522.4797-.3218.686.0608 1.5179.1032 2.2767.1578 1.6514.0972 2.4468.255h.3886l.0546-.1579-.1336-.0971-.1032-.0972L6.973 9.8356l-2.55-1.6879-1.3356-.9714-.7225-.4918-.3643-.4614-.1578-1.0078.6557-.7225.8803.0607.2246.0607.8925.686 1.9064 1.4754 2.4893 1.8336.3643.3035.1457-.1032.0182-.0728-.164-.2733-1.3539-2.4467-1.445-2.4893-.6435-1.032-.17-.6194c-.0607-.255-.1032-.4674-.1032-.7285L6.287.1335 6.6997 0l.9957.1336.419.3642.6192 1.4147 1.0018 2.2282 1.5543 3.0296.4553.8985.2429.8318.091.255h.1579v-.1457l.1275-1.706.2368-2.0947.2307-2.6957.0789-.7589.3764-.9107.7468-.4918.5828.2793.4797.686-.0668.4433-.2853 1.8517-.5586 2.9021-.3643 1.9429h.2125l.2429-.2429.9835-1.3053 1.6514-2.0643.7286-.8196.85-.9046.5464-.4311h1.0321l.759 1.1293-.34 1.1657-1.0625 1.3478-.8804 1.1414-1.2628 1.7-.7893 1.36.0729.1093.1882-.0183 2.8535-.607 1.5421-.2794 1.8396-.3157.8318.3886.091.3946-.3278.8075-1.967.4857-2.3072.4614-3.4364.8136-.0425.0304.0486.0607 1.5482.1457.6618.0364h1.621l3.0175.2247.7892.522.4736.6376-.079.4857-1.2142.6193-1.6393-.3886-3.825-.9107-1.3113-.3279h-.1822v.1093l1.0929 1.0686 2.0035 1.8092 2.5075 2.3314.1275.5768-.3218.4554-.34-.0486-2.2039-1.6575-.85-.7468-1.9246-1.621h-.1275v.17l.4432.6496 2.3436 3.5214.1214 1.0807-.17.3521-.6071.2125-.6679-.1214-1.3721-1.9246L14.38 17.959l-1.1414-1.9428-.1397.079-.674 7.2552-.3156.3703-.7286.2793-.6071-.4614-.3218-.7468.3218-1.4753.3886-1.9246.3157-1.53.2853-1.9004.17-.6314-.0121-.0425-.1397.0182-1.4328 1.9672-2.1796 2.9446-1.7243 1.8456-.4128.164-.7164-.3704.0667-.6618.4008-.5889 2.386-3.0357 1.4389-1.882.929-1.0868-.0062-.1579h-.0546l-6.3385 4.1164-1.1293.1457-.4857-.4554.0608-.7467.2307-.2429 1.9064-1.3114Z"/>"##),
            .codex: image(##"<path fill="#E6E6EA" d="M22.2819 9.8211a5.9847 5.9847 0 0 0-.5157-4.9108 6.0462 6.0462 0 0 0-6.5098-2.9A6.0651 6.0651 0 0 0 4.9807 4.1818a5.9847 5.9847 0 0 0-3.9977 2.9 6.0462 6.0462 0 0 0 .7427 7.0966 5.98 5.98 0 0 0 .511 4.9107 6.051 6.051 0 0 0 6.5146 2.9001A5.9847 5.9847 0 0 0 13.2599 24a6.0557 6.0557 0 0 0 5.7718-4.2058 5.9894 5.9894 0 0 0 3.9977-2.9001 6.0557 6.0557 0 0 0-.7475-7.0729zm-9.022 12.6081a4.4755 4.4755 0 0 1-2.8764-1.0408l.1419-.0804 4.7783-2.7582a.7948.7948 0 0 0 .3927-.6813v-6.7369l2.02 1.1686a.071.071 0 0 1 .038.052v5.5826a4.504 4.504 0 0 1-4.4945 4.4944zm-9.6607-4.1254a4.4708 4.4708 0 0 1-.5346-3.0137l.142.0852 4.783 2.7582a.7712.7712 0 0 0 .7806 0l5.8428-3.3685v2.3324a.0804.0804 0 0 1-.0332.0615L9.74 19.9502a4.4992 4.4992 0 0 1-6.1408-1.6464zM2.3408 7.8956a4.485 4.485 0 0 1 2.3655-1.9728V11.6a.7664.7664 0 0 0 .3879.6765l5.8144 3.3543-2.0201 1.1685a.0757.0757 0 0 1-.071 0l-4.8303-2.7865A4.504 4.504 0 0 1 2.3408 7.872zm16.5963 3.8558L13.1038 8.364 15.1192 7.2a.0757.0757 0 0 1 .071 0l4.8303 2.7913a4.4944 4.4944 0 0 1-.6765 8.1042v-5.6772a.79.79 0 0 0-.407-.667zm2.0107-3.0231l-.142-.0852-4.7735-2.7818a.7759.7759 0 0 0-.7854 0L9.409 9.2297V6.8974a.0662.0662 0 0 1 .0284-.0615l4.8303-2.7866a4.4992 4.4992 0 0 1 6.6802 4.66zM8.3065 12.863l-2.02-1.1638a.0804.0804 0 0 1-.038-.0567V6.0742a4.4992 4.4992 0 0 1 7.3757-3.4537l-.142.0805L8.704 5.459a.7948.7948 0 0 0-.3927.6813zm1.0976-2.3654l2.602-1.4998 2.6069 1.4998v2.9994l-2.5974 1.4997-2.6067-1.4997Z"/>"##),
        ]
    }()

    var icon: NSImage { Self.icons[self] ?? NSImage() }

    /// The three choices, for a dropdown.
    static func dropdownItems(_ choose: @escaping (TabProgram) -> Void) -> [DropdownItem] {
        allCases.map { program in DropdownItem(id: program.rawValue, title: program.title, icon: program.icon) { choose(program) } }
    }
}

/// Picks what a new workspace's first tab starts: the choice shown with its
/// icon, the choices in a menu, in the palette's plain style.
struct ProgramPicker: View {
    @Binding var program: TabProgram
    @State private var hovering = false
    @State private var anchor = DropdownAnchor()

    var body: some View {
        Button {
            DropdownPanel.toggle(TabProgram.dropdownItems { program = $0 }, selected: program.rawValue, below: anchor)
        } label: {
            HStack(spacing: 7) {
                Image(nsImage: program.icon)
                Text(program.title)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Theme.tertiary)
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovering ? Theme.control : .clear))
            .contentShape(Rectangle())
            .dropdownAnchor(anchor)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
        .accessibilityLabel("에이전트")
        .accessibilityValue(Text(program.title))
    }
}
