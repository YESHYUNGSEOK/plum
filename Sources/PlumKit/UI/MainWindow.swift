import AppKit
import Observation
import SwiftUI

/// Tabs of the selected workspace, drawn inside the top of the terminal panel
/// on a darker strip. The open tab is the same surface as the terminal below
/// it and flows into it through curved feet, as in Chrome (design F).
/// What a terminal panel shows: the main window's selected workspace, or
/// one workspace in a window of its own.
enum PanelScope: Equatable {
    case selection
    case workspace(UUID)

    /// The workspace to show now. The main window leaves out those that
    /// have their own windows.
    @MainActor
    func workspace(in model: AppModel) -> UUID? {
        switch self {
        case .selection: model.selection.flatMap { model.ownWindows.contains($0) ? nil : $0 }
        case let .workspace(id): id
        }
    }
}

struct TabBarView: View {
    let model: AppModel
    var scope = PanelScope.selection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var barWidth: CGFloat = 0
    @State private var chipWidth: CGFloat = 0

    // Room for the window buttons when no sidebar is beside the bar.
    private var leadingInset: CGFloat { scope != .selection ? 82 : 14 }

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            if let selection = scope.workspace(in: model), let workspace = model.workspace(selection), !workspace.isArchived {
                // A split tab shows once, under its head.
                let tabs = model.tabBarTabs(in: selection)
                let active = model.activeTabs[selection].map(model.head)
                // Room for tabs: the bar less its insets, the + and the branch.
                let room = barWidth - leadingInset - 12 - 38 - 8 - chipWidth
                if barWidth > 0, CGFloat(tabs.count) * TabStrip.minimumWidth > room {
                    // Even at their narrowest they don't fit: they scroll, the
                    // open one kept in view.
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal, showsIndicators: false) {
                            TabStrip(fixedWidth: TabStrip.minimumWidth) { tabButtons(tabs, active: active) }
                        }
                        .frame(width: max(0, room), height: 34)
                        .onAppear { if let active { proxy.scrollTo(active) } }
                        .onChange(of: active) { if let active { withAnimation(Motion.settle) { proxy.scrollTo(active) } } }
                    }
                } else {
                    TabStrip { tabButtons(tabs, active: active) }
                        // The tabs get room before the branch name does.
                        .layoutPriority(1)
                }
                NewTabButton { program in
                    if program == .terminal { model.openTabBeside(in: selection) } else { model.openTab(in: selection, program: program) }
                }
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
                            .frame(maxWidth: 200, alignment: .leading)
                    }
                    .foregroundStyle(Theme.secondary)
                    .padding(.horizontal, 9)
                    // As wide as the name, up to a limit; it keeps that width
                    // and the tabs make do with the rest.
                    .fixedSize()
                    .frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Theme.tabBarChip))
                    .frame(height: 34)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { chipWidth = $0 }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("브랜치 \(workspace.branch)")
                }
            } else {
                Spacer(minLength: 0)
            }
        }
        // With the sidebar hidden the panel reaches the window's left edge,
        // where the close/minimize/zoom buttons sit.
        .padding(.leading, leadingInset)
        .padding(.trailing, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 46, alignment: .bottom)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { barWidth = $0 }
        .background(Theme.tabBar)
        // The open surface moves to the tab chosen; tabs fade in and out.
        .animation(Motion.settle, value: activeKey)
        .id(model.state.settings.accent)
    }

    private func tabButtons(_ tabs: [TerminalTab], active: UUID?) -> some View {
        ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
            let next = index + 1 < tabs.count ? tabs[index + 1].id : nil
            let panes = model.panes(ofTab: tab.id)
            // A split tab is named for the pane with the keyboard, and shows
            // the most pressing state among its panes.
            let focused = model.activeTabs[tab.workspaceID].flatMap(model.terminal)
            let shown = active == tab.id ? focused ?? tab : tab
            TabButton(
                tab: shown,
                status: panes.compactMap { model.statuses[$0] }.max { $0.urgency < $1.urgency } ?? .idle,
                isActive: active == tab.id,
                // A thin line between two tabs in the back; none beside the open one.
                showsDivider: next != nil && tab.id != active && next != active,
                isRenaming: model.renamingTab == shown.id,
                select: { model.selectTabBarTab(tab.id) },
                startRename: {
                    model.activateTab(shown.id)
                    model.renamingTab = shown.id
                },
                close: { panes.count > 1 ? AppActions.closeTabs(model, panes) : AppActions.closeTab(model, tab.id) },
                finishRename: { title in
                    model.renamingTab = nil
                    if let title { model.renameTab(shown.id, to: title) }
                })
            // Drag a tab onto another to put it there.
            .draggable(tab.id.uuidString)
            .dropDestination(for: String.self) { items, _ in
                guard let id = items.first.flatMap(UUID.init(uuidString:)) else { return false }
                withAnimation(reduceMotion ? nil : Motion.settle) { model.moveTab(id, to: tab.id) }
                return true
            }
            .plumMenu {
                [
                    .command(String(localized: "제목 변경…"), symbol: "pencil") {
                        model.activateTab(shown.id)
                        model.renamingTab = shown.id
                    },
                    .separator(),
                    .command(String(localized: "탭 닫기"), symbol: "xmark") {
                        panes.count > 1 ? AppActions.closeTabs(model, panes) : AppActions.closeTab(model, tab.id)
                    },
                    .command(String(localized: "다른 탭 닫기"), symbol: "xmark.square", enabled: tabs.count > 1) {
                        AppActions.closeTabs(model, tabs.filter { $0.id != tab.id }.flatMap { model.panes(ofTab: $0.id) })
                    },
                    .command(String(localized: "오른쪽 탭 닫기"), symbol: "arrow.right.to.line", enabled: index + 1 < tabs.count) {
                        AppActions.closeTabs(model, tabs[(index + 1)...].flatMap { model.panes(ofTab: $0.id) })
                    },
                ]
            }
            .transition(.opacity)
        }
    }

    /// Which tab is active and which tabs exist: what the bar animates on.
    private var activeKey: [UUID] {
        guard let selection = scope.workspace(in: model) else { return [] }
        return [model.activeTabs[selection].map(model.head)].compactMap { $0 } + model.tabBarTabs(in: selection).map(\.id)
    }

}

/// The tabs side by side, all one width, as in Chrome: up to `maximumWidth`
/// each, narrower as tabs are added so the bar never asks for more room than
/// the window has, and no narrower than `minimumWidth` (past that the bar
/// scrolls them).
struct TabStrip: Layout {
    static let minimumWidth: CGFloat = 56
    static let maximumWidth: CGFloat = 200
    /// Every tab this wide, whatever the room (when they scroll).
    var fixedWidth: CGFloat?

    private func tabWidth(_ available: CGFloat?, _ count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        if let fixedWidth { return fixedWidth }
        return min(Self.maximumWidth, max(Self.minimumWidth, ((available ?? .infinity) / CGFloat(count)).rounded(.down)))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: tabWidth(proposal.width, subviews.count) * CGFloat(subviews.count), height: 34)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let width = tabWidth(bounds.width, subviews.count)
        for (index, subview) in subviews.enumerated() {
            subview.place(
                at: CGPoint(x: bounds.minX + CGFloat(index) * width, y: bounds.minY),
                proposal: ProposedViewSize(width: width, height: bounds.height))
        }
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

    /// What a tab is called, in the tab bar and the sidebar alike: the
    /// user's title if they gave one; for an agent, the title it gave its tab without the spinner in front (its
    /// name until it gives one); for anything else, its program's title.
    @MainActor
    static func label(_ tab: TerminalTab) -> String {
        if let custom = tab.customTitle { return custom }
        let title = display(tab.title, shell: AppModel.shellName)
        guard let agent = tab.agent else { return title }
        let topic = title.drop { !$0.isLetter && !$0.isNumber }
        return topic.isEmpty || topic == AppModel.shellName || topic == agent.rawValue ? agent.name : String(topic)
    }
}

private struct TabButton: View {
    /// The tab itself, not its title: the title is read here, so a new one
    /// redraws this button alone.
    let tab: TerminalTab
    let status: AgentStatus
    let isActive: Bool
    let showsDivider: Bool
    /// The title is an editable field right now.
    let isRenaming: Bool
    let select: () -> Void
    /// A double click on the title edits it in place, as a workspace's name.
    let startRename: () -> Void
    let close: () -> Void
    /// The new title (empty: the program's again), or nil if cancelled.
    let finishRename: (String?) -> Void
    @State private var hovering = false
    /// Squeezed by many tabs: the close button shows only under the pointer,
    /// so the name keeps the little room there is (⌘W still closes).
    @State private var narrow = false

    private var title: String { TabTitle.label(tab) }

    var body: some View {
        HStack(spacing: 2) {
            Button(action: select) {
                HStack(spacing: 8) {
                    if status != .idle { StatusMark(status: status) }
                    if let agent = tab.agent {
                        Image(nsImage: agent.icon).resizable().frame(width: 13, height: 13).accessibilityHidden(true)
                    }
                    let font = Font.system(size: 13, weight: isActive ? .medium : .regular)
                    if isRenaming {
                        RenameField(name: tab.customTitle ?? title, font: font, color: .white, prompt: "탭 제목", finish: finishRename)
                    } else {
                        Text(title)
                            .font(font)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .padding(.leading, narrow ? 10 : 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .simultaneousGesture(TapGesture(count: 2).onEnded { startRename() })
            .accessibilityLabel(status == .idle ? String(localized: "\(title) 탭") : String(localized: "\(title) 탭, \(status.label)"))
            .accessibilityAction(named: Text("제목 변경")) { startRename() }
            .accessibilityAddTraits(isActive ? .isSelected : [])

            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 20, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(hovering || (isActive && !narrow) ? 0.7 : 0)
            .frame(width: narrow && !hovering ? 0 : nil)
            .clipped()
            .accessibilityLabel("\(title) 탭 닫기")
        }
        .padding(.trailing, narrow && !hovering ? 2 : 6)
        .frame(maxWidth: .infinity)
        .frame(height: 34)
        .onGeometryChange(for: Bool.self) { $0.size.width < 90 } action: { narrow = $0 }
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Theme.selectedTab)
                .frame(width: 1, height: 16)
                .opacity(showsDivider ? 1 : 0)
                .accessibilityHidden(true)
        }
        .foregroundStyle(isActive ? Theme.strongText : hovering ? Theme.rowText : Theme.secondary)
        .background {
            if isActive {
                ChromeTabShape().fill(Theme.panelColor)
                    .overlay(alignment: .top) {
                        // A faint lit edge along the top, where the surface meets the strip.
                        Rectangle().fill(Theme.hairline).frame(height: 1).padding(.horizontal, 9)
                    }
                    .transition(.opacity)
            } else {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovering ? Theme.hoveredRow : .clear)
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

/// + at the end of the tabs: a dropdown of what the new tab starts, as in
/// Orca. ⌘T stays a plain terminal.
private struct NewTabButton: View {
    let open: (TabProgram) -> Void
    @State private var hovering = false
    @State private var anchor = DropdownAnchor()

    var body: some View {
        Button {
            DropdownPanel.toggle(TabProgram.dropdownItems(open), below: anchor)
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .medium))
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? Theme.hoveredRow : .clear))
                .contentShape(Rectangle())
                .dropdownAnchor(anchor)
        }
        .buttonStyle(.plain)
        .foregroundStyle(hovering ? Theme.text : Theme.secondary)
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
        .accessibilityLabel("새 탭")
        .help("새 탭: 터미널, Claude, Codex")
    }
}


/// Shown in the panel when the selection has no terminal.
struct EmptyStateView: View {
    let model: AppModel
    var scope = PanelScope.selection

    var body: some View {
        VStack(spacing: 12) {
            if scope == .selection, let selection = model.selection, model.ownWindows.contains(selection) {
                headline("이 워크스페이스는 따로 열린 창에 있습니다")
                Button("그 창으로 가기") { model.openInOwnWindow(selection) }
                    .buttonStyle(PlumButtonStyle(kind: .primary))
                    .padding(.top, 4)
            } else if model.state.projects.isEmpty {
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
                            default: Circle().strokeBorder(Theme.ring, lineWidth: 1.5).frame(width: 11, height: 11)
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
    let scope: PanelScope
    private let container = NSView()
    private var emptyState: NSView!
    private var toast: NSHostingView<ToastView>!
    private var toastBottom: NSLayoutConstraint!
    private var findBar: NSHostingView<FindBar>!
    /// The error the toast shows, or nil while it is hidden or going.
    private var shownError: String?
    private var font: (String, Double)
    /// The open tab's panes, side by side or stacked: one view each.
    private let panes = SplitContainerView()
    private var views: [UUID: TerminalView] = [:]
    /// The pane with the keyboard, and the layout drawn.
    private var shownActive: UUID?
    private var shownLayout: SplitNode?

    /// The terminal with the keyboard, if a tab is open.
    var terminal: TerminalView? { shownActive.flatMap { views[$0] } }

    init(model: AppModel, scope: PanelScope = .selection) {
        self.model = model
        self.scope = scope
        font = (model.state.settings.fontName, model.state.settings.fontSize)
        super.init(nibName: nil, bundle: nil)
        panes.onRatio = { [weak self] path, ratio, done in
            guard let self, let head = shownLayout?.panes.first.map(model.head) else { return }
            model.setSplitRatio(head, path: path, ratio: ratio, done: done)
        }
    }

    /// A view for one pane, wired to the model like every other.
    private func makeView(for session: TerminalSession) -> TerminalView {
        let terminal = TerminalView(fontName: font.0, fontSize: font.1)
        terminal.session = session
        terminal.onUserInput = { [weak model] session in
            MainActor.assumeIsolated { model?.userTyped(in: session.id) }
        }
        // A click in a pane gives it the keyboard.
        terminal.onFocus = { [weak model] session in
            MainActor.assumeIsolated {
                guard let model, let tab = model.terminal(session.id), model.activeTabs[tab.workspaceID] != session.id else { return }
                model.activateTab(session.id)
            }
        }
        terminal.onFind = { [weak self] in self?.showFind() }
        terminal.onSplit = { [weak model] axis in MainActor.assumeIsolated { _ = model?.splitPane(axis) } }
        terminal.confirmPaste = { [weak model] text, answer in
            guard let model else { return answer(false) }
            var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            if lines.last == "" { lines.removeLast() } // a final newline ends the last line, it isn't one more
            Task {
                answer(await AppActions.ask(model, Confirmation(
                    title: String(localized: "여러 줄을 붙여 넣을까요?"),
                    summary: String(localized: "붙여 넣는 내용에 줄바꿈이 있어 명령이 바로 실행될 수 있습니다."),
                    sections: [.init(title: String(localized: "붙여 넣을 내용"), lines: lines)],
                    action: String(localized: "붙여넣기"), destructive: false)))
            }
        }
        return terminal
    }

    /// New colors for every pane (the accent changed).
    func setTheme(_ theme: TerminalTheme) {
        for view in views.values { view.setTheme(theme) }
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

        let tabBar = NSHostingView(rootView: TabBarView(model: model, scope: scope))
        tabBar.safeAreaRegions = [] // it sits under the title bar on purpose
        // The bar fits the window, not the other way round: tabs narrow as
        // they're added instead of the bar asking for a wider window.
        tabBar.sizingOptions = []
        let empty = NSHostingView(rootView: EmptyStateView(model: model, scope: scope))
        empty.safeAreaRegions = []
        emptyState = empty
        // Sized to the toast itself, so the terminal still gets every other click.
        let toast = NSHostingView(rootView: ToastView())
        toast.safeAreaRegions = []
        toast.sizingOptions = [.intrinsicContentSize]
        toast.isHidden = true
        self.toast = toast

        let findBar = NSHostingView(rootView: FindBar(token: UUID(), search: { _ in (0, 0) }, step: { _ in (0, 0) }, close: {}))
        findBar.safeAreaRegions = []
        findBar.sizingOptions = [.intrinsicContentSize]
        findBar.isHidden = true
        self.findBar = findBar

        for view in [surface, panel, tabBar, container, toast, findBar] { view.translatesAutoresizingMaskIntoConstraints = false }
        root.addSubview(surface)
        surface.addSubview(panel)
        panel.addSubview(tabBar)
        panel.addSubview(container)
        panel.addSubview(toast)
        panel.addSubview(findBar)
        NSLayoutConstraint.activate([
            findBar.topAnchor.constraint(equalTo: tabBar.bottomAnchor, constant: 8),
            findBar.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -12),
            // Measured from the window's edges, not the safe area: the panel
            // runs up beside the window buttons.
            surface.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            // Beside the sidebar in the main window; inset from the edge alone.
            surface.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: scope == .selection ? 4 : 10),
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
        for view in [panes, emptyState!] {
            view.frame = container.bounds
            view.autoresizingMask = [.width, .height]
            container.addSubview(view)
        }
        panes.isHidden = true
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
        TerminalSession.optionAsMeta = settings.optionAsMeta
        if font != (settings.fontName, settings.fontSize) {
            font = (settings.fontName, settings.fontSize)
            for view in views.values { view.setFont(name: font.0, size: font.1) }
        }
        let shown = scope.workspace(in: model).flatMap(model.workspace)
        // Not shown, but still what VoiceOver and the Window menu read.
        view.window?.title = shown.map { workspace in
            "\(workspace.name) — \(model.project(workspace.projectID)?.name ?? "")"
        } ?? "Plum"
        if scope == .selection { syncToast() } // errors show in the main window
        // A window of its own goes with its workspace.
        if case .workspace = scope, shown == nil || shown?.isArchived == true || !model.ownWindows.contains(shown?.id ?? UUID()) {
            DispatchQueue.main.async { [weak self] in self?.view.window?.close() }
        }

        let active = shown.flatMap { model.activeTabs[$0.id] }.flatMap(model.terminal)
        let layout = active.map { model.layout(of: model.head(of: $0.id)) }
        guard active?.id != shownActive || layout != shownLayout else { return }
        let focusMoved = active?.id != shownActive
        if focusMoved { closeFind(refocus: false) } // a search belongs to the terminal it was typed for
        shownActive = active?.id
        shownLayout = layout

        // A view for each pane on screen; the others let go of theirs (each
        // holds full-size drawing buffers).
        let ids = layout?.panes ?? []
        for (id, view) in views where !ids.contains(id) {
            view.session = nil
            view.removeFromSuperview()
            views[id] = nil
        }
        for id in ids where views[id] == nil {
            guard let session = model.terminal(id)?.session else { continue }
            views[id] = makeView(for: session)
        }
        if let layout { panes.show(layout, views: views, focused: active?.id) }
        panes.isHidden = active == nil
        emptyState.isHidden = active != nil
        // Don't steal focus from a field in an open dialog.
        if focusMoved, let terminal, model.sheet == nil { view.window?.makeFirstResponder(terminal) }
    }

    // MARK: Find

    /// ⌘F: a bar over the terminal's top right corner. Matches are looked
    /// for as you type; the one selected is drawn as the selection.
    func showFind() {
        guard terminal?.session != nil else { return }
        findBar.rootView = FindBar(
            token: UUID(),
            search: { [weak self] query in self?.find { $0.find(query) } ?? (0, 0) },
            step: { [weak self] backward in self?.find { $0.findNext(backward: backward) } ?? (0, 0) },
            close: { [weak self] in self?.closeFind(refocus: true) })
        findBar.isHidden = false
        view.window?.makeFirstResponder(findBar)
    }

    /// ⌘G and ⇧⌘G. With no bar open, they open it.
    func findNext(backward: Bool) {
        guard !findBar.isHidden else { return showFind() }
        _ = find { $0.findNext(backward: backward) }
    }

    private func find(_ run: (TerminalSession) -> (Int, Int)) -> (Int, Int) {
        guard let terminal, let session = terminal.session else { return (0, 0) }
        let result = run(session)
        terminal.selectionChanged()
        return result
    }

    private func closeFind(refocus: Bool) {
        guard !findBar.isHidden else { return }
        findBar.isHidden = true
        terminal?.session?.endFind()
        terminal?.selectionChanged()
        if refocus, let terminal { view.window?.makeFirstResponder(terminal) }
    }

    /// Slides the toast in when an error arrives and fades it out when it is
    /// dismissed. Core Animation runs both, off the main thread's clock.
    private func syncToast() {
        let error = model.errorMessage
        // An update waits behind errors and news of work under way.
        let update = error == nil && model.notice == nil ? model.availableUpdate : nil
        let message = error ?? model.notice ?? update.map { String(localized: "새 버전이 있습니다: \($0.tag)") }
        guard message != shownError else { return }
        let wasShown = shownError != nil
        shownError = message
        let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if let message {
            let install = update.map { release in
                (title: LocalizedStringKey("설치…"), run: { [weak model] in
                    guard let model else { return }
                    Task { await AppActions.offerUpdate(model, release) }
                })
            }
            toast.rootView = ToastView(message: message, isError: error != nil, action: install) { [weak model] in
                guard let model else { return }
                if update != nil { return model.availableUpdate = nil }
                model.errorMessage = nil
                model.notice = nil
            }
            // It is easy to miss without sight: read it out.
            NSAccessibility.post(
                element: NSApp as Any, notification: .announcementRequested,
                userInfo: [.announcement: error != nil ? String(localized: "문제가 생겼습니다. \(message)") : message,
                           .priority: NSAccessibilityPriorityLevel.high.rawValue])
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
        if let terminal, !panes.isHidden { view.window?.makeFirstResponder(terminal) }
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
    /// The sidebar's width when open: the user's, or the default.
    private var openWidth: CGFloat
    private let sidebarEdge = SidebarEdge()
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
        openWidth = Self.clamp(model.state.sidebarWidth.map { CGFloat($0) } ?? Theme.sidebarWidth)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let root = NSView()
        addChild(sidebar)
        addChild(terminalArea)
        sidebar.view.clipsToBounds = true
        for view in [sidebar.view, terminalArea.view, sidebarEdge] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        sidebarEdge.drag = { [weak self] x in
            guard let self else { return }
            openWidth = Self.clamp(x, in: view.bounds.width)
            sidebarWidth.constant = openWidth
        }
        sidebarEdge.dragEnded = { [weak self] in
            guard let self else { return }
            model.setSidebarWidth(openWidth == Theme.sidebarWidth ? nil : Double(openWidth))
        }
        sidebarEdge.reset = { [weak self] in
            guard let self else { return }
            openWidth = Theme.sidebarWidth
            model.setSidebarWidth(nil)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.allowsImplicitAnimation = true
                self.sidebarWidth.animator().constant = self.openWidth
            }
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
        sidebarWidth = sidebar.view.widthAnchor.constraint(equalToConstant: openWidth)
        NSLayoutConstraint.activate([
            sidebarWidth,
            // A grip a few points either side of the line where sidebar meets panel.
            sidebarEdge.centerXAnchor.constraint(equalTo: sidebar.view.trailingAnchor),
            sidebarEdge.widthAnchor.constraint(equalToConstant: 8),
            sidebarEdge.topAnchor.constraint(equalTo: root.topAnchor),
            sidebarEdge.bottomAnchor.constraint(equalTo: root.bottomAnchor),
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
        observeRenaming()
    }

    /// The widths the sidebar may be dragged to, leaving the terminal room.
    private static func clamp(_ width: CGFloat, in windowWidth: CGFloat = .infinity) -> CGFloat {
        min(max(width, 180), min(420, windowWidth - 400)).rounded()
    }

    /// When a name being edited in the sidebar or a tab's title being
    /// edited in the tab bar is done, typing goes back to the terminal.
    private func observeRenaming() {
        let renaming = withObservationTracking { (model.renaming, model.renamingTab) } onChange: { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.observeRenaming() } }
        }
        guard renaming == (nil, nil) else { return }
        // Once SwiftUI has removed the field, the keyboard is with the
        // window itself, or somewhere in the sidebar or the tab bar.
        DispatchQueue.main.async { [weak self] in
            guard let self, model.sheet == nil, model.renaming == nil, model.renamingTab == nil, let window = view.window else { return }
            let responder = window.firstResponder
            let inside = { (area: NSView) in (responder as? NSView)?.isDescendant(of: area) == true }
            if responder === window || inside(sidebar.view) || inside(terminalArea.view) {
                terminalArea.focusTerminal()
            }
        }
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
        // Dialogs open in the main window: bring it up if another window is in front.
        if sheet != nil, view.window?.isKeyWindow == false { view.window?.makeKeyAndOrderFront(nil) }
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
}

/// The line between sidebar and terminal panel: drag it to resize the
/// sidebar, double-click it for the default width.
final class SidebarEdge: NSView {
    /// Called with the pointer's x in the window's content view.
    var drag: (CGFloat) -> Void = { _ in }
    var dragEnded: () -> Void = {}
    var reset: () -> Void = {}

    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    // The window moves by its background; without this the edge counts as
    // background and a drag here moves the window instead.
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { reset() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let superview else { return }
        // The pointer may leave the grip mid-drag; keep the resize cursor.
        NSCursor.resizeLeftRight.set()
        drag(superview.convert(event.locationInWindow, from: nil).x)
    }

    override func mouseUp(with event: NSEvent) {
        if event.clickCount < 2 { dragEnded() }
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
        // The window moves by that title bar strip only, not by its whole
        // background: there a drag or double-click on a sidebar row or the
        // sidebar's edge would move the window instead of reaching them.

        super.init(window: window)
        window.contentViewController = root
        window.setContentSize(NSSize(width: 1180, height: 760))
        window.center()
        window.setFrameAutosaveName("PlumMainWindow")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    public func focusSidebar() { root.focusSidebar() }
    func traceDialogClose(_ done: @escaping (String) -> Void) { root.traceDialogClose(done) }
    public func focusTerminal() { root.terminalArea.focusTerminal() }
    var terminalView: TerminalView? { root.terminalArea.terminal }
    var terminalArea: TerminalAreaController { root.terminalArea }
}

/// The find bar: a field, "3/12", previous and next, close.
struct FindBar: View {
    /// A new one each time the bar opens, so it starts empty and focused.
    let token: UUID
    let search: (String) -> (Int, Int)
    let step: (_ backward: Bool) -> (Int, Int)
    let close: () -> Void

    var body: some View { FindField(search: search, step: step, close: close).id(token) }
}

private struct FindField: View {
    let search: (String) -> (Int, Int)
    let step: (Bool) -> (Int, Int)
    let close: () -> Void
    @State private var query = ""
    @State private var result = (0, 0)
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.tertiary)
            TextField("찾기", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Theme.text)
                .frame(width: 170)
                .focused($focused)
                .onSubmit { result = step(NSEvent.modifierFlags.contains(.shift)) } // ⇧Return goes back
                .onExitCommand(perform: close)
                .onChange(of: query) { result = search(query) }
            Text(verbatim: query.isEmpty ? "" : result.1 == 0 ? String(localized: "없음") : "\(result.0)/\(result.1)")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(result.1 == 0 ? Theme.danger : Theme.tertiary)
                .frame(minWidth: 38, alignment: .trailing)
            button("chevron.up", "다음 찾기") { result = step(false) }
            button("chevron.down", "이전 찾기") { result = step(true) }
            button("xmark", "찾기 닫기", action: close)
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.fieldBorder))
        .shadow(color: .black.opacity(Theme.shadowOpacity), radius: 10, y: 4)
        .onAppear { focused = true }
    }

    // "Next" is the next one up into older output, so its arrow points up.
    private func button(_ symbol: String, _ label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).frame(width: 24, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.secondary)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// The open tab's panes laid out as its split says, with a thin line
/// between them that can be dragged. Panes without the keyboard are dimmed.
final class SplitContainerView: NSView {
    /// A divider moved: where it is in the split, its new share, and
    /// whether the drag is over.
    var onRatio: ((_ path: [Bool], _ ratio: Double, _ done: Bool) -> Void)?
    private var node: SplitNode?
    private var paneViews: [UUID: NSView] = [:]
    private var dividers: [SplitDivider] = []

    override var isFlipped: Bool { true }

    func show(_ node: SplitNode, views: [UUID: NSView], focused: UUID?) {
        self.node = node
        paneViews = views.filter { node.panes.contains($0.key) }
        for (id, view) in paneViews {
            if view.superview !== self { addSubview(view) }
            view.alphaValue = paneViews.count > 1 && id != focused ? 0.62 : 1
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard let node else { return }
        var used = 0
        place(node, in: bounds, path: [], dividersUsed: &used)
        while dividers.count > used { dividers.removeLast().removeFromSuperview() }
    }

    private func place(_ node: SplitNode, in rect: CGRect, path: [Bool], dividersUsed: inout Int) {
        switch node {
        case let .pane(id):
            paneViews[id]?.frame = rect.integral
        case let .split(axis, ratio, first, second):
            let (a, b) = SplitNode.divide(rect, axis, ratio)
            let line: CGFloat = 1
            // The line takes a point from the pane after it.
            let after = axis == .horizontal
                ? CGRect(x: b.minX + line, y: b.minY, width: b.width - line, height: b.height)
                : CGRect(x: b.minX, y: b.minY + line, width: b.width, height: b.height - line)
            if dividers.count <= dividersUsed {
                let divider = SplitDivider()
                divider.onRatio = { [weak self] path, ratio, done in self?.onRatio?(path, ratio, done) }
                addSubview(divider)
                dividers.append(divider)
            }
            let divider = dividers[dividersUsed]
            dividersUsed += 1
            divider.axis = axis
            divider.path = path
            divider.span = rect
            // A wide grip around a thin line.
            divider.frame = axis == .horizontal
                ? CGRect(x: b.minX - 3, y: rect.minY, width: line + 6, height: rect.height)
                : CGRect(x: rect.minX, y: b.minY - 3, width: rect.width, height: line + 6)
            place(first, in: a, path: path + [false], dividersUsed: &dividersUsed)
            place(second, in: after, path: path + [true], dividersUsed: &dividersUsed)
            divider.removeFromSuperview()
            addSubview(divider) // above the panes, to be grabbed
        }
    }
}

/// The line between two panes. Drag it to share the space differently.
final class SplitDivider: NSView {
    var axis = SplitNode.Axis.horizontal
    var path: [Bool] = []
    /// The space the two panes share, in the container's coordinates.
    var span = CGRect.zero
    var onRatio: (([Bool], Double, Bool) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(Theme.divider).setFill()
        let line = axis == .horizontal ? CGRect(x: 3, y: 0, width: 1, height: bounds.height) : CGRect(x: 0, y: 3, width: bounds.width, height: 1)
        line.fill()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: axis == .horizontal ? .resizeLeftRight : .resizeUpDown)
    }

    override func mouseDragged(with event: NSEvent) { report(event, done: false) }
    override func mouseUp(with event: NSEvent) { report(event, done: true) }

    private func report(_ event: NSEvent, done: Bool) {
        guard let container = superview, span.width > 0, span.height > 0 else { return }
        let point = container.convert(event.locationInWindow, from: nil)
        let ratio = axis == .horizontal ? (point.x - span.minX) / span.width : (point.y - span.minY) / span.height
        onRatio?(path, Double(ratio), done)
    }
}

/// One workspace in a window of its own: its tabs and terminals, no
/// sidebar. Closing it gives the workspace back to the main window; its
/// terminals keep running.
final class WorkspaceWindowController: NSWindowController, NSWindowDelegate {
    let workspaceID: UUID
    let area: TerminalAreaController
    private let model: AppModel
    var onClose: (() -> Void)?

    init(model: AppModel, workspaceID: UUID) {
        self.model = model
        self.workspaceID = workspaceID
        area = TerminalAreaController(model: model, scope: .workspace(workspaceID))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.minSize = NSSize(width: 480, height: 300)
        window.tabbingMode = .disallowed
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = Theme.backdrop
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.toolbar = NSToolbar(identifier: "PlumWorkspace")
        window.toolbarStyle = .unified
        super.init(window: window)
        window.delegate = self
        window.contentViewController = area
        window.setContentSize(NSSize(width: 900, height: 620))
        // Where it was last time, or the middle of the screen.
        let name = "PlumWorkspace-\(workspaceID.uuidString)"
        if !window.setFrameUsingName(name) { window.center() }
        window.setFrameAutosaveName(name)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    // Menus and shortcuts act on the window in front: its workspace is the selection.
    func windowDidBecomeKey(_ notification: Notification) {
        if model.selection != workspaceID { model.select(workspaceID) }
    }

    func windowWillClose(_ notification: Notification) {
        model.closeOwnWindow(workspaceID)
        onClose?()
    }
}
