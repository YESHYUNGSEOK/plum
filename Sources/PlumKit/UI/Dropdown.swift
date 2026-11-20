import AppKit
import Observation
import SwiftUI

/// One line of a dropdown or a menu: a command, a line between groups, a
/// note that explains, or a submenu that opens in place.
struct DropdownItem: Identifiable {
    enum Kind {
        case action, separator, note
        case submenu([DropdownItem])
    }

    let id: String
    let title: Text
    var icon: NSImage?
    var symbol: String?
    var kind = Kind.action
    var destructive = false
    var enabled = true
    var action: () -> Void = {}

    init(id: String, title: LocalizedStringKey, icon: NSImage? = nil, action: @escaping () -> Void) {
        self.id = id
        self.title = Text(title)
        self.icon = icon
        self.action = action
    }

    private init(id: String, title: Text) {
        self.id = id
        self.title = title
    }

    /// A command; `title` is already localized, and names it for scripted checks.
    static func command(_ title: String, symbol: String? = nil, icon: NSImage? = nil, destructive: Bool = false,
                        enabled: Bool = true, action: @escaping () -> Void) -> DropdownItem {
        var item = DropdownItem(id: title, title: Text(verbatim: title))
        item.symbol = symbol
        item.icon = icon
        item.destructive = destructive
        item.enabled = enabled
        item.action = action
        return item
    }

    static func separator() -> DropdownItem {
        var item = DropdownItem(id: "—" + UUID().uuidString, title: Text(verbatim: ""))
        item.kind = .separator
        return item
    }

    /// A line that explains, in the menu's quieter gray.
    static func note(_ text: String) -> DropdownItem {
        var item = DropdownItem(id: text, title: Text(verbatim: text))
        item.kind = .note
        return item
    }

    static func submenu(_ title: String, symbol: String, _ items: [DropdownItem]) -> DropdownItem {
        var item = DropdownItem(id: title, title: Text(verbatim: title))
        item.symbol = symbol
        item.kind = .submenu(items)
        return item
    }

    var selectable: Bool {
        switch kind {
        case .action, .submenu: enabled
        case .separator, .note: false
        }
    }
}

/// Where a dropdown opens from: an AppKit view laid under the SwiftUI control,
/// so the panel can be placed against it on screen.
final class DropdownAnchor {
    fileprivate weak var view: NSView?
}

private struct AnchorView: NSViewRepresentable {
    let anchor: DropdownAnchor
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { anchor.view = view }
}

extension View {
    func dropdownAnchor(_ anchor: DropdownAnchor) -> some View { background(AnchorView(anchor: anchor)) }

    /// A right-click (or Control-click) here opens Plum's own menu, with the
    /// items `items` makes at that moment.
    func plumMenu(_ items: @escaping () -> [DropdownItem]) -> some View { overlay(MenuCatcher(items: items)) }
}

private struct MenuCatcher: NSViewRepresentable {
    let items: () -> [DropdownItem]
    func makeNSView(context: Context) -> MenuCatcherView { MenuCatcherView() }
    func updateNSView(_ view: MenuCatcherView, context: Context) { view.items = items }
}

/// Laid over a control, it takes only secondary clicks: every other event
/// finds the control beneath as if this weren't there.
final class MenuCatcherView: NSView {
    var items: (() -> [DropdownItem])?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApp.currentEvent else { return nil }
        let secondary = event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
        return secondary ? super.hitTest(point) : nil
    }

    override func rightMouseDown(with event: NSEvent) { open(event) }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { open(event) } else { super.mouseDown(with: event) }
    }

    /// At the click itself, not wherever the pointer is by now.
    private func open(_ event: NSEvent) {
        guard let window, let items = items?(), !items.isEmpty else { return }
        DropdownPanel.showMenu(items, at: window.convertPoint(toScreen: event.locationInWindow), in: window)
    }
}

@Observable
final class DropdownList {
    let items: [DropdownItem]
    let selected: String?
    var highlighted: String?
    /// Submenus opened in place.
    var expanded: Set<String> = []
    /// Drives the fade in and out, drawn by the list itself.
    var shown = false

    init(items: [DropdownItem], selected: String?) {
        self.items = items
        self.selected = selected
        highlighted = selected
    }

    /// The lines as shown: an open submenu's items follow it, indented.
    var rows: [(item: DropdownItem, depth: Int)] {
        items.flatMap { item -> [(item: DropdownItem, depth: Int)] in
            if case let .submenu(children) = item.kind, expanded.contains(item.id) {
                return [(item, 0)] + children.map { ($0, 1) }
            }
            return [(item, 0)]
        }
    }

    func move(_ step: Int) {
        let choices = rows.map(\.item).filter(\.selectable)
        guard !choices.isEmpty else { return }
        let index = choices.firstIndex { $0.id == highlighted } ?? (step > 0 ? -1 : choices.count)
        highlighted = choices[(index + step + choices.count) % choices.count].id
    }

    /// The submenu a line belongs to, if it's inside one.
    func parent(of id: String) -> DropdownItem? {
        items.first { item in
            if case let .submenu(children) = item.kind { return children.contains { $0.id == id } }
            return false
        }
    }
}

/// Plum's own dropdowns and menus, drawn like the rest of the app rather
/// than as system menus: a small panel under its control, or at the pointer
/// for a right-click. ↑↓ move, Return chooses, → and ← open and close a
/// submenu, Esc closes; so does a click anywhere else.
@MainActor
final class DropdownPanel: NSPanel {
    /// The one open now. Also read by the scripted checks.
    private(set) static var current: DropdownPanel?
    /// The last one to close, and when: a click on its own control closes it
    /// first, and must not then open it again.
    private static var lastClosed: (anchor: ObjectIdentifier, at: TimeInterval)?

    let list: DropdownList
    private weak var anchorView: NSView?
    private var host: NSHostingView<DropdownView>?
    private var minWidth: CGFloat = 0
    private var closing = false
    /// Closes the dropdown on a press anywhere else in the app.
    private var clicks: Any?

    private init(list: DropdownList) {
        self.list = list
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }

    /// Opens a dropdown under `anchor`, or closes the one it opened.
    static func toggle(_ items: [DropdownItem], selected: String? = nil, below anchor: DropdownAnchor, minWidth: CGFloat = 0) {
        guard let view = anchor.view, let parent = view.window else { return }
        if let open = current, open.anchorView === view {
            open.dismiss()
            return
        }
        if let last = lastClosed, last.anchor == ObjectIdentifier(view), ProcessInfo.processInfo.systemUptime - last.at < 0.25 {
            return
        }
        current?.dismiss()
        let panel = DropdownPanel(list: DropdownList(items: items, selected: selected))
        // Return chooses at once: the current choice, or the first.
        panel.list.highlighted = selected ?? items.first(where: \.selectable)?.id
        panel.anchorView = view
        // Under the control, its left edges lined up.
        let anchorOnScreen = parent.convertToScreen(view.convert(view.bounds, to: nil))
        panel.present(in: parent, minWidth: minWidth, topLeft: NSPoint(x: anchorOnScreen.minX, y: anchorOnScreen.minY - 4),
                      above: anchorOnScreen.maxY + 4)
    }

    /// Opens a menu at `point` on screen: what a right-click shows.
    static func showMenu(_ items: [DropdownItem], at point: NSPoint, in parent: NSWindow) {
        current?.dismiss()
        let panel = DropdownPanel(list: DropdownList(items: items, selected: nil))
        panel.present(in: parent, minWidth: 220, topLeft: NSPoint(x: point.x + 2, y: point.y - 2), above: point.y + 2)
    }

    /// Shows the panel with its top left at `topLeft`, or above `above`
    /// when there is no room below, kept on screen.
    private func present(in parent: NSWindow, minWidth: CGFloat, topLeft: NSPoint, above: CGFloat) {
        self.minWidth = minWidth
        let host = NSHostingView(rootView: DropdownView(list: list, minWidth: minWidth) { [weak self] item in self?.choose(item) })
        host.sizingOptions = [.intrinsicContentSize]
        self.host = host
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        contentView = host

        var frame = NSRect(x: topLeft.x, y: topLeft.y - size.height, width: size.width, height: size.height)
        if let screen = parent.screen?.visibleFrame {
            frame.origin.x = min(max(frame.minX, screen.minX + 4), screen.maxX - size.width - 4)
            if frame.minY < screen.minY { frame.origin.y = above } // no room below: above
        }
        setFrame(frame, display: false)
        parent.addChildWindow(self, ordered: .above)
        makeKeyAndOrderFront(nil)
        // The list fades in, not the window: a window's own fade stalls
        // when the system isn't drawing it, and would leave it invisible.
        withAnimation(.easeOut(duration: 0.12)) { list.shown = true }
        clicks = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                if let self, event.window !== self { self.dismiss() }
            }
            return event
        }
        Self.current = self
    }

    /// Grows or shrinks to the list, its top edge staying where it is.
    private func fit() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let host else { return }
            let size = host.fittingSize
            var frame = self.frame
            frame.origin.y = frame.maxY - size.height
            frame.size = size
            host.frame = NSRect(origin: .zero, size: size)
            setFrame(frame, display: true)
        }
    }

    private func choose(_ item: DropdownItem) {
        guard item.selectable else { return }
        if case .submenu = item.kind {
            toggleSubmenu(item.id)
            return
        }
        dismiss()
        item.action()
    }

    private func toggleSubmenu(_ id: String, open: Bool? = nil) {
        let opening = open ?? !list.expanded.contains(id)
        withAnimation(.easeOut(duration: 0.12)) {
            if opening { list.expanded.insert(id) } else { list.expanded.remove(id) }
        }
        fit()
    }

    func dismiss() {
        guard !closing else { return }
        closing = true
        if let clicks { NSEvent.removeMonitor(clicks) }
        clicks = nil
        if let view = anchorView { Self.lastClosed = (ObjectIdentifier(view), ProcessInfo.processInfo.systemUptime) }
        if Self.current === self { Self.current = nil }
        let parent = self.parent
        // Typing goes back where it was before the dropdown opened.
        if isKeyWindow { parent?.makeKey() }
        withAnimation(.easeIn(duration: 0.08)) { list.shown = false }
        // Gone after the fade by the clock, not by the fade finishing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            parent?.removeChildWindow(self)
            orderOut(nil)
        }
    }

    // A click outside, or another app in front.
    override func resignKey() {
        super.resignKey()
        dismiss()
    }

    override func keyDown(with event: NSEvent) {
        let highlighted = list.rows.map(\.item).first { $0.id == list.highlighted }
        switch event.keyCode {
        case 125: list.move(1) // ↓
        case 126: list.move(-1) // ↑
        case 36, 76, 49: // Return, Enter, Space
            if let highlighted { choose(highlighted) }
        case 124: // →: into a submenu
            if let highlighted, case let .submenu(children) = highlighted.kind {
                toggleSubmenu(highlighted.id, open: true)
                list.highlighted = children.first(where: \.selectable)?.id
            }
        case 123: // ←: out of it
            if let id = list.highlighted, let parent = list.parent(of: id) {
                list.highlighted = parent.id
                toggleSubmenu(parent.id, open: false)
            }
        case 53: dismiss() // Esc
        default: super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) { dismiss() }
}

struct DropdownView: View {
    let list: DropdownList
    let minWidth: CGFloat
    let choose: (DropdownItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(list.rows, id: \.item.id) { row in
                line(row.item, depth: row.depth)
            }
        }
        .padding(5)
        .frame(minWidth: max(minWidth, 184), alignment: .leading)
        .fixedSize()
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.menu)
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline)))
        .animation(Motion.hover, value: list.highlighted)
        .opacity(list.shown ? 1 : 0)
        .offset(y: list.shown ? 0 : -3)
    }

    @ViewBuilder
    private func line(_ item: DropdownItem, depth: Int) -> some View {
        switch item.kind {
        case .separator:
            Rectangle().fill(Theme.hairline).frame(height: 1).padding(.vertical, 4).padding(.horizontal, 6)
        case .note:
            // In line with the commands' titles.
            item.title
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 34)
                .padding(.trailing, 9)
                .padding(.vertical, 2)
        case .action, .submenu:
            command(item, depth: depth)
        }
    }

    private func command(_ item: DropdownItem, depth: Int) -> some View {
        let isHighlighted = list.highlighted == item.id && item.enabled
        let color = item.destructive ? Theme.danger : Theme.text
        return Button { choose(item) } label: {
            HStack(spacing: 9) {
                Group {
                    if let icon = item.icon {
                        Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                    } else if let symbol = item.symbol {
                        Image(systemName: symbol).font(.system(size: 12, weight: .medium))
                            .foregroundStyle(item.destructive ? Theme.danger : Theme.secondary)
                    }
                }
                .frame(width: 16)
                item.title
                    .font(.system(size: 13))
                    .foregroundStyle(color)
                Spacer(minLength: 16)
                if case .submenu = item.kind {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.tertiary)
                        .rotationEffect(.degrees(list.expanded.contains(item.id) ? 90 : 0))
                } else if list.selected != nil {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.accent)
                        .opacity(list.selected == item.id ? 1 : 0)
                }
            }
            .padding(.leading, 9 + CGFloat(depth) * 16)
            .padding(.trailing, 9)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHighlighted ? Theme.highlight : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!item.enabled)
        .opacity(item.enabled ? 1 : 0.4)
        .onHover { if $0, item.enabled { list.highlighted = item.id } }
        .accessibilityAddTraits(list.selected == item.id ? .isSelected : [])
    }
}
