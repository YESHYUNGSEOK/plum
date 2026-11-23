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
                if let reason = Updates.cannotInstall(release) {
                    return await offerPage(model, release, title: String(localized: "새 버전이 있습니다: \(release.tag)"),
                                           summary: String(localized: "지금 버전은 \(Updates.current)입니다. 여기서는 바로 설치할 수 없습니다: \(reason)"))
                }
                guard await ask(model, Confirmation(
                    title: String(localized: "새 버전이 있습니다: \(release.tag)"),
                    summary: String(localized: "지금 버전은 \(Updates.current)입니다. 내려받아 설치하고 Plum을 다시 시작할까요? 터미널과 그 안의 프로그램은 그대로 이어집니다."),
                    sections: [], action: String(localized: "설치하고 다시 시작"), destructive: false)) else { return }
                // The daily check and the menu can both get here.
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
            } else if !quietly {
                model.notice = String(localized: "최신 버전입니다 (\(Updates.current)).")
            }
        } catch {
            if !quietly { model.errorMessage = String(localized: "업데이트를 확인하지 못했습니다: \(error.localizedDescription)") }
        }
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
