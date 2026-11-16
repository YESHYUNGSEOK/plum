import AppKit

/// User-facing flows that need a confirmation before the model acts.
@MainActor
enum AppActions {
    static func addProject(_ model: AppModel) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "git 저장소 폴더를 선택하세요"
        panel.prompt = "추가"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.addProject(at: url.path)
    }

    static func removeProject(_ model: AppModel, _ project: Project) {
        let alert = NSAlert()
        alert.messageText = "‘\(project.name)’을 목록에서 제거할까요?"
        alert.informativeText = "Plum의 기록만 지웁니다. 저장소와 워크트리 폴더는 그대로 남습니다. 열려 있는 터미널은 종료됩니다."
        alert.addButton(withTitle: "제거")
        alert.addButton(withTitle: "취소")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        model.removeProject(project.id)
    }

    static func archive(_ model: AppModel, _ workspace: Workspace) {
        Task {
            let check = await model.removalCheck(workspace.id, deletingBranch: false)
            let openTabs = model.tabs[workspace.id]?.count ?? 0
            if !check.isClean || openTabs > 0 {
                var lines = ["워크트리 폴더를 지우고 브랜치 \(workspace.branch)는 남깁니다. 나중에 복원할 수 있습니다."]
                if openTabs > 0 { lines.append("열려 있는 터미널 \(openTabs)개가 종료됩니다.") }
                lines += lossSummary(check)
                guard confirm(
                    title: "‘\(workspace.name)’을 아카이브할까요?", lines: lines,
                    action: check.uncommitted.isEmpty ? "아카이브" : "변경을 버리고 아카이브",
                    destructive: !check.uncommitted.isEmpty)
                else { return }
            }
            await run(model) { try await model.archive(workspace.id, force: !check.uncommitted.isEmpty) }
        }
    }

    static func delete(_ model: AppModel, _ workspace: Workspace) {
        Task {
            let check = await model.removalCheck(workspace.id, deletingBranch: true)
            let openTabs = model.tabs[workspace.id]?.count ?? 0
            var lines = [workspace.isArchived
                ? "로컬 브랜치 \(workspace.branch)를 지웁니다. 되돌릴 수 없습니다."
                : "워크트리 폴더와 로컬 브랜치 \(workspace.branch)를 지웁니다. 되돌릴 수 없습니다."]
            if openTabs > 0 { lines.append("열려 있는 터미널 \(openTabs)개가 종료됩니다.") }
            lines += lossSummary(check)
            guard confirm(
                title: "‘\(workspace.name)’을 삭제할까요?", lines: lines,
                action: check.isClean ? "삭제" : "잃어도 좋으니 삭제", destructive: true)
            else { return }
            await run(model) { try await model.delete(workspace.id, force: !check.uncommitted.isEmpty) }
        }
    }

    static func restore(_ model: AppModel, _ workspace: Workspace) {
        Task { await run(model) { try await model.restore(workspace.id) } }
    }

    /// Spells out exactly what would be lost, so "confirm" is an informed choice.
    private static func lossSummary(_ check: WorkspaceService.RemovalCheck) -> [String] {
        var lines: [String] = []
        if !check.uncommitted.isEmpty {
            lines.append("커밋하지 않은 변경 \(check.uncommitted.count)개가 사라집니다:\n" + listing(check.uncommitted))
        }
        if !check.unpushed.isEmpty {
            lines.append("어느 원격에도 없는 커밋 \(check.unpushed.count)개가 사라집니다:\n" + listing(check.unpushed))
        }
        return lines
    }

    private static func listing(_ items: [String]) -> String {
        let shown = items.prefix(12).map { "  \($0)" }.joined(separator: "\n")
        return items.count > 12 ? shown + "\n  … 외 \(items.count - 12)개" : shown
    }

    private static func confirm(title: String, lines: [String], action: String, destructive: Bool) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = destructive ? .critical : .warning
        alert.messageText = title
        alert.informativeText = lines.joined(separator: "\n\n")
        let button = alert.addButton(withTitle: action)
        button.hasDestructiveAction = destructive
        // The safe choice is the default: Return never destroys work.
        let cancel = alert.addButton(withTitle: "취소")
        if destructive {
            button.keyEquivalent = ""
            cancel.keyEquivalent = "\r"
        }
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func run(_ model: AppModel, _ operation: () async throws -> Void) async {
        do { try await operation() } catch { model.errorMessage = error.localizedDescription }
    }
}
