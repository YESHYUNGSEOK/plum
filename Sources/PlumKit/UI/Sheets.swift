import SwiftUI

public enum AppSheet: Identifiable {
    case newWorkspace(Project)
    case projectSettings(Project)
    case settings

    public var id: String {
        switch self {
        case let .newWorkspace(project): "new-\(project.id)"
        case let .projectSettings(project): "project-\(project.id)"
        case .settings: "settings"
        }
    }
}

struct NewWorkspaceSheet: View {
    @ObservedObject var model: AppModel
    let project: Project

    @State private var name = ""
    @State private var branch = ""
    @State private var branchEdited = false
    @State private var useExisting = false
    @State private var base = ""
    @State private var existingBranch = ""
    @State private var branches: [String] = []
    @State private var defaultBase = ""
    @State private var error: String?
    @State private var working = false
    @Environment(\.dismiss) private var dismiss

    private var suggestedBranch: String {
        WorkspaceNaming.branchName(for: name, prefix: model.state.settings.branchPrefix)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("\(project.name)에 워크스페이스 추가")
                .font(.headline)
            Form {
                TextField("이름", text: $name)
                    .onChange(of: name) { if !branchEdited { branch = suggestedBranch } }
                Picker("브랜치", selection: $useExisting) {
                    Text("새 브랜치").tag(false)
                    Text("기존 브랜치").tag(true)
                }
                .pickerStyle(.segmented)
                if useExisting {
                    Picker("체크아웃할 브랜치", selection: $existingBranch) {
                        ForEach(branches, id: \.self) { Text($0).tag($0) }
                    }
                } else {
                    TextField("브랜치 이름", text: Binding(get: { branch }, set: { branch = $0; branchEdited = true }))
                    TextField("시작 지점", text: $base, prompt: Text(defaultBase.isEmpty ? "기본 브랜치" : defaultBase))
                }
            }
            if let error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button("취소", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("만들기") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || name.trimmingCharacters(in: .whitespaces).isEmpty || (useExisting ? existingBranch.isEmpty : branch.isEmpty))
            }
        }
        .padding(20)
        .frame(width: 440)
        .task {
            let path = project.path
            let configured = project.baseBranch
            let loaded = await Task.detached { (Git.branches(in: path), Git.defaultBase(in: path)) }.value
            branches = loaded.0
            existingBranch = loaded.0.first ?? ""
            defaultBase = configured.isEmpty ? loaded.1 : configured
        }
    }

    private func create() {
        working = true
        error = nil
        let trimmedBase = base.trimmingCharacters(in: .whitespaces)
        let choice: WorkspaceService.BranchChoice = useExisting ? .existing : .new(base: trimmedBase.isEmpty ? nil : trimmedBase)
        Task {
            do {
                try await model.createWorkspace(
                    projectID: project.id, name: name, branch: useExisting ? existingBranch : branch, choice: choice)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            working = false
        }
    }
}

struct ProjectSettingsSheet: View {
    @ObservedObject var model: AppModel
    @State var project: Project
    @State private var patterns: String
    @Environment(\.dismiss) private var dismiss

    init(model: AppModel, project: Project) {
        self.model = model
        _project = State(initialValue: project)
        _patterns = State(initialValue: project.copyPatterns.joined(separator: "\n"))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("\(project.name) 설정")
                .font(.headline)
            Text(project.path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Form {
                TextField("시작 지점", text: $project.baseBranch, prompt: Text("원격 기본 브랜치"))
                Section("워크스페이스를 만들 때") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("복사할 파일 (한 줄에 하나)")
                        TextEditor(text: $patterns)
                            .font(.system(.body, design: .monospaced))
                            .frame(height: 60)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator))
                            .accessibilityLabel("복사할 파일 패턴")
                        Text("기본 체크아웃에서 새 워크트리로 복사합니다. 예: .env*")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    TextField("준비 명령", text: $project.setupCommand, prompt: Text("예: pnpm install"))
                    TextField("에이전트 명령", text: $project.agentCommand, prompt: Text("비워 두면 실행하지 않음"))
                    Button("Claude Code 명령 넣기") {
                        project.agentCommand = "claude --settings \"$PLUM_CLAUDE_SETTINGS\""
                    }
                    .controlSize(.small)
                    Text("이 명령으로 실행한 Claude Code는 작업 중·입력 대기·완료 상태를 Plum에 알립니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Button("목록에서 제거", role: .destructive) {
                    AppActions.removeProject(model, project)
                    dismiss()
                }
                Spacer()
                Button("취소", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("저장") {
                    project.copyPatterns = patterns.split(whereSeparator: \.isNewline)
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    project.baseBranch = project.baseBranch.trimmingCharacters(in: .whitespaces)
                    model.update(project)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}

struct SettingsSheet: View {
    @ObservedObject var model: AppModel
    @State var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("설정")
                .font(.headline)
            Form {
                TextField("글꼴", text: $settings.fontName, prompt: Text("시스템 고정폭"))
                Stepper("글꼴 크기 \(Int(settings.fontSize))", value: $settings.fontSize, in: 8...40)
                TextField("워크스페이스 위치", text: $settings.workspaceRoot)
                TextField("브랜치 접두사", text: $settings.branchPrefix, prompt: Text("예: eric/"))
            }
            HStack {
                Spacer()
                Button("취소", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("저장") {
                    settings.workspaceRoot = settings.workspaceRoot.trimmingCharacters(in: .whitespaces)
                    if settings.workspaceRoot.isEmpty { settings.workspaceRoot = AppSettings().workspaceRoot }
                    model.update(settings)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
