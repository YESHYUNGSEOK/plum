import SwiftUI

extension AgentStatus {
    var color: Color { Color(nsColor: nsColor) }

    var nsColor: NSColor {
        switch self {
        case .idle: .clear
        case .monitoring: Theme.monitoringNS
        case .working: Theme.workingNS
        case .waiting: Theme.waitingNS
        case .done: Theme.doneNS
        }
    }

    var label: String {
        switch self {
        case .idle: ""
        case .monitoring: String(localized: "모니터링 중")
        case .working: String(localized: "작업 중")
        case .waiting: String(localized: "입력 대기")
        case .done: String(localized: "완료")
        }
    }
}

/// A borderless icon button in the sidebar's quiet gray.
private struct IconButton: View {
    let systemName: String
    let label: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Theme.hoveredRow : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(hovering ? Theme.text : Theme.secondary)
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
        .accessibilityLabel(label)
        .help(label)
    }
}

/// "Add Project" at the top of the sidebar: as wide as the cards, a thin
/// outline that lights up under the pointer.
private struct AddProjectButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: "plus").font(.system(size: 11, weight: .medium))
                Text("프로젝트 추가").font(.system(size: 13))
            }
            .foregroundStyle(hovering ? Theme.rowText : Theme.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 9).fill(hovering ? Theme.hoveredRow : .clear))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.fieldBorder))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
        .help("프로젝트 추가 (⌘O)")
    }
}

/// Projects and their workspaces, drawn straight on the window's ground.
struct SidebarView: View {
    let model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            AddProjectButton { AppActions.addProject(model) }
                // In line with the cards below.
                .padding(.init(top: 2, leading: 12, bottom: 4, trailing: 4))
            if model.state.projects.isEmpty {
                Spacer()
                Text("프로젝트가 없습니다")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondary)
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        AttentionSection(model: model)
                        ForEach(model.state.projects) { project in
                            ProjectSection(model: model, project: project)
                        }
                    }
                    .padding(.init(top: 8, leading: 12, bottom: 12, trailing: 4))
                    // Workspaces come, go and change state: let the list move, not jump.
                    .animation(Motion.layout(reduceMotion), value: layoutKey)
                }
            }
            HStack {
                Spacer()
                IconButton(systemName: "slider.horizontal.3", label: String(localized: "설정")) { model.sheet = .settings }
            }
            .padding(.horizontal, 22)
            .frame(height: 46)
        }
        // As wide as the window makes it (the user can drag its edge). While
        // it folds away it keeps a minimum width and is clipped, not squeezed.
        .frame(minWidth: 180, maxWidth: .infinity, alignment: .leading)
        // A new accent is a static value no view watches: draw everything again.
        .id(model.state.settings.accent)
    }

    /// Changes whenever a row appears, disappears or moves, a tab's line included.
    private var layoutKey: [UUID] {
        let shown = model.state.projects.flatMap { model.workspaces(in: $0) }
        let attention = shown.filter { [.waiting, .done].contains(model.status(of: $0.id)) }.map(\.id)
        let tabs = shown.flatMap { model.tabs[$0.id] ?? [] }.map(\.id)
        return attention + model.state.workspaces.map(\.id) + model.pending.map(\.id) + tabs
    }
}

/// Workspaces that finished or wait for an answer, from every project, on
/// top so they are found without scanning the list.
private struct AttentionSection: View {
    let model: AppModel

    private struct Item {
        let workspace: Workspace
        let project: String
        let status: AgentStatus
    }

    private var items: [Item] {
        var found: [Item] = []
        for project in model.state.projects {
            for workspace in model.workspaces(in: project) {
                let status = model.status(of: workspace.id)
                if status == .waiting || status == .done { found.append(Item(workspace: workspace, project: project.name, status: status)) }
            }
        }
        return found.sorted { $0.status.urgency > $1.status.urgency }
    }

    var body: some View {
        let items = items
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                let waiting = items.filter { $0.status == .waiting }.count
                let done = items.count - waiting
                HStack(spacing: 8) {
                    Text("확인 필요").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text)
                    // A chip for each kind, so what is waiting reads apart from what is done.
                    HStack(spacing: 4) {
                        ForEach([(AgentStatus.waiting, waiting), (.done, done)].filter { $0.1 > 0 }, id: \.0) { status, count in
                            HStack(spacing: 4) {
                                StatusMark(status: status, size: 10)
                                Text(verbatim: "\(count)")
                                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                                    .foregroundStyle(Theme.rowText)
                            }
                            .padding(.leading, 4)
                            .padding(.trailing, 6)
                            .frame(height: 18)
                            .background(Capsule().fill(Theme.selectedTab))
                        }
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 26)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("확인 필요: 입력 대기 \(waiting)개, 완료 \(done)개")

                ForEach(items, id: \.workspace.id) { item in
                    SidebarRow(
                        name: item.workspace.name, status: item.status, isSelected: false,
                        select: { model.select(item.workspace.id) }
                    ) {
                        Text(item.project).font(.system(size: 11)).foregroundStyle(Theme.tertiary).lineLimit(1)
                    }
                    .transition(.opacity)
                }
            }
            .transition(.opacity)
            .padding(.bottom, 12)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.divider).frame(height: 1).padding(.horizontal, 10) }
        }
    }
}

private struct ProjectSection: View {
    let model: AppModel
    let project: Project
    @State private var showsArchived = false
    @State private var drag: Drag?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// A workspace being dragged to a new place: the row it started on, and
    /// how far the pointer has gone since.
    private struct Drag {
        let id: UUID
        let from: Int
        var offset: CGFloat = 0
    }

    /// How tall each of this project's rows is, for dragging: rows are as
    /// tall as what they show. Heights, not frames: a drag's offsets move
    /// rows on screen, and a frame read then would no longer say where the
    /// row is laid out.
    @State private var heights: [UUID: CGFloat] = [:]

    /// Where each row starts, from the top of the first, and how tall it is.
    private func layout(_ rows: [Workspace]) -> [(top: CGFloat, height: CGFloat)] {
        var top: CGFloat = 0
        return rows.map { row in
            let height = heights[row.id] ?? 0
            defer { top += height + 2 } // the gap between rows
            return (top, height)
        }
    }

    /// The row a dragged workspace would land on: past the middle of each
    /// row it was dragged over.
    private func landing(of drag: Drag, in rows: [Workspace]) -> Int {
        let places = layout(rows)
        guard places.indices.contains(drag.from) else { return drag.from }
        let middle = places[drag.from].top + places[drag.from].height / 2 + drag.offset
        var landing = drag.from
        for (index, place) in places.enumerated() {
            if index > drag.from, middle > place.top + place.height / 2 { landing = max(landing, index) }
            if index < drag.from, middle < place.top + place.height / 2 { landing = min(landing, index) }
        }
        return landing
    }

    /// Where a row is drawn while one is dragged: the dragged one under the
    /// pointer, kept among its project's rows; the ones it passed, moved
    /// over to make room.
    private func offset(of index: Int, in rows: [Workspace], landing: Int?) -> CGFloat {
        guard let drag, let landing else { return 0 }
        let places = layout(rows)
        guard places.indices.contains(drag.from), let last = places.last else { return 0 }
        let moving = places[drag.from]
        if index == drag.from {
            return min(max(drag.offset, -moving.top), last.top + last.height - moving.top - moving.height)
        }
        let room = moving.height + 2 // the row and the gap under it
        if drag.from < index, index <= landing { return -room }
        if landing <= index, index < drag.from { return room }
        return 0
    }

    /// Dragging a workspace up or down puts it in a new place among its
    /// project's workspaces, saved when the button comes up.
    private func reorder(_ workspace: Workspace, at index: Int, in rows: [Workspace]) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .onChanged { value in
                if drag == nil { drag = Drag(id: workspace.id, from: index) }
                drag?.offset = value.translation.height
            }
            .onEnded { _ in
                guard let drag else { return }
                let steps = landing(of: drag, in: rows) - drag.from
                withAnimation(Motion.layout(reduceMotion)) {
                    self.drag = nil
                    model.moveWorkspace(drag.id, by: steps)
                }
            }
    }

    private var collapsed: Bool { model.state.collapsedProjects.contains(project.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ProjectHeader(model: model, project: project, collapsed: collapsed) {
                withAnimation(Motion.layout(reduceMotion)) { model.setCollapsed(project.id, !collapsed) }
            }
            .plumMenu { projectMenu() }
            if !collapsed { rows }
        }
    }

    /// The project's workspaces: its own checkout, the others in the user's
    /// order, those being made, then the archived ones folded away.
    @ViewBuilder
    private var rows: some View {
        let rows = model.workspaces(in: project)
        let target = drag.map { landing(of: $0, in: rows) }
        ForEach(Array(rows.enumerated()), id: \.element.id) { index, workspace in
            let dragged = drag?.id == workspace.id
            WorkspaceRow(model: model, workspace: workspace)
                .plumMenu { workspaceMenu(workspace) }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { heights[workspace.id] = $0 }
                // Lifted while dragged: it covers the rows it passes over.
                .background(
                    RoundedRectangle(cornerRadius: 9)
                        .fill(Color(nsColor: Theme.backdrop))
                        .shadow(color: .black.opacity(Theme.shadowOpacity), radius: 10, y: 3)
                        .opacity(dragged ? 1 : 0))
                .offset(y: offset(of: index, in: rows, landing: target))
                .animation(dragged ? nil : Motion.layout(reduceMotion), value: target)
                .zIndex(dragged ? 1 : 0)
                .simultaneousGesture(reorder(workspace, at: index, in: rows),
                                     including: model.renaming == workspace.id ? .subviews : .all)
                .transition(.opacity)
        }
        ForEach(model.pending.filter { $0.projectID == project.id }) { pending in
            SidebarRow(name: pending.name, isSelected: model.selection == pending.id, select: { model.select(pending.id) }) {
                ProgressView().controlSize(.small).accessibilityLabel("만드는 중")
            }
            .transition(.opacity)
        }

        let archived = model.workspaces(in: project, archived: true)
        if !archived.isEmpty {
            Button {
                withAnimation(Motion.layout(reduceMotion)) { showsArchived.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .rotationEffect(.degrees(showsArchived ? 90 : 0))
                    Text("아카이브 \(archived.count)")
                        .font(.system(size: 12))
                    Spacer()
                }
                .padding(.horizontal, 10)
                .frame(height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.secondary)
            .accessibilityLabel(showsArchived
                ? String(localized: "아카이브된 워크스페이스 \(archived.count)개 접기")
                : String(localized: "아카이브된 워크스페이스 \(archived.count)개 펼치기"))

            if showsArchived {
                ForEach(archived) { workspace in
                    WorkspaceRow(model: model, workspace: workspace)
                        .plumMenu { workspaceMenu(workspace) }
                        .transition(.opacity)
                }
            }
        }
    }

    /// What a right-click on a project's name offers.
    private func projectMenu() -> [DropdownItem] {
        var items: [DropdownItem] = [
            .command(String(localized: "새 워크스페이스…"), symbol: "plus") { model.sheet = .newWorkspace(project) },
            .command(String(localized: "프로젝트 설정…"), symbol: "slider.horizontal.3") { model.sheet = .projectSettings(project) },
            .command(String(localized: "기존 워크트리 가져오기"), symbol: "square.and.arrow.down") {
                Task {
                    if await model.importWorktrees(of: project.id) == 0 {
                        model.errorMessage = String(localized: "가져올 워크트리가 없습니다. 이 저장소의 워크트리는 모두 목록에 있습니다.")
                    }
                }
            },
            collapsed
                ? .command(String(localized: "펼치기"), symbol: "chevron.down") { model.setCollapsed(project.id, false) }
                : .command(String(localized: "접기"), symbol: "chevron.right") { model.setCollapsed(project.id, true) },
            .separator(),
            .command(String(localized: "Finder에서 보기"), symbol: "folder") {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: project.path)
            },
        ]
        if let openIn = ExternalApp.openIn(project.path) { items.append(openIn) }
        items += [
            .separator(),
            .command(String(localized: "Plum에서 프로젝트 제거"), symbol: "minus.circle", destructive: true) {
                AppActions.removeProject(model, project)
            },
        ]
        return items
    }

    /// What a right-click on a workspace offers, grouped as on macOS: change
    /// it, then what can't be undone, then where to see or copy it.
    private func workspaceMenu(_ workspace: Workspace) -> [DropdownItem] {
        var items: [DropdownItem] = [.command(String(localized: "이름 바꾸기"), symbol: "pencil") { model.renaming = workspace.id }]
        if model.status(of: workspace.id) == .done {
            items.append(.command(String(localized: "읽음으로 표시"), symbol: "checkmark.circle") { model.markRead(workspace.id) })
        }
        let open = model.tabs[workspace.id] ?? []
        if !open.isEmpty {
            // Frees what its programs hold; the worktree stays as it is.
            items.append(.command(String(localized: "탭 모두 닫기"), symbol: "xmark.square") { AppActions.closeTabs(model, open.map(\.id)) })
        }
        items.append(.separator())
        if model.isMain(workspace) {
            // The project's own checkout is the repository itself.
            items += [
                .command(String(localized: "작업 트리 삭제"), symbol: "trash", enabled: false) {},
                .note(String(localized: "기본 체크아웃은 삭제할 수 없습니다.") + " " + String(localized: "대신 프로젝트를 목록에서 제거하세요.")),
                .command(String(localized: "Plum에서 프로젝트 제거"), symbol: "minus.circle", destructive: true) {
                    AppActions.removeProject(model, project)
                },
            ]
        } else {
            items.append(workspace.isArchived
                ? .command(String(localized: "복원"), symbol: "arrow.uturn.backward") { AppActions.restore(model, workspace) }
                : .command(String(localized: "아카이브"), symbol: "archivebox") { AppActions.archive(model, workspace) })
            items.append(.command(workspace.isArchived ? String(localized: "브랜치 삭제…") : String(localized: "작업 트리 삭제…"),
                                  symbol: "trash", destructive: true) { AppActions.delete(model, workspace) })
        }
        items.append(.separator())
        if !workspace.isArchived {
            items.append(.command(String(localized: "Finder에서 보기"), symbol: "folder") {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: workspace.path)
            })
            if let openIn = ExternalApp.openIn(workspace.path) { items.append(openIn) }
        }
        let pullRequest = model.pullRequest(of: workspace)
        if !workspace.isArchived {
            items.append(.command(String(localized: "변경 보기"), symbol: "plus.forwardslash.minus") { model.sheet = .diff(workspace) })
            items.append(.command(String(localized: "새 창에서 열기"), symbol: "macwindow.badge.plus") { model.openInOwnWindow(workspace.id) })
        }
        if let pullRequest {
            items.append(.command(String(localized: "PR #\(pullRequest.number) 열기"), symbol: "arrow.triangle.pull") {
                NSWorkspace.shared.open(pullRequest.url)
            })
        } else if !workspace.isArchived, !model.isMain(workspace) {
            items.append(.command(String(localized: "PR 만들기"), symbol: "arrow.triangle.pull") { model.createPullRequest(workspace.id) })
        }
        var copies: [DropdownItem] = [.command(String(localized: "경로"), symbol: "folder") { copy(workspace.path) }]
        let branch = model.branch(of: workspace)
        if !branch.isEmpty { copies.append(.command(String(localized: "브랜치 이름"), symbol: "arrow.triangle.branch") { copy(branch) }) }
        if let pullRequest { copies.append(.command(String(localized: "PR 링크"), symbol: "link") { copy(pullRequest.url.absoluteString) }) }
        items.append(.submenu(String(localized: "복사"), symbol: "doc.on.doc", copies))
        return items
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct WorkspaceRow: View {
    let model: AppModel
    let workspace: Workspace
    /// More than this many tabs fold into a "more" line.
    private static let shownTabs = 4
    @State private var showsAllTabs = false

    var body: some View {
        let branch = model.branch(of: workspace)
        let tabs = workspace.isArchived ? [] : model.tabs[workspace.id] ?? []
        let isSelected = model.selection == workspace.id
        SidebarRow(
            name: workspace.name, status: model.status(of: workspace.id), isSelected: isSelected,
            dimmed: workspace.isArchived, hasKeyboard: model.sidebarHasKeyboard && isSelected,
            isRenaming: model.renaming == workspace.id, isMain: model.isMain(workspace),
            select: { model.select(workspace.id) },
            startRename: { model.renaming = workspace.id },
            finishRename: { newName in
                model.renaming = nil
                if let newName, let problem = model.renameWorkspace(workspace.id, to: newName) { model.errorMessage = problem }
            }
        ) {
            if model.busy.contains(workspace.id) {
                ProgressView().controlSize(.small)
            } else if !workspace.isArchived, !model.folderExists(workspace) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.waiting)
                    .help("폴더가 없습니다")
                    .accessibilityLabel("폴더 없음")
            }
        } details: {
            if !branch.isEmpty || !tabs.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    if !branch.isEmpty {
                        BranchLine(
                            branch: branch, changes: workspace.isArchived ? nil : model.changes[workspace.id],
                            pullRequest: model.pullRequest(of: workspace), select: { model.select(workspace.id) },
                            showChanges: { model.sheet = .diff(workspace) })
                    }
                    ForEach(showsAllTabs ? tabs[...] : tabs.prefix(Self.shownTabs)) { tab in
                        TabLine(
                            tab: tab, status: model.statuses[tab.id] ?? .idle,
                            isActive: isSelected && model.activeTabs[workspace.id] == tab.id,
                            show: { model.reveal(tab: tab.id) },
                            close: { AppActions.closeTab(model, tab.id) })
                        .transition(.opacity)
                    }
                    if tabs.count > Self.shownTabs {
                        let hidden = tabs.dropFirst(Self.shownTabs)
                        MoreTabsLine(
                            hidden: hidden.count, expanded: showsAllTabs,
                            // What the folded tabs are doing, so a waiting one isn't missed.
                            status: hidden.map { model.statuses[$0.id] ?? .idle }.max { $0.urgency < $1.urgency } ?? .idle
                        ) { showsAllTabs.toggle() }
                        .transition(.opacity)
                    }
                }
                // Under the name: past the state mark and the gap after it.
                .padding(.leading, 20)
            }
        }
        .help(branch.isEmpty ? workspace.path : "\(branch)\n\(workspace.path)")
    }
}

/// One row of the sidebar: state mark, name, and whatever goes at the end;
/// under it, for a workspace, its branch and tabs.
private struct SidebarRow<Trailing: View, Details: View>: View {
    let name: String
    let status: AgentStatus
    let isSelected: Bool
    let dimmed: Bool
    /// The sidebar's keyboard mode is on this row.
    let hasKeyboard: Bool
    /// The name is an editable field right now.
    let isRenaming: Bool
    /// The project's own checkout, marked as such.
    let isMain: Bool
    let select: () -> Void
    /// Double-clicking the name starts renaming; nil where it can't be renamed.
    let startRename: (() -> Void)?
    /// The new name, or nil when renaming was cancelled.
    let finishRename: (String?) -> Void
    let trailing: Trailing
    let details: Details
    @State private var hovering = false

    init(
        name: String, status: AgentStatus = .idle, isSelected: Bool, dimmed: Bool = false, hasKeyboard: Bool = false,
        isRenaming: Bool = false, isMain: Bool = false, select: @escaping () -> Void, startRename: (() -> Void)? = nil,
        finishRename: @escaping (String?) -> Void = { _ in },
        @ViewBuilder trailing: () -> Trailing, @ViewBuilder details: () -> Details
    ) {
        self.name = name
        self.status = status
        self.isSelected = isSelected
        self.dimmed = dimmed
        self.hasKeyboard = hasKeyboard
        self.isRenaming = isRenaming
        self.isMain = isMain
        self.select = select
        self.startRename = startRename
        self.finishRename = finishRename
        self.trailing = trailing()
        self.details = details()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Button(action: select) { header }
                .buttonStyle(RowButtonStyle())
                .simultaneousGesture(TapGesture(count: 2).onEnded { startRename?() })
            details
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            // While the name is being edited, only the field shows.
            RoundedRectangle(cornerRadius: 9)
                .fill(isRenaming ? .clear : isSelected ? Theme.selectedRow : hovering ? Theme.hoveredRow : .clear)
                .animation(Motion.hover, value: hovering)
                .animation(Motion.settle, value: isSelected)
                .animation(Motion.settle, value: isRenaming))
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(Theme.accent, lineWidth: 1.5)
                .opacity(hasKeyboard ? 1 : 0)
                .animation(Motion.settle, value: hasKeyboard))
        .contentShape(Rectangle())
        // The lines are buttons of their own (the name, the branch, each
        // tab); this catches the gaps between them.
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction(named: Text("이름 바꾸기")) { startRename?() }
    }

    /// State mark, name (or the field editing it), and what goes at the end.
    private var header: some View {
        HStack(spacing: 8) {
            StatusMark(status: status)
            // The field is the name made editable, set exactly like it:
            // nothing moves when editing starts.
            let font = Font.system(size: 13, weight: isSelected ? .semibold : .regular)
            let color = isSelected ? Theme.strongText : dimmed ? Theme.secondary : Theme.rowText
            if isRenaming {
                RenameField(name: name, font: font, color: color, finish: finishRename)
            } else {
                Text(name)
                    .font(font)
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if isMain {
                Text("기본")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.secondary)
                    .padding(.horizontal, 5)
                    .frame(height: 16)
                    .background(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.divider))
            }
            Spacer(minLength: 4)
            trailing
        }
        .frame(height: 20)
        .contentShape(Rectangle())
    }
}

extension SidebarRow where Details == EmptyView {
    /// A one-line row: a workspace that needs attention, or one being made.
    init(name: String, status: AgentStatus = .idle, isSelected: Bool, select: @escaping () -> Void, @ViewBuilder trailing: () -> Trailing) {
        self.init(name: name, status: status, isSelected: isSelected, select: select, trailing: trailing, details: { EmptyView() })
    }
}

/// A workspace's branch, how much has changed in it since the last commit,
/// and its pull request.
private struct BranchLine: View {
    let branch: String
    let changes: Git.Changes?
    let pullRequest: GitHub.PullRequest?
    /// A click on the line, but not on its counts or pull request, selects the workspace.
    let select: () -> Void
    /// A click on the counts shows what changed.
    let showChanges: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: select) { summary }.buttonStyle(RowButtonStyle())
            if let changes, !changes.isEmpty {
                Button(action: showChanges) { counts(changes) }
                    .buttonStyle(.plain)
                    .help(String(localized: "커밋하지 않은 변경: \(changes.added)줄 추가, \(changes.removed)줄 삭제") + " · " + String(localized: "변경 보기"))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(String(localized: "커밋하지 않은 변경: \(changes.added)줄 추가, \(changes.removed)줄 삭제"))
                    .accessibilityHint(String(localized: "변경 보기"))
            }
            if let pullRequest { PullRequestBadge(pullRequest: pullRequest) }
        }
        .frame(height: 18)
    }

    private func counts(_ changes: Git.Changes) -> some View {
        HStack(spacing: 3) {
            if changes.added > 0 { Text(verbatim: "+\(changes.added)").foregroundStyle(Theme.done) }
            if changes.removed > 0 { Text(verbatim: "−\(changes.removed)").foregroundStyle(Theme.danger) }
        }
        .font(.system(size: 10.5, weight: .medium).monospacedDigit())
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
    }

    private var summary: some View {
        HStack(spacing: 6) {
            Text(branch)
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
        }
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
    }
}

/// A pull request's number, colored by its state as on GitHub, with a dot
/// for its checks. A click opens it in the browser.
private struct PullRequestBadge: View {
    let pullRequest: GitHub.PullRequest

    var body: some View {
        Button { NSWorkspace.shared.open(pullRequest.url) } label: {
            HStack(spacing: 3) {
                Image(systemName: pullRequest.state == .merged ? "arrow.triangle.merge" : "arrow.triangle.pull")
                    .font(.system(size: 9, weight: .semibold))
                Text(verbatim: "#\(pullRequest.number)")
                    .font(.system(size: 11).monospacedDigit())
                if let checks = checksColor { Circle().fill(checks).frame(width: 5, height: 5) }
            }
            .foregroundStyle(stateColor)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(description)
        .accessibilityLabel(description)
    }

    private var stateColor: Color {
        switch pullRequest.state {
        case .open: Theme.done
        case .draft: Theme.tertiary
        case .merged: Theme.accent
        case .closed: Theme.danger
        }
    }

    private var checksColor: Color? {
        switch pullRequest.checks {
        case .none: nil
        case .pending: Theme.waiting
        case .passing: Theme.done
        case .failing: Theme.danger
        }
    }

    private var description: String {
        let state = switch pullRequest.state {
        case .open: String(localized: "열림")
        case .draft: String(localized: "초안")
        case .merged: String(localized: "병합됨")
        case .closed: String(localized: "닫힘")
        }
        let checks: String? = switch pullRequest.checks {
        case .none: nil
        case .pending: String(localized: "검사 진행 중")
        case .passing: String(localized: "검사 통과")
        case .failing: String(localized: "검사 실패")
        }
        return ["PR #\(pullRequest.number)", state, checks].compactMap { $0 }.joined(separator: " · ")
    }
}

/// One of a workspace's tabs: what runs in it, its state, and for an agent
/// how long since that last changed. A click shows the tab; under the
/// pointer it offers to close it.
private struct TabLine: View {
    let tab: TerminalTab
    let status: AgentStatus
    /// The tab on screen now.
    let isActive: Bool
    let show: () -> Void
    let close: () -> Void
    @State private var hovering = false

    var body: some View {
        let agent = tab.agent
        HStack(spacing: 6) {
            Button(action: show) {
                HStack(spacing: 6) {
                    Image(nsImage: (agent ?? .terminal).icon).resizable().frame(width: 12, height: 12)
                    Text(verbatim: TabTitle.label(tab))
                        .font(.system(size: 12, weight: isActive ? .medium : .regular))
                        .foregroundStyle(isActive ? Theme.rowText : Theme.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(RowButtonStyle())
            ForEach(tab.ports.prefix(2), id: \.self) { PortLink(port: $0) }
            if status != .idle { StatusMark(status: status) }
            if hovering {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.secondary)
                .help("탭 닫기")
            } else if agent != nil {
                TimelineView(.everyMinute) { context in
                    Text(Duration.seconds(max(context.date.timeIntervalSince(tab.activeAt), 60))
                        .formatted(.units(allowed: [.days, .hours, .minutes], width: .narrow, maximumUnitCount: 1)))
                }
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiary)
            }
        }
        .padding(.horizontal, 4)
        .frame(height: 20)
        .background(RoundedRectangle(cornerRadius: 5).fill(hovering ? Theme.hoveredRow : .clear))
        // The highlight reaches a little past the line; its text stays in line with the name.
        .padding(.horizontal, -4)
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: Text("탭 닫기"), close)
    }
}

/// The line under a workspace's first tabs when it has more: how many are
/// folded away, and the state of the most pressing of them. A click shows
/// them all, or folds them again.
private struct MoreTabsLine: View {
    let hidden: Int
    let expanded: Bool
    let status: AgentStatus
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Image(systemName: expanded ? "chevron.up" : "ellipsis")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 12, height: 12)
                Text(expanded ? "접기" : "탭 \(hidden)개 더 보기")
                    .font(.system(size: 11))
                Spacer(minLength: 4)
                if !expanded, status != .idle { StatusMark(status: status) }
            }
            .foregroundStyle(Theme.tertiary)
            .frame(height: 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
    }
}

/// A port a program in the tab listens on; a click opens it in the browser.
private struct PortLink: View {
    let port: UInt16

    var body: some View {
        Button { if let url = URL(string: "http://localhost:\(port)") { NSWorkspace.shared.open(url) } } label: {
            Text(verbatim: ":\(port)")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Theme.working)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(String(localized: "브라우저에서 localhost:\(Int(port)) 열기"))
    }
}

/// A project's name over its workspaces. A click folds them away, or
/// brings them back; folded, it still shows what its agents are doing.
private struct ProjectHeader: View {
    let model: AppModel
    let project: Project
    let collapsed: Bool
    let toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: 6) {
                    Text(project.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(hovering ? Theme.rowText : Theme.secondary)
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Theme.tertiary)
                        .rotationEffect(.degrees(collapsed ? 0 : 90))
                        .opacity(hovering || collapsed ? 1 : 0)
                    if collapsed {
                        let status = model.workspaces(in: project).map { model.status(of: $0.id) }.max { $0.urgency < $1.urgency } ?? .idle
                        if status != .idle { StatusMark(status: status) }
                    }
                    Spacer(minLength: 4)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(collapsed ? String(localized: "\(project.name) 펼치기") : String(localized: "\(project.name) 접기"))
            IconButton(systemName: "ellipsis", label: String(localized: "\(project.name) 프로젝트 설정")) {
                model.sheet = .projectSettings(project)
            }
            IconButton(systemName: "plus", label: String(localized: "\(project.name)에 워크스페이스 추가")) {
                model.sheet = .newWorkspace(project)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(height: 26)
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
    }
}

/// An app a folder can be opened in.
@MainActor
private struct ExternalApp {
    let url: URL
    let name: String
    let icon: NSImage

    /// Editors, then terminals, then git apps: those installed, looked up once.
    static let installed: [ExternalApp] = [
        "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "dev.zed.Zed", "com.exafunction.windsurf",
        "com.apple.dt.Xcode", "com.jetbrains.intellij", "com.jetbrains.WebStorm", "com.jetbrains.goland",
        "com.jetbrains.pycharm", "com.sublimetext.4",
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
        "com.github.GitHubClient", "com.DanPristupov.Fork", "com.fournova.Tower3", "com.sublimemerge",
    ].compactMap { id in
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 16, height: 16)
        return ExternalApp(url: url, name: FileManager.default.displayName(atPath: url.path), icon: icon)
    }

    func open(_ path: String) {
        NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: url, configuration: NSWorkspace.OpenConfiguration())
    }

    /// "Open in" for a folder: the editors, terminals and git apps on this
    /// Mac, as a submenu; nil when none is installed.
    static func openIn(_ path: String) -> DropdownItem? {
        installed.isEmpty ? nil : .submenu(String(localized: "다른 앱에서 열기"), symbol: "arrow.up.forward.app",
                                           installed.map { app in .command(app.name, icon: app.icon) { app.open(path) } })
    }
}

/// A row keeps its look while pressed: no darkening, the hover color stays.
private struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}

/// The name, editable in place: Return keeps it, Esc puts the old one back,
/// and clicking elsewhere keeps what was typed, as in Finder.
struct RenameField: View {
    let name: String
    let font: Font
    let color: Color
    var prompt: LocalizedStringKey = "워크스페이스 이름"
    let finish: (String?) -> Void
    @State private var draft = ""
    @State private var done = false
    @FocusState private var focused: Bool

    var body: some View {
        TextField(prompt, text: $draft)
            .textFieldStyle(.plain)
            .font(font)
            .foregroundStyle(color)
            .focused($focused)
            .onSubmit { end(draft) }
            .onExitCommand { end(nil) }
            .onChange(of: focused) { if !focused { end(draft) } }
            .onAppear {
                draft = name
                focused = true
            }
    }

    private func end(_ value: String?) {
        guard !done else { return }
        done = true
        finish(value)
    }
}

