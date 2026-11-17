import AppKit
import Observation
import SwiftUI

/// Tabs of the selected workspace, drawn inside the top of the terminal panel
/// on a darker strip. The open tab is the same surface as the terminal below
/// it and flows into it through curved feet, as in Chrome (design F).
struct TabBarView: View {
    let model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            if let selection = model.selection, let workspace = model.workspace(selection), !workspace.isArchived {
                let tabs = model.tabs[selection] ?? []
                let active = model.activeTabs[selection]
                ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                    TabButton(
                        title: title(for: tab, index: index),
                        status: model.statuses[tab.id] ?? .idle,
                        isActive: active == tab.id,
                        select: { model.activateTab(tab.id) },
                        close: { AppActions.closeTab(model, tab.id) })
                    .transition(.opacity)
                    // A thin line between two tabs in the back; none beside the open one.
                    let next = index + 1 < tabs.count ? tabs[index + 1].id : nil
                    Rectangle()
                        .fill(Color(hex: 0x2E2E34))
                        .frame(width: 1, height: 16)
                        .padding(.bottom, 9)
                        .opacity(next != nil && tab.id != active && next != active ? 1 : 0)
                        .accessibilityHidden(true)
                }
                NewTabButton { model.openTab(in: selection) }
                    .disabled(!model.folderExists(workspace))
                    .frame(height: 34)
                    .padding(.leading, 4)
                Spacer(minLength: 8)
                if !workspace.branch.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.triangle.branch").font(.system(size: 10, weight: .medium))
                        Text(workspace.branch)
                            .font(.system(size: 12, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .foregroundStyle(Theme.secondary)
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color(hex: 0x1C1C20)))
                    .frame(height: 34)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("브랜치 \(workspace.branch)")
                }
            } else {
                Spacer(minLength: 0)
            }
        }
        // With the sidebar hidden the panel reaches the window's left edge,
        // where the close/minimize/zoom buttons sit.
        .padding(.leading, model.sidebarCollapsed ? 82 : 14)
        .padding(.trailing, 12)
        .frame(height: 46, alignment: .bottom)
        .background(Color(hex: 0x111113))
        // The open surface moves to the tab chosen; tabs fade in and out.
        .animation(Motion.settle, value: activeKey)
        .animation(Motion.layout(reduceMotion), value: model.sidebarCollapsed)
        .environment(\.colorScheme, .dark)
    }

    /// Which tab is active and which tabs exist: what the bar animates on.
    private var activeKey: [UUID] {
        guard let selection = model.selection else { return [] }
        return [model.activeTabs[selection]].compactMap { $0 } + (model.tabs[selection] ?? []).map(\.id)
    }

    private func title(for tab: TerminalTab, index: Int) -> String {
        TabTitle.display(model.titles[tab.id] ?? "", shell: AppModel.shellName)
    }
}

enum TabTitle {
    /// A short tab label from the window title a program reported.
    static func display(_ reported: String, shell: String) -> String {
        let title = reported.trimmingCharacters(in: .whitespaces)
        // A shell waiting at its prompt usually reports "user@host:directory".
        // The sidebar already says which directory this is, so name the
        // shell instead; a running command reports its own name.
        if title.isEmpty || title.range(of: #"^[^\s@]+@[^\s:]+:"#, options: .regularExpression) != nil { return shell }
        return title
    }
}

private struct TabButton: View {
    let title: String
    let status: AgentStatus
    let isActive: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 2) {
            Button(action: select) {
                HStack(spacing: 8) {
                    if status != .idle { StatusMark(status: status) }
                    Text(title)
                        .font(.system(size: 13, weight: isActive ? .medium : .regular))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        // As wide as the title needs, up to a limit: a bare
                        // maxWidth would stretch every tab to that limit.
                        .frame(maxWidth: 150, alignment: .leading)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .padding(.leading, 14)
                // Short titles still make a tab of at least 120 points, with
                // the close button at its right edge.
                .frame(minWidth: 94, maxHeight: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(status == .idle ? String(localized: "\(title) 탭") : String(localized: "\(title) 탭, \(status.label)"))
            .accessibilityAddTraits(isActive ? .isSelected : [])

            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 20, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(hovering || isActive ? 0.7 : 0)
            .accessibilityLabel("\(title) 탭 닫기")
        }
        .padding(.trailing, 6)
        .frame(height: 34)
        .foregroundStyle(isActive ? Color.white : hovering ? Theme.rowText : Theme.secondary)
        .background {
            if isActive {
                ChromeTabShape().fill(Theme.panelColor)
                    .overlay(alignment: .top) {
                        // A faint lit edge along the top, where the surface meets the strip.
                        Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1).padding(.horizontal, 9)
                    }
                    .transition(.opacity)
            } else {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(hovering ? 0.05 : 0))
                    .padding(.vertical, 3)
            }
        }
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
    }
}

/// An open tab: rounded on top and widening at the bottom through two
/// concave feet into the surface below. The feet reach `foot` points
/// outside the frame on each side.
struct ChromeTabShape: Shape {
    var corner: CGFloat = 10
    var foot: CGFloat = 8

    func path(in rect: CGRect) -> Path {
        let (left, right, top, bottom) = (rect.minX, rect.maxX, rect.minY, rect.maxY)
        var path = Path()
        path.move(to: CGPoint(x: left - foot, y: bottom))
        path.addQuadCurve(to: CGPoint(x: left, y: bottom - foot), control: CGPoint(x: left, y: bottom))
        path.addLine(to: CGPoint(x: left, y: top + corner))
        path.addQuadCurve(to: CGPoint(x: left + corner, y: top), control: CGPoint(x: left, y: top))
        path.addLine(to: CGPoint(x: right - corner, y: top))
        path.addQuadCurve(to: CGPoint(x: right, y: top + corner), control: CGPoint(x: right, y: top))
        path.addLine(to: CGPoint(x: right, y: bottom - foot))
        path.addQuadCurve(to: CGPoint(x: right + foot, y: bottom), control: CGPoint(x: right, y: bottom))
        path.closeSubpath()
        return path
    }
}

private struct NewTabButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .medium))
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? Theme.hoveredRow : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(hovering ? Theme.text : Theme.secondary)
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
        .accessibilityLabel("새 탭")
        .help("새 탭 (⌘T)")
    }
}

/// Shown in the panel when the selection has no terminal.
struct EmptyStateView: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 12) {
            if model.state.projects.isEmpty {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 84, height: 84)
                    .accessibilityHidden(true)
                headline("프로젝트를 추가해 시작하세요")
                detail("git 저장소 폴더를 등록하면 워크스페이스마다 워크트리와 터미널이 만들어집니다.")
                Button { AppActions.addProject(model) } label: {
                    HStack(spacing: 8) { Text("프로젝트 추가"); ButtonKey("⌘O") }
                }
                .buttonStyle(PlumButtonStyle(kind: .primary))
                .keyboardShortcut(.defaultAction)
                .padding(.top, 4)
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    shortcut("⌘N", "새 워크스페이스")
                    shortcut("⌘T", "새 탭")
                    shortcut("⌃⌘S", "사이드바 보기/가리기")
                }
                .padding(.top, 14)
            } else if let pending = model.pending.first(where: { $0.id == model.selection }) {
                PendingView(pending: pending)
            } else if let workspace = model.selectedWorkspace {
                if model.busy.contains(workspace.id) {
                    ProgressView()
                } else if workspace.isArchived {
                    headline("‘\(workspace.name)’은 아카이브되어 있습니다")
                    detail("브랜치 \(workspace.branch)는 남아 있습니다. 복원하면 워크트리를 다시 만듭니다.")
                    Button("복원") { AppActions.restore(model, workspace) }
                        .buttonStyle(PlumButtonStyle(kind: .primary))
                        .padding(.top, 4)
                } else if !model.folderExists(workspace) {
                    headline("폴더가 없습니다")
                    Text(workspace.path)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Theme.secondary)
                        .textSelection(.enabled)
                    detail("앱 밖에서 지워진 것 같습니다. 사이드바에서 아카이브하거나 삭제해 정리할 수 있습니다.")
                } else {
                    Button { model.openTab(in: workspace.id) } label: {
                        HStack(spacing: 8) { Text("터미널 열기"); ButtonKey("⌘T") }
                    }
                    .buttonStyle(PlumButtonStyle(kind: .primary))
                }
            } else {
                detail("워크스페이스를 선택하세요")
            }
        }
        .multilineTextAlignment(.center)
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(Motion.settle, value: stateKey)
        .environment(\.colorScheme, .dark)
    }

    /// Which of the states above is showing, so moving between them fades.
    private var stateKey: String {
        if model.state.projects.isEmpty { return "start" }
        if let pending = model.pending.first(where: { $0.id == model.selection }) { return "pending-\(pending.currentIndex)" }
        guard let workspace = model.selectedWorkspace else { return "none" }
        return "\(workspace.id)-\(model.busy.contains(workspace.id))-\(workspace.isArchived)"
    }

    private func headline(_ text: LocalizedStringKey) -> some View {
        Text(text).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text)
    }

    private func detail(_ text: LocalizedStringKey) -> some View {
        Text(text).font(.system(size: 13)).foregroundStyle(Theme.secondary)
    }

    private func shortcut(_ key: String, _ label: LocalizedStringKey) -> some View {
        GridRow {
            KeyHint(key).gridColumnAlignment(.trailing)
            Text(label).font(.system(size: 12.5)).foregroundStyle(Theme.tertiary)
        }
    }
}

/// The steps of a workspace being made: done, running, still to come.
private struct PendingView: View {
    let pending: PendingWorkspace

    var body: some View {
        VStack(spacing: 14) {
            Text("\(pending.name) 만드는 중").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(pending.steps.enumerated()), id: \.offset) { index, step in
                    let state = index < pending.currentIndex ? 0 : index == pending.currentIndex && step.kind != nil ? 1 : 2
                    HStack(spacing: 10) {
                        Group {
                            switch state {
                            case 0: Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.done)
                            case 1: ProgressView().controlSize(.small)
                            default: Circle().strokeBorder(Color(hex: 0x4A4A52), lineWidth: 1.5).frame(width: 11, height: 11)
                            }
                        }
                        .frame(width: 16)
                        Text(Self.title(step.kind))
                            .font(.system(size: 13))
                            .foregroundStyle(state == 1 ? Theme.text : state == 0 ? Theme.secondary : Theme.tertiary)
                        Spacer(minLength: 12)
                        Text(step.detail)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .frame(height: 30)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(verbatim: "\(Self.title(step.kind)), \(state == 0 ? String(localized: "끝남") : state == 1 ? String(localized: "진행 중") : String(localized: "대기"))"))
                }
            }
            .frame(width: 320)
        }
    }

    private static func title(_ kind: WorkspaceService.CreateStep?) -> String {
        switch kind {
        case .fetch: String(localized: "원격 가져오기")
        case .worktree: String(localized: "워크트리 만들기")
        case .copy: String(localized: "파일 복사")
        case nil: String(localized: "첫 탭에서 준비 명령")
        }
    }
}

/// The floating panel: tabs on top, the active terminal below.
/// The terminal view is plain AppKit, kept out of SwiftUI so that a change in
/// the SwiftUI tree can never tear down what is on screen.
@MainActor
final class TerminalAreaController: NSViewController {
    private let model: AppModel
    private let container = NSView()
    private var emptyState: NSView!
    private var toast: NSHostingView<ToastView>!
    private var toastBottom: NSLayoutConstraint!
    /// The error the toast shows, or nil while it is hidden or going.
    private var shownError: String?
    let terminal: TerminalView
    private var font: (String, Double)

    init(model: AppModel) {
        self.model = model
        font = (model.state.settings.fontName, model.state.settings.fontSize)
        terminal = TerminalView(fontName: font.0, fontSize: font.1)
        super.init(nibName: nil, bundle: nil)
        terminal.onUserInput = { [weak model] session in
            MainActor.assumeIsolated { model?.userTyped(in: session.id) }
        }
        terminal.confirmPaste = { [weak model] text, answer in
            guard let model else { return answer(false) }
            var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            if lines.last == "" { lines.removeLast() } // a final newline ends the last line, it isn't one more
            Task {
                answer(await AppActions.ask(model, Confirmation(
                    title: String(localized: "여러 줄을 붙여 넣을까요?"),
                    summary: String(localized: "붙여 넣는 내용에 줄바꿈이 있어 명령이 바로 실행될 수 있습니다."),
                    symbol: "doc.on.clipboard",
                    sections: [.init(title: String(localized: "붙여 넣을 내용"), lines: lines)],
                    action: String(localized: "붙여넣기"), destructive: false)))
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let root = NSView()

        // Two views for one panel: the outer carries the color and the drop
        // shadow, the inner clips the terminal to the rounded corners. One
        // layer cannot both clip its contents and cast a shadow.
        let surface = NSView()
        surface.wantsLayer = true
        surface.layer?.backgroundColor = Theme.panel.cgColor
        surface.layer?.cornerRadius = Theme.panelRadius
        surface.layer?.cornerCurve = .continuous
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.4)
        shadow.shadowBlurRadius = 18
        shadow.shadowOffset = NSSize(width: 0, height: -6)
        surface.shadow = shadow

        let panel = NSView()
        panel.wantsLayer = true
        panel.layer?.cornerRadius = Theme.panelRadius
        panel.layer?.cornerCurve = .continuous
        panel.layer?.masksToBounds = true

        let tabBar = NSHostingView(rootView: TabBarView(model: model))
        tabBar.safeAreaRegions = [] // it sits under the title bar on purpose
        let empty = NSHostingView(rootView: EmptyStateView(model: model))
        empty.safeAreaRegions = []
        emptyState = empty
        // Sized to the toast itself, so the terminal still gets every other click.
        let toast = NSHostingView(rootView: ToastView())
        toast.safeAreaRegions = []
        toast.sizingOptions = [.intrinsicContentSize]
        toast.isHidden = true
        self.toast = toast

        for view in [surface, panel, tabBar, container, toast] { view.translatesAutoresizingMaskIntoConstraints = false }
        root.addSubview(surface)
        surface.addSubview(panel)
        panel.addSubview(tabBar)
        panel.addSubview(container)
        panel.addSubview(toast)
        NSLayoutConstraint.activate([
            // Measured from the window's edges, not the safe area: the panel
            // runs up beside the window buttons.
            surface.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            surface.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 4),
            surface.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            surface.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
            panel.topAnchor.constraint(equalTo: surface.topAnchor),
            panel.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            panel.bottomAnchor.constraint(equalTo: surface.bottomAnchor),
            tabBar.topAnchor.constraint(equalTo: panel.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: 46),
            container.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            container.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
            toast.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
        ])
        toastBottom = toast.bottomAnchor.constraint(equalTo: panel.bottomAnchor)
        toastBottom.isActive = true
        for view in [terminal, emptyState!] {
            view.frame = container.bounds
            view.autoresizingMask = [.width, .height]
            container.addSubview(view)
        }
        terminal.isHidden = true
        view = root

        observeModel()
    }

    /// Runs `sync` now and again whenever something it read changes.
    private func observeModel() {
        withObservationTracking { sync() } onChange: { [weak self] in
            // Called before the change lands: look again once it has.
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.observeModel() } }
        }
    }

    private func sync() {
        let settings = model.state.settings
        if font != (settings.fontName, settings.fontSize) {
            font = (settings.fontName, settings.fontSize)
            terminal.setFont(name: font.0, size: font.1)
        }
        // Not shown, but still what VoiceOver and the Window menu read.
        view.window?.title = model.selectedWorkspace.map { workspace in
            "\(workspace.name) — \(model.project(workspace.projectID)?.name ?? "")"
        } ?? "Plum"
        syncToast()

        let active = model.activeTab?.session
        guard active !== terminal.session || terminal.isHidden != (active == nil) else { return }
        terminal.session = active
        terminal.isHidden = active == nil
        emptyState.isHidden = active != nil
        // Don't steal focus from a field in an open dialog.
        if active != nil, model.sheet == nil { view.window?.makeFirstResponder(terminal) }
    }

    /// Slides the toast in when an error arrives and fades it out when it is
    /// dismissed. Core Animation runs both, off the main thread's clock.
    private func syncToast() {
        let message = model.errorMessage
        guard message != shownError else { return }
        let wasShown = shownError != nil
        shownError = message
        let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if let message {
            toast.rootView = ToastView(message: message) { [weak model] in model?.errorMessage = nil }
            // It is easy to miss without sight: read it out.
            NSAccessibility.post(
                element: NSApp as Any, notification: .announcementRequested,
                userInfo: [.announcement: String(localized: "문제가 생겼습니다. \(message)"), .priority: NSAccessibilityPriorityLevel.high.rawValue])
            guard !wasShown else { return }
            toast.alphaValue = 0
            toastBottom.constant = still ? 0 : 12
            toast.isHidden = false
            toast.superview?.layoutSubtreeIfNeeded()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                toast.animator().alphaValue = 1
                toastBottom.animator().constant = 0
            }
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                toast.animator().alphaValue = 0
                if !still { toastBottom.animator().constant = 8 }
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    // Unless another error came while it faded.
                    guard let self, self.shownError == nil else { return }
                    self.toast.isHidden = true
                }
            }
        }
    }

    func focusTerminal() {
        if !terminal.isHidden { view.window?.makeFirstResponder(terminal) }
    }
}

/// Sidebar on the left, terminal panel on the right, both on the window's
/// own background with nothing drawn between them.
@MainActor
final class RootViewController: NSViewController {
    private let model: AppModel
    let terminalArea: TerminalAreaController
    private let sidebar: NSHostingController<SidebarView>
    private var sidebarWidth: NSLayoutConstraint!
    private let dim = DimView()
    private var card: CardHostingView!
    private var cardAtTop: NSLayoutConstraint!
    private var cardCentered: NSLayoutConstraint!
    private var shownSheet: AppSheet?
    /// Keys a dialog needs before its controls see them.
    private var dialogKeys: Any?
    /// The sidebar's keyboard mode, while it is on.
    private var sidebarKeys: Any?

    init(model: AppModel) {
        self.model = model
        terminalArea = TerminalAreaController(model: model)
        sidebar = NSHostingController(rootView: SidebarView(model: model))
        // The width is ours to set (and to animate to zero), not SwiftUI's.
        sidebar.sizingOptions = []
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let root = NSView()
        addChild(sidebar)
        addChild(terminalArea)
        sidebar.view.clipsToBounds = true
        for view in [sidebar.view, terminalArea.view] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        // Dialogs draw over everything, sidebar included.
        let card = CardHostingView(rootView: DialogCard(model: model, sheet: nil))
        card.safeAreaRegions = []
        card.sizingOptions = [.intrinsicContentSize]
        card.wantsLayer = true
        self.card = card
        dim.onClick = { [weak self] in
            // A click outside closes the palette, the one dialog with nothing to lose.
            if case .newWorkspace = self?.model.sheet { self?.model.sheet = nil }
        }
        for dialogView in [dim, card] as [NSView] {
            dialogView.isHidden = true
            dialogView.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(dialogView)
        }
        sidebarWidth = sidebar.view.widthAnchor.constraint(equalToConstant: Theme.sidebarWidth)
        NSLayoutConstraint.activate([
            sidebarWidth,
            sidebar.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebar.view.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.view.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            terminalArea.view.leadingAnchor.constraint(equalTo: sidebar.view.trailingAnchor),
            terminalArea.view.topAnchor.constraint(equalTo: root.topAnchor),
            terminalArea.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            terminalArea.view.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            dim.topAnchor.constraint(equalTo: root.topAnchor),
            dim.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            dim.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            dim.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            card.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            card.topAnchor.constraint(greaterThanOrEqualTo: root.topAnchor, constant: 20),
        ])
        // The palette sits high, like a search field; the rest are centered.
        cardAtTop = card.topAnchor.constraint(equalTo: root.topAnchor, constant: 72)
        cardCentered = card.centerYAnchor.constraint(equalTo: root.centerYAnchor)
        cardCentered.priority = .defaultHigh
        view = root
        observeDialogs()
    }

    /// For scripted checks: closes the open dialog and reports the card's
    /// on-screen opacity every 1/120 s for 0.4 s ("ms:opacity", "h" once hidden).
    func traceDialogClose(_ done: @escaping (String) -> Void) {
        let start = CACurrentMediaTime()
        var samples: [String] = []
        model.sheet = nil
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { return timer.invalidate() }
                let elapsed = CACurrentMediaTime() - start
                let opacity = self.card.layer?.presentation()?.opacity ?? -1
                samples.append(String(format: "%.0f:%.2f%@", elapsed * 1000, opacity, self.card.isHidden ? "h" : ""))
                if elapsed > 0.4 {
                    timer.invalidate()
                    done(samples.joined(separator: " "))
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Shows, swaps and hides the dialog as `model.sheet` changes, keeping
    /// the keyboard with it while it is open.
    private func observeDialogs() {
        let sheet = withObservationTracking { model.sheet } onChange: { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.observeDialogs() } }
        }
        guard sheet?.id != shownSheet?.id else { return }
        let previous = shownSheet
        shownSheet = sheet
        // A question closed without an answer was answered "no".
        if case let .confirm(confirmation)? = previous { confirmation.finish(false) }
        if let dialogKeys { NSEvent.removeMonitor(dialogKeys) }
        dialogKeys = nil
        if sheet != nil, sidebarKeys != nil { leaveSidebar(focusTerminal: false) }
        switch sheet {
        case let .confirm(confirmation)?:
            dialogKeys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.window === view.window, let answer = confirmation.answerForKey(event.keyCode) else { return event }
                confirmation.finish(answer)
                model.sheet = nil
                return nil
            }
        case let .switcher(switcher)?:
            // A text field keeps the arrow keys; the list needs them.
            dialogKeys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.window === view.window else { return event }
                let control = event.modifierFlags.contains(.control)
                let key = event.charactersIgnoringModifiers ?? ""
                if event.keyCode == 125 || (control && key == "n") {
                    switcher.move(1)
                } else if event.keyCode == 126 || (control && key == "p") {
                    switcher.move(-1)
                } else {
                    return event
                }
                return nil
            }
        default: break
        }

        guard let sheet else {
            DialogMotion.hide(dim: dim, card: card) { [weak self] in
                guard let self, shownSheet == nil else { return }
                card.rootView = DialogCard(model: model, sheet: nil)
                // SwiftUI may take the keyboard back for a control that is
                // gone; once it has settled, hand it to the terminal.
                DispatchQueue.main.async { [weak self] in
                    guard let self, shownSheet == nil,
                          let responder = view.window?.firstResponder as? NSView, responder.isDescendant(of: card)
                    else { return }
                    terminalArea.focusTerminal()
                }
            }
            terminalArea.focusTerminal()
            return
        }
        card.rootView = DialogCard(model: model, sheet: sheet)
        let atTop = if case .newWorkspace = sheet { true } else { false }
        cardCentered.isActive = !atTop
        cardAtTop.isActive = atTop
        view.layoutSubtreeIfNeeded()
        if previous == nil { DialogMotion.show(dim: dim, card: card) } else { DialogMotion.swap(card: card) }
        // Typing must stop reaching the terminal behind. A field the dialog
        // focused itself already holds the keyboard: leave it there.
        if view.window?.firstResponder is TerminalView { view.window?.makeFirstResponder(card) }
    }

    /// Gives the sidebar the keyboard: ↑↓ (or j k, ⌃N ⌃P) pick a workspace,
    /// Return, Esc or → hand the keyboard back to its terminal. Any other key
    /// does that too and is then typed there. ⌘ shortcuts keep working.
    func focusSidebar() {
        guard model.sheet == nil, !model.workspaceOrder.isEmpty else { return }
        if sidebarKeys != nil { return leaveSidebar(focusTerminal: true) }
        if model.sidebarCollapsed { toggleSidebar() }
        model.sidebarHasKeyboard = true
        sidebarKeys = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] event in
            guard let self, event.window === view.window else { return event }
            if event.type == .leftMouseDown {
                leaveSidebar(focusTerminal: false)
                return event
            }
            let flags = event.modifierFlags.intersection([.command, .control, .option])
            if flags.contains(.command) { return event }
            let key = event.charactersIgnoringModifiers ?? ""
            let plain = flags.isEmpty, control = flags == .control
            if event.keyCode == 126 || (plain && key == "k") || (control && key == "p") {
                model.selectWorkspace(offset: -1)
            } else if event.keyCode == 125 || (plain && key == "j") || (control && key == "n") {
                model.selectWorkspace(offset: 1)
            } else if [36, 76, 53, 124].contains(event.keyCode) { // Return, Enter, Esc, →
                leaveSidebar(focusTerminal: true)
            } else {
                leaveSidebar(focusTerminal: true)
                return event
            }
            return nil
        }
    }

    private func leaveSidebar(focusTerminal: Bool) {
        if let sidebarKeys { NSEvent.removeMonitor(sidebarKeys) }
        sidebarKeys = nil
        model.sidebarHasKeyboard = false
        if focusTerminal { terminalArea.focusTerminal() }
    }

    func toggleSidebar() {
        let collapse = !model.sidebarCollapsed
        model.sidebarCollapsed = collapse
        if !collapse { sidebar.view.isHidden = false }
        let width = collapse ? 0 : Theme.sidebarWidth
        // Animations don't advance in a window nobody can see, which would
        // leave the layout stuck halfway.
        guard view.window?.occlusionState.contains(.visible) == true else {
            sidebarWidth.constant = width
            sidebar.view.alphaValue = collapse ? 0 : 1
            sidebar.view.isHidden = collapse
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.allowsImplicitAnimation = true
            sidebarWidth.animator().constant = width
            sidebar.view.animator().alphaValue = collapse ? 0 : 1
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                // Hidden, not just zero-width, so keyboard and VoiceOver skip it.
                if self?.model.sidebarCollapsed == true { self?.sidebar.view.isHidden = true }
            }
        }
    }
}

/// The dimmed window behind a dialog. It takes every click, so nothing
/// behind reacts while the dialog is open.
final class DimView: NSView {
    var onClick: () -> Void = {}

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func mouseDown(with event: NSEvent) { onClick() }
    override func rightMouseDown(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}
    override var mouseDownCanMoveWindow: Bool { false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
}

/// The dialog card. Its drop shadow is a layer shadow along a known path:
/// drawn by the render server, outside the view's bounds, at no cost to SwiftUI.
final class CardHostingView: NSHostingView<DialogCard> {
    override func layout() {
        super.layout()
        guard let layer else { return }
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = 0.5
        layer.shadowRadius = 30
        layer.shadowOffset = CGSize(width: 0, height: -14)
        layer.shadowPath = CGPath(roundedRect: bounds, cornerWidth: 14, cornerHeight: 14, transform: nil)
    }
}

/// How dialogs come and go. Core Animation interpolates every frame in the
/// render server, so the motion stays smooth even while the main thread is
/// still building the dialog's views.
@MainActor
enum DialogMotion {
    private static var still: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    static func show(dim: NSView, card: NSView) {
        for view in [dim, card] { view.layer?.removeAllAnimations() }
        dim.isHidden = false
        card.isHidden = false
        dim.alphaValue = 1
        card.alphaValue = 1
        dim.layer?.add(fade(from: 0, to: 1, duration: 0.2), forKey: "fade")
        card.layer?.add(fade(from: 0, to: 1, duration: 0.2), forKey: "fade")
        if !still { card.layer?.add(scale(card, from: 0.96, duration: 0.24, curve: settle), forKey: "scale") }
    }

    /// One dialog in place of another (settings → "remove this project?").
    static func swap(card: NSView) {
        card.layer?.removeAllAnimations()
        card.layer?.add(fade(from: 0.4, to: 1, duration: 0.14), forKey: "fade")
    }

    static func hide(dim: NSView, card: NSView, completion: @escaping () -> Void) {
        CATransaction.begin()
        CATransaction.setCompletionBlock {
            MainActor.assumeIsolated {
                // A dialog opened while this one faded keeps its views.
                guard dim.layer?.animation(forKey: "fadeOut") != nil else { return }
                for view in [dim, card] {
                    view.isHidden = true
                    view.layer?.removeAllAnimations()
                }
                completion()
            }
        }
        // Fading and shrinking share one duration and one curve, so the card
        // goes as one piece; the curve starts at once and eases into nothing
        // instead of holding on and then vanishing.
        for view in [dim, card] {
            let out = fade(from: 1, to: 0, duration: 0.2)
            out.fillMode = .forwards
            out.isRemovedOnCompletion = false
            view.layer?.add(out, forKey: "fadeOut")
        }
        if !still { card.layer?.add(scale(card, from: 1, to: 0.97, duration: 0.2, curve: glide, keep: true), forKey: "scaleOut") }
        CATransaction.commit()
    }

    /// Arriving: quick, then settling.
    private static let settle = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
    /// Moving at once and slowing to a stop: for fades both ways and for leaving.
    private static let glide = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1)

    private static func fade(from: CGFloat, to: CGFloat, duration: Double) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.timingFunction = glide
        return animation
    }

    /// Scales about the card's center (an AppKit layer's anchor is its corner).
    private static func scale(_ card: NSView, from: CGFloat, to: CGFloat = 1, duration: Double, curve: CAMediaTimingFunction, keep: Bool = false) -> CABasicAnimation {
        func transform(_ factor: CGFloat) -> CATransform3D {
            let (x, y) = (card.bounds.width / 2, card.bounds.height / 2)
            return CATransform3DConcat(
                CATransform3DConcat(CATransform3DMakeTranslation(-x, -y, 0), CATransform3DMakeScale(factor, factor, 1)),
                CATransform3DMakeTranslation(x, y, 0))
        }
        let animation = CABasicAnimation(keyPath: "transform")
        animation.fromValue = transform(from)
        animation.toValue = transform(to)
        animation.duration = duration
        animation.timingFunction = curve
        if keep {
            animation.fillMode = .forwards
            animation.isRemovedOnCompletion = false
        }
        return animation
    }
}

@MainActor
public final class MainWindowController: NSWindowController {
    private let root: RootViewController

    public init(model: AppModel) {
        root = RootViewController(model: model)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Plum"
        window.minSize = NSSize(width: 640, height: 360)
        window.tabbingMode = .disallowed
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = Theme.backdrop

        // No visible title bar: the sidebar and the panel run to the top
        // edge. An empty unified toolbar is there only to make the title bar
        // tall enough that the window buttons sit level with the tabs.
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.toolbar = NSToolbar(identifier: "PlumMain")
        window.toolbarStyle = .unified
        window.isMovableByWindowBackground = true

        super.init(window: window)
        window.contentViewController = root
        window.setContentSize(NSSize(width: 1180, height: 760))
        window.center()
        window.setFrameAutosaveName("PlumMainWindow")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    public func toggleSidebar() { root.toggleSidebar() }
    public func focusSidebar() { root.focusSidebar() }
    func traceDialogClose(_ done: @escaping (String) -> Void) { root.traceDialogClose(done) }
    public func focusTerminal() { root.terminalArea.focusTerminal() }
    var terminalView: TerminalView { root.terminalArea.terminal }
}
