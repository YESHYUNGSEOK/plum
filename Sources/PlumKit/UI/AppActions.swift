import AppKit

/// User-facing flows that need a confirmation before the model acts.
@MainActor
enum AppActions {
    static func addProject(_ model: AppModel) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "git 저장소 폴더를 선택하세요")
        panel.prompt = String(localized: "추가")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.addProject(at: url.path)
    }

    /// Closes a tab, asking first if a program is running in it.
    static func closeTab(_ model: AppModel, _ id: UUID) {
        guard let tab = model.tabs.values.joined().first(where: { $0.id == id }) else { return }
        guard let program = tab.session.foregroundProgram() else { return model.closeTab(id) }
        Task {
            guard await ask(model, Confirmation(
                title: String(localized: "이 탭을 닫을까요?"),
                summary: String(localized: "실행 중인 ‘\(program)’도 함께 종료됩니다."),
                action: String(localized: "닫기"), destructive: true))
            else { return }
            model.closeTab(id)
        }
    }

    /// Closes several tabs, asking once if programs run in any of them.
    static func closeTabs(_ model: AppModel, _ ids: [UUID]) {
        let tabs = model.tabs.values.joined().filter { ids.contains($0.id) }
        let programs = tabs.compactMap { $0.session.foregroundProgram() }
        guard !programs.isEmpty else { return tabs.forEach { model.closeTab($0.id) } }
        Task {
            guard await ask(model, Confirmation(
                title: String(localized: "탭 \(tabs.count)개를 닫을까요?"),
                summary: String(localized: "실행 중인 ‘\(programs.joined(separator: ", "))’도 함께 종료됩니다."),
                action: String(localized: "닫기"), destructive: true))
            else { return }
            for tab in tabs { model.closeTab(tab.id) }
        }
    }

    static func removeProject(_ model: AppModel, _ project: Project) {
        Task {
            let openTabs = model.workspaces(in: project).reduce(0) { $0 + (model.tabs[$1.id]?.count ?? 0) }
            guard await ask(model, Confirmation(
                title: String(localized: "‘\(project.name)’을 목록에서 제거할까요?"),
                summary: String(localized: "Plum의 기록만 지웁니다. 저장소와 워크트리 폴더는 그대로 남습니다."),
                note: terminalsNote(openTabs), action: String(localized: "제거"), destructive: false))
            else { return }
            model.removeProject(project.id)
        }
    }

    static func archive(_ model: AppModel, _ workspace: Workspace) {
        Task {
            let check = await model.removalCheck(workspace.id, deletingBranch: false)
            let openTabs = model.tabs[workspace.id]?.count ?? 0
            if !check.isClean || openTabs > 0 {
                guard await ask(model, Confirmation(
                    title: String(localized: "‘\(workspace.name)’을 아카이브할까요?"),
                    summary: String(localized: "워크트리 폴더를 지우고 브랜치 \(workspace.branch)는 남깁니다. 나중에 복원할 수 있습니다."),
                    sections: losses(check) + running(model, workspace.id), note: terminalsNote(openTabs),
                    action: check.uncommitted.isEmpty ? String(localized: "아카이브") : String(localized: "변경을 버리고 아카이브"),
                    destructive: !check.uncommitted.isEmpty))
                else { return }
            }
            await run(model) { try await model.archive(workspace.id, force: !check.uncommitted.isEmpty) }
        }
    }

    static func delete(_ model: AppModel, _ workspace: Workspace) {
        Task {
            let check = await model.removalCheck(workspace.id, deletingBranch: true)
            let openTabs = model.tabs[workspace.id]?.count ?? 0
            let summary = workspace.isArchived
                ? String(localized: "로컬 브랜치 \(workspace.branch)를 지웁니다. 되돌릴 수 없습니다.")
                : String(localized: "워크트리 폴더와 로컬 브랜치 \(workspace.branch)를 지웁니다. 되돌릴 수 없습니다.")
            guard await ask(model, Confirmation(
                title: String(localized: "‘\(workspace.name)’을 삭제할까요?"), summary: summary,
                sections: losses(check) + running(model, workspace.id), note: terminalsNote(openTabs),
                action: check.isClean ? String(localized: "삭제") : String(localized: "잃어도 좋으니 삭제"), destructive: true))
            else { return }
            await run(model) { try await model.delete(workspace.id, force: !check.uncommitted.isEmpty) }
        }
    }

    static func restore(_ model: AppModel, _ workspace: Workspace) {
        Task { await run(model) { try await model.restore(workspace.id) } }
    }

    /// Exactly what would be lost, so "confirm" is an informed choice.
    private static func losses(_ check: WorkspaceService.RemovalCheck) -> [Confirmation.Section] {
        var sections: [Confirmation.Section] = []
        if !check.uncommitted.isEmpty { sections.append(.init(title: String(localized: "커밋하지 않은 변경"), lines: check.uncommitted, maxCode: 2)) }
        if !check.unpushed.isEmpty { sections.append(.init(title: String(localized: "원격에 없는 커밋"), lines: check.unpushed, maxCode: 40)) }
        return sections
    }

    private static func running(_ model: AppModel, _ workspaceID: UUID) -> [Confirmation.Section] {
        let programs = model.runningPrograms(in: workspaceID)
        return programs.isEmpty ? [] : [.init(title: String(localized: "함께 종료되는 프로그램"), lines: programs)]
    }

    private static func terminalsNote(_ count: Int) -> String? {
        count == 0 ? nil : String(localized: "열려 있는 터미널 \(count)개가 종료됩니다.")
    }

    /// Shows the question in the window and waits for the answer.
    /// Asks GitHub for a newer release and offers its page. `quietly` (the
    /// daily check) says nothing unless there is one.
    static func checkForUpdates(_ model: AppModel, quietly: Bool) async {
        do {
            if let release = try await Updates.newer() {
                // Don't interrupt a dialog that is already open.
                guard model.sheet == nil else { return }
                let open = await ask(model, Confirmation(
                    title: String(localized: "새 버전이 있습니다: \(release.tag)"),
                    summary: String(localized: "지금 버전은 \(Updates.current)입니다. 내려받기 페이지를 열까요?"),
                    sections: [], action: String(localized: "페이지 열기"), destructive: false))
                if open { NSWorkspace.shared.open(release.page) }
            } else if !quietly {
                model.errorMessage = String(localized: "최신 버전입니다 (\(Updates.current)).")
            }
        } catch {
            if !quietly { model.errorMessage = String(localized: "업데이트를 확인하지 못했습니다: \(error.localizedDescription)") }
        }
    }

    static func ask(_ model: AppModel, _ confirmation: Confirmation) async -> Bool {
        await withCheckedContinuation { continuation in
            confirmation.onAnswer = { continuation.resume(returning: $0) }
            model.sheet = .confirm(confirmation)
        }
    }

    private static func run(_ model: AppModel, _ operation: () async throws -> Void) async {
        do { try await operation() } catch { model.errorMessage = error.localizedDescription }
    }
}
