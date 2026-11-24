import AppKit

/// User-facing flows that need a confirmation before the model acts.
@MainActor
enum AppActions {
    static func addProject(_ model: AppModel) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "git 저장소나 폴더를 선택하세요")
        panel.prompt = String(localized: "추가")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard Git.repositoryRoot(of: url.path) == nil else { return model.addProject(at: url.path) }
        // As Orca does: a folder that isn't a repository opens with terminals only.
        Task {
            guard await ask(model, Confirmation(
                title: String(localized: "이 폴더는 git 저장소가 아닙니다"),
                summary: String(localized: "터미널과 에이전트는 쓸 수 있지만 워크트리, 브랜치, 변경 보기, PR 같은 git 기능은 쓸 수 없습니다."),
                sections: [.init(title: String(localized: "폴더"), lines: [(url.path as NSString).abbreviatingWithTildeInPath])],
                action: String(localized: "폴더로 열기"), destructive: false))
            else { return }
            model.addProject(at: url.path, asFolder: true)
        }
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
                summary: project.isFolder
                    ? String(localized: "Plum의 목록에서만 지웁니다. 폴더는 그대로 남습니다.")
                    : String(localized: "Plum의 기록만 지웁니다. 저장소와 워크트리 폴더는 그대로 남습니다."),
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
        if model.project(workspace.projectID)?.isFolder == true { return forget(model, workspace) }
        Task {
            // As in Orca, a branch that isn't merged is kept, so only local changes can be lost.
            let check = await model.removalCheck(workspace.id, deletingBranch: false)
            let openTabs = model.tabs[workspace.id]?.count ?? 0
            let summary = workspace.isArchived
                ? String(localized: "브랜치 \(workspace.branch)는 병합된 경우에만 지웁니다.")
                : String(localized: "워크트리 폴더와 로컬 변경을 지웁니다. 브랜치 \(workspace.branch)는 병합된 경우에만 지웁니다.")
            let folder = WorkspaceService.canonical(workspace.path) + "/"
            let nested = check.nested.isEmpty ? [] : [Confirmation.Section(
                title: String(localized: "함께 삭제되는 안쪽 워크트리"),
                lines: check.nested.map { String(WorkspaceService.canonical($0.path).dropFirst(folder.count)) + ($0.branch.map { "  \($0)" } ?? "") })]
            guard await ask(model, Confirmation(
                title: String(localized: "‘\(workspace.name)’을 삭제할까요?"), summary: summary,
                sections: losses(check) + nested + running(model, workspace.id), note: terminalsNote(openTabs),
                action: check.isClean ? String(localized: "삭제") : String(localized: "잃어도 좋으니 삭제"), destructive: true))
            else { return }
            var kept: [Git.Branch] = []
            await run(model) { kept = try await model.delete(workspace.id, force: !check.uncommitted.isEmpty, nested: check.nested) }
            if let project = model.project(workspace.projectID) { await offerToDelete(kept, in: project, model) }
        }
    }

    /// A folder project's workspace leaves only Plum's list: the folder is the project's.
    private static func forget(_ model: AppModel, _ workspace: Workspace) {
        Task {
            let openTabs = model.tabs[workspace.id]?.count ?? 0
            guard await ask(model, Confirmation(
                title: String(localized: "‘\(workspace.name)’을 목록에서 제거할까요?"),
                summary: String(localized: "Plum의 목록에서만 지웁니다. 폴더는 그대로 남습니다."),
                sections: running(model, workspace.id), note: terminalsNote(openTabs),
                action: String(localized: "제거"), destructive: false))
            else { return }
            await run(model) { try await model.delete(workspace.id, force: false) }
        }
    }

    /// Orca's "force delete" for the branches a delete kept because they aren't merged.
    private static func offerToDelete(_ kept: [Git.Branch], in project: Project, _ model: AppModel) async {
        guard !kept.isEmpty else { return }
        let commits = await Task.detached { kept.flatMap { Git.unpushedCommits(on: $0.name, in: project.path) } }.value
        guard await ask(model, Confirmation(
            title: String(localized: "병합되지 않은 브랜치를 남겼습니다"),
            summary: String(localized: "\(kept.map(\.name).joined(separator: ", "))는 병합되지 않아 지우지 않았습니다. 그래도 지울까요? 되돌릴 수 없습니다."),
            sections: commits.isEmpty ? [] : [.init(title: String(localized: "원격에 없는 커밋"), lines: commits, maxCode: 40)],
            action: String(localized: "브랜치 삭제"), destructive: true))
        else { return }
        await run(model) {
            try await Task.detached { for branch in kept { try Git.deleteBranch(branch.name, at: branch.head, in: project.path) } }.value
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
    /// Asks GitHub for a newer release and offers it. `quietly` (the daily
    /// check) says nothing unless there is one, and then only in a toast.
    static func checkForUpdates(_ model: AppModel, quietly: Bool) async {
        do {
            if let release = try await Updates.newer() {
                // The daily check only says so, in a toast; the menu asks now.
                if quietly { return model.availableUpdate = release }
                await offerUpdate(model, release)
            } else if !quietly {
                model.notice = String(localized: "최신 버전입니다 (\(Updates.current)).")
            }
        } catch {
            if !quietly { model.errorMessage = String(localized: "업데이트를 확인하지 못했습니다: \(error.localizedDescription)") }
        }
    }

    /// Asks to install a newer release, then installs it and restarts.
    static func offerUpdate(_ model: AppModel, _ release: Updates.Release) async {
        // Don't interrupt a dialog that is already open.
        guard model.sheet == nil else { return }
        model.availableUpdate = nil
        if let reason = Updates.cannotInstall(release) {
            return await offerPage(model, release, title: String(localized: "새 버전이 있습니다: \(release.tag)"),
                                   summary: String(localized: "지금 버전은 \(Updates.current)입니다. 여기서는 바로 설치할 수 없습니다: \(reason)"))
        }
        guard await ask(model, Confirmation(
            title: String(localized: "새 버전이 있습니다: \(release.tag)"),
            summary: String(localized: "지금 버전은 \(Updates.current)입니다. 내려받아 설치하고 Plum을 다시 시작할까요? 터미널과 그 안의 프로그램은 그대로 이어집니다."),
            sections: [], action: String(localized: "설치하고 다시 시작"), destructive: false)) else { return }
        // The toast and the menu can both get here.
        guard !installing else { return }
        installing = true
        defer { installing = false }
        model.notice = String(localized: "업데이트를 내려받는 중…")
        do {
            let app = try await Updates.install(release)
            // Still true if the quit is cancelled.
            model.notice = String(localized: "업데이트를 설치했습니다. Plum을 다시 시작하면 적용됩니다.")
            relaunch(app)
        } catch {
            model.notice = nil
            await offerPage(model, release, title: String(localized: "업데이트를 설치하지 못했습니다"),
                            summary: error.localizedDescription)
        }
    }

    /// Brings in what the user had in Orca, once (OrcaImport): asks, then
    /// adds. `quietly` (the first-launch offer) says nothing unless there
    /// is something to bring in.
    static let orcaOfferedKey = "offeredOrcaImport"

    static func importFromOrca(_ model: AppModel, quietly: Bool, cli: URL? = OrcaImport.cli()) async {
        guard let cli else {
            if !quietly { model.errorMessage = String(localized: "Orca가 설치되어 있지 않습니다.") }
            return
        }
        let catalog: OrcaImport.Catalog
        do {
            catalog = try await OrcaImport.load(cli: cli)
        } catch OrcaImport.Failure.notRunning {
            if !quietly { model.errorMessage = String(localized: "Orca를 켠 뒤 다시 시도해 주세요.") }
            return
        } catch {
            if !quietly { model.errorMessage = String(localized: "Orca의 출력을 읽지 못해 가져오지 않았습니다 (Orca \(OrcaImport.version() ?? "?")).") }
            return
        }
        guard !catalog.repos.isEmpty else {
            if !quietly { model.notice = String(localized: "Orca에 가져올 저장소가 없습니다.") }
            return
        }
        let new = model.notInPlum(catalog)
        guard !new.repos.isEmpty || !new.worktrees.isEmpty else {
            if !quietly { model.notice = String(localized: "Orca의 저장소와 워크트리가 이미 모두 Plum에 있습니다.") }
            return
        }
        // Don't take over a dialog that is already open.
        guard model.sheet == nil else { return }
        // The first-launch offer counts as made once it has asked.
        if quietly { UserDefaults.standard.set(true, forKey: orcaOfferedKey) }
        guard await ask(model, Confirmation(
            title: String(localized: "Orca에서 가져올까요?"),
            summary: String(localized: "저장소 \(new.repos.count)개와 워크트리 \(new.worktrees.count)개를 Plum 목록에 더합니다. 새 저장소의 다른 git 워크트리도 함께 보입니다. 디스크의 파일은 바뀌지 않습니다."),
            sections: new.repos.isEmpty ? [] : [.init(title: String(localized: "저장소"), lines: new.repos.map(\.name))],
            action: String(localized: "가져오기"), destructive: false)) else { return }
        let result = await model.importFromOrca(catalog)
        var message = String(localized: "저장소 \(result.projects)개와 워크트리 \(result.workspaces)개를 가져왔습니다.")
        if catalog.detached + catalog.missing > 0 {
            message += String(localized: " 브랜치가 없는 워크트리 \(catalog.detached)개와 폴더가 없는 워크트리 \(catalog.missing)개는 건너뛰었습니다.")
        }
        model.notice = message
    }

    private static func offerPage(_ model: AppModel, _ release: Updates.Release, title: String, summary: String) async {
        let open = await ask(model, Confirmation(
            title: title, summary: summary + " " + String(localized: "내려받기 페이지를 열까요?"),
            sections: [], action: String(localized: "페이지 열기"), destructive: false))
        if open { NSWorkspace.shared.open(release.page) }
    }

    private static var installing = false
    /// The updated app, opened once this process is gone. Only a quit that
    /// goes ahead opens it: the user can still cancel the quit.
    private static var reopenAfterQuit: URL?

    /// Quits, and the updated `app` opens after (`reopenIfUpdated`). Quitting
    /// parks the terminals in the host as usual; the new copy picks them up.
    static func relaunch(_ app: URL) {
        reopenAfterQuit = app
        NSApp.terminate(nil)
    }

    /// As Plum quits: a helper that waits for this process to end, then
    /// opens the updated app.
    static func reopenIfUpdated() {
        guard let app = reopenAfterQuit else { return }
        // A shell of its own session that inherits none of the app's
        // descriptors (the host would otherwise see a connection kept open).
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
        defer { posix_spawnattr_destroy(&attributes) }
        // -n: a new copy, always. Without it LaunchServices, which can still
        // count the copy that just quit as running, sends that copy "reopen"
        // instead, and nothing opens.
        let script = "while kill -0 \(getpid()) 2>/dev/null; do sleep 0.2; done; exec /usr/bin/open -n \"$@\""
        // A copy started with settings of its own (a test instance's state
        // folder) comes back with them; one started normally has none.
        let carried = ProcessInfo.processInfo.environment
            .filter { $0.key.hasPrefix("PLUM_") || $0.key == "CLAUDE_CONFIG_DIR" || $0.key == "CODEX_HOME" }
            .sorted { $0.key < $1.key }
            .flatMap { ["--env", "\($0.key)=\($0.value)"] }
        let argv: [UnsafeMutablePointer<CChar>?] = (["/bin/sh", "-c", script, "sh"] + carried + [app.path]).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        posix_spawn(&pid, "/bin/sh", nil, &attributes, argv, environ) // if not, the user opens it again
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
