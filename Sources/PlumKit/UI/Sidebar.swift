import SwiftUI

extension AgentStatus {
    var color: Color {
        switch self {
        case .idle: .clear
        case .working: .blue
        case .waiting: .orange
        case .done: .green
        }
    }

    var label: String {
        switch self {
        case .idle: ""
        case .working: "작업 중"
        case .waiting: "입력 대기"
        case .done: "완료"
        }
    }
}

struct StatusDot: View {
    let status: AgentStatus

    var body: some View {
        Circle()
            .fill(status.color)
            .frame(width: 8, height: 8)
            .opacity(status == .idle ? 0 : 1)
            .accessibilityLabel(status.label)
            .help(status.label)
    }
}

struct SidebarView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if model.state.projects.isEmpty {
                Spacer()
                Text("프로젝트가 없습니다")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List(selection: Binding(get: { model.selection }, set: { model.select($0) })) {
                    // Rows without a tag take the ForEach id as their selection
                    // value. The main workspace is tagged with the project's
                    // UUID, so the loop must not use that same UUID as its id,
                    // or the header and archive rows light up with "main".
                    ForEach(model.state.projects, id: \.sidebarID) { project in
                        ProjectHeader(model: model, project: project)
                            .selectionDisabled()
                            .listRowSeparator(.hidden)
                        ForEach(model.workspaces(in: project)) { workspace in
                            WorkspaceRow(model: model, workspace: workspace)
                                .tag(workspace.id)
                                .contextMenu { workspaceMenu(workspace) }
                        }
                        let archived = model.workspaces(in: project, archived: true)
                        if !archived.isEmpty {
                            DisclosureGroup("아카이브 \(archived.count)") {
                                ForEach(archived) { workspace in
                                    WorkspaceRow(model: model, workspace: workspace)
                                        .tag(workspace.id)
                                        .contextMenu { archivedMenu(workspace) }
                                }
                            }
                            .foregroundStyle(.secondary)
                        }
                    }
                }
                .listStyle(.sidebar)
            }
            Divider()
            HStack {
                Button {
                    AppActions.addProject(model)
                } label: {
                    Label("프로젝트 추가", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                Spacer()
                Button {
                    model.sheet = .settings
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("설정")
                .help("설정")
            }
            .padding(10)
        }
        .sheet(item: $model.sheet) { sheet in
            switch sheet {
            case let .newWorkspace(project): NewWorkspaceSheet(model: model, project: project)
            case let .projectSettings(project): ProjectSettingsSheet(model: model, project: project)
            case .settings: SettingsSheet(model: model, settings: model.state.settings)
            }
        }
        .alert("문제가 생겼습니다", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
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

    @ViewBuilder
    private func archivedMenu(_ workspace: Workspace) -> some View {
        Button("복원") { AppActions.restore(model, workspace) }
        Button("삭제…", role: .destructive) { AppActions.delete(model, workspace) }
    }
}

private extension Project {
    var sidebarID: String { "project-\(id.uuidString)" }
}

private struct ProjectHeader: View {
    @ObservedObject var model: AppModel
    let project: Project

    var body: some View {
        HStack(spacing: 4) {
            Text(project.name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Button {
                model.sheet = .projectSettings(project)
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("\(project.name) 프로젝트 설정")
            .help("프로젝트 설정")
            Button {
                model.sheet = .newWorkspace(project)
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("\(project.name)에 워크스페이스 추가")
            .help("워크스페이스 추가")
        }
    }
}

private struct WorkspaceRow: View {
    @ObservedObject var model: AppModel
    let workspace: Workspace

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(workspace.name)
                    .lineLimit(1)
                if !workspace.branch.isEmpty, workspace.branch != workspace.name {
                    Text(workspace.branch)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 4)
            if model.busy.contains(workspace.id) {
                ProgressView().controlSize(.small)
            } else if !workspace.isArchived, !model.folderExists(workspace) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.yellow)
                    .help("폴더가 없습니다")
                    .accessibilityLabel("폴더 없음")
            } else {
                StatusDot(status: model.status(of: workspace.id))
            }
        }
        .padding(.vertical, 2)
        .padding(.leading, 6)
    }
}
