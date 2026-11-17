import SwiftUI

extension AgentStatus {
    var color: Color {
        switch self {
        case .idle: .clear
        case .working: Theme.working
        case .waiting: Theme.waiting
        case .done: Theme.done
        }
    }

    var label: String {
        switch self {
        case .idle: ""
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

/// Projects and their workspaces, drawn straight on the window's ground.
struct SidebarView: View {
    let model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
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
                Button("프로젝트 추가") { AppActions.addProject(model) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
                Spacer()
                IconButton(systemName: "slider.horizontal.3", label: String(localized: "설정")) { model.sheet = .settings }
            }
            .padding(.horizontal, 22)
            .frame(height: 46)
        }
        .frame(width: Theme.sidebarWidth)
        .environment(\.colorScheme, .dark)
    }

    /// Changes whenever a row appears, disappears or moves.
    private var layoutKey: [UUID] {
        let attention = model.state.projects.flatMap { model.workspaces(in: $0) }
            .filter { [.waiting, .done].contains(model.status(of: $0.id)) }.map(\.id)
        return attention + model.state.workspaces.map(\.id) + model.pending.map(\.id)
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
                HStack(spacing: 8) {
                    Text("확인 필요").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text)
                    Text("\(items.count)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.panelColor)
                        .padding(.horizontal, 6)
                        .frame(height: 16)
                        .background(Capsule().fill(Theme.waiting))
                }
                .padding(.horizontal, 10)
                .frame(height: 26)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("확인 필요 \(items.count)개")

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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 0) {
                Text(project.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
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

            ForEach(model.workspaces(in: project)) { workspace in
                WorkspaceRow(model: model, workspace: workspace)
                    .contextMenu { workspaceMenu(workspace) }
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
                            .contextMenu {
                                Button("복원") { AppActions.restore(model, workspace) }
                                Button("삭제…", role: .destructive) { AppActions.delete(model, workspace) }
                            }
                            .transition(.opacity)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func workspaceMenu(_ workspace: Workspace) -> some View {
        Button("Finder에서 보기") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: workspace.path) }
        Button("경로 복사") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(workspace.path, forType: .string)
        }
        if !model.isMain(workspace) {
            Divider()
            Button("아카이브") { AppActions.archive(model, workspace) }
            Button("삭제…", role: .destructive) { AppActions.delete(model, workspace) }
        }
    }
}

private struct WorkspaceRow: View {
    let model: AppModel
    let workspace: Workspace

    var body: some View {
        SidebarRow(
            name: workspace.name, status: model.status(of: workspace.id), isSelected: model.selection == workspace.id,
            dimmed: workspace.isArchived, hasKeyboard: model.sidebarHasKeyboard && model.selection == workspace.id,
            select: { model.select(workspace.id) }
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
        }
        .help(workspace.branch.isEmpty ? workspace.path : "\(workspace.branch)\n\(workspace.path)")
    }
}

/// One line of the sidebar: state mark, name, and whatever goes at the end.
private struct SidebarRow<Trailing: View>: View {
    let name: String
    var status: AgentStatus = .idle
    let isSelected: Bool
    var dimmed = false
    /// The sidebar's keyboard mode is on this row.
    var hasKeyboard = false
    let select: () -> Void
    @ViewBuilder let trailing: () -> Trailing
    @State private var hovering = false

    var body: some View {
        Button(action: select) {
            HStack(spacing: 8) {
                StatusMark(status: status)
                Text(name)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.white : dimmed ? Theme.secondary : Theme.rowText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                trailing()
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(isSelected ? Theme.selectedRow : hovering ? Theme.hoveredRow : .clear)
                    .animation(Motion.hover, value: hovering)
                    .animation(Motion.settle, value: isSelected))
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(Theme.accent, lineWidth: 1.5)
                    .opacity(hasKeyboard ? 1 : 0)
                    .animation(Motion.settle, value: hasKeyboard))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
