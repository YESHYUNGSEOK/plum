import AppKit
import Combine
import Foundation

/// One terminal tab inside a workspace.
public final class TerminalTab: Identifiable {
    public let id: UUID
    public let workspaceID: UUID
    public let session: TerminalSession
    /// A program in this tab reported its state through hooks or OSC 7501,
    /// so a plain bell no longer needs to be read as "wants attention".
    var hasStructuredStatus = false

    init(id: UUID, workspaceID: UUID, session: TerminalSession) {
        self.id = id
        self.workspaceID = workspaceID
        self.session = session
    }
}

/// Everything the windows show: projects, workspaces, tabs and agent states.
@MainActor
public final class AppModel: ObservableObject {
    @Published public private(set) var state: AppState
    /// The selected workspace. A project's main checkout uses the project's id.
    @Published public private(set) var selection: UUID?
    @Published public private(set) var tabs: [UUID: [TerminalTab]] = [:]
    @Published public private(set) var activeTabs: [UUID: UUID] = [:]
    @Published public private(set) var statuses: [UUID: AgentStatus] = [:]
    @Published public private(set) var titles: [UUID: String] = [:]
    /// Workspaces whose worktree is being created or removed right now.
    @Published public private(set) var busy: Set<UUID> = []
    @Published public var errorMessage: String?
    @Published public var sheet: AppSheet?

    /// Called when a tab needs the user and they aren't looking at it.
    public var notify: ((_ title: String, _ body: String, _ tab: UUID) -> Void)?

    public let store: Store
    private var server: StatusServer?
    private var hookSettingsPath = ""
    var debugResult = ""
    var debugWindowNumber: (() -> Int)?
    var debugTerminalView: (() -> TerminalView?)?
    var debugNotificationStatus: (() -> String)?
    var debugWindow: (() -> NSWindow?)?

    public init(store: Store = Store()) {
        self.store = store
        state = store.load()
    }

    /// Starts listening for agent hooks. Call once at launch.
    public func start(debug: Bool = false) {
        let settings = store.directory.appendingPathComponent("claude-hooks.json")
        try? HookSettings.claudeSettings().write(to: settings, options: .atomic)
        hookSettingsPath = settings.path

        let server = StatusServer(
            directory: store.directory,
            onMessage: { [weak self] tab, status, message in
                MainActor.assumeIsolated { self?.setStatus(status, message: message, tab: tab, structured: true) }
            },
            debugHandler: debug ? { [weak self] line in
                MainActor.assumeIsolated { self?.handleDebug(line) ?? "" }
            } : nil)
        do {
            try server.start()
            self.server = server
        } catch {
            errorMessage = "에이전트 상태 수신을 시작하지 못했습니다: \(error.localizedDescription)"
        }
        if let first = state.projects.first { select(first.id) }
    }

    private func save() {
        do { try store.save(state) } catch { errorMessage = "상태를 저장하지 못했습니다: \(error.localizedDescription)" }
    }

    // MARK: Lookup

    /// A project's own checkout, shown as a workspace named "main".
    public func mainWorkspace(of project: Project) -> Workspace {
        var workspace = Workspace(projectID: project.id, name: "main", branch: "", path: project.path)
        workspace.id = project.id
        return workspace
    }

    public func isMain(_ workspace: Workspace) -> Bool { workspace.id == workspace.projectID }

    public func workspaces(in project: Project, archived: Bool = false) -> [Workspace] {
        let own = state.workspaces.filter { $0.projectID == project.id && $0.isArchived == archived }
        return archived ? own : [mainWorkspace(of: project)] + own
    }

    public func workspace(_ id: UUID) -> Workspace? {
        state.workspaces.first { $0.id == id } ?? state.projects.first { $0.id == id }.map(mainWorkspace)
    }

    public func project(_ id: UUID) -> Project? { state.projects.first { $0.id == id } }

    public var selectedWorkspace: Workspace? { selection.flatMap(workspace) }

    public var activeTab: TerminalTab? {
        guard let selection, let active = activeTabs[selection] else { return nil }
        return tabs[selection]?.first { $0.id == active }
    }

    public func folderExists(_ workspace: Workspace) -> Bool {
        FileManager.default.fileExists(atPath: workspace.path)
    }

    /// The most urgent state among a workspace's tabs.
    public func status(of workspaceID: UUID) -> AgentStatus {
        (tabs[workspaceID] ?? []).compactMap { statuses[$0.id] }.max { $0.urgency < $1.urgency } ?? .idle
    }

    private func tab(_ id: UUID) -> TerminalTab? {
        tabs.values.lazy.flatMap { $0 }.first { $0.id == id }
    }

    // MARK: Selection and tabs

    public func select(_ id: UUID?) {
        selection = id
        guard let id, let workspace = workspace(id), !workspace.isArchived, folderExists(workspace) else { return }
        if (tabs[id] ?? []).isEmpty { openTab(in: id) }
        tabBecameVisible()
    }

    /// Opens a shell in the workspace. `command` is typed into it once it starts.
    @discardableResult
    public func openTab(in workspaceID: UUID, command: String? = nil) -> TerminalTab? {
        guard let workspace = workspace(workspaceID), folderExists(workspace) else { return nil }
        let id = UUID()
        let session = TerminalSession(id: id)
        let tab = TerminalTab(id: id, workspaceID: workspaceID, session: session)

        // The session and view call these on the main thread.
        session.onTitle = { [weak self] title in MainActor.assumeIsolated { self?.titles[id] = title } }
        session.onSignal = { [weak self] signal in MainActor.assumeIsolated { self?.handle(signal, tab: id) } }
        session.onExit = { [weak self] in MainActor.assumeIsolated { self?.closeTab(id) } }

        do {
            try session.start(shell: Self.loginShell, cwd: workspace.path, environment: environment(for: tab, workspace: workspace))
        } catch {
            errorMessage = "셸을 시작하지 못했습니다: \(error.localizedDescription)"
            return nil
        }
        if let command, !command.isEmpty { session.writeWhenReady(command + "\n") }

        tabs[workspaceID, default: []].append(tab)
        activeTabs[workspaceID] = id
        return tab
    }

    public func activateTab(_ id: UUID) {
        guard let tab = tab(id) else { return }
        activeTabs[tab.workspaceID] = id
        tabBecameVisible()
    }

    /// Moves to the next (+1) or previous (-1) tab of the selected workspace.
    public func cycleTab(_ offset: Int) {
        guard let selection, let list = tabs[selection], list.count > 1,
              let index = list.firstIndex(where: { $0.id == activeTabs[selection] }) else { return }
        activateTab(list[(index + offset + list.count) % list.count].id)
    }

    public func activateTab(at index: Int) {
        guard let selection, let list = tabs[selection], list.indices.contains(index) else { return }
        activateTab(list[index].id)
    }

    public func closeTab(_ id: UUID) {
        guard let tab = tab(id), var list = tabs[tab.workspaceID], let index = list.firstIndex(where: { $0.id == id }) else { return }
        tab.session.onExit = nil
        tab.session.terminate()
        list.remove(at: index)
        tabs[tab.workspaceID] = list
        statuses[id] = nil
        titles[id] = nil
        if activeTabs[tab.workspaceID] == id {
            activeTabs[tab.workspaceID] = list.isEmpty ? nil : list[min(index, list.count - 1)].id
        }
    }

    private func closeAllTabs(in workspaceID: UUID) {
        for tab in tabs[workspaceID] ?? [] { closeTab(tab.id) }
        tabs[workspaceID] = nil
        activeTabs[workspaceID] = nil
    }

    private static var loginShell: String {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            let path = String(cString: shell)
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return "/bin/zsh"
    }

    private func environment(for tab: TerminalTab, workspace: Workspace) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        // Leftovers from whatever launched us would mislead programs.
        for key in ["TERM_PROGRAM_VERSION", "TERM_SESSION_ID", "TMUX", "TMUX_PANE", "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "PLUM_DEBUG", "PLUM_STATE_DIR"] {
            env[key] = nil
        }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "Plum"
        if env["LANG"] == nil {
            // Apps started from Finder have no locale; without UTF-8 the
            // shell mangles Hangul.
            // A language/region pair macOS allows (say en_KR) need not exist
            // as a POSIX locale; an unknown one makes programs complain.
            let preferred = String(Locale.current.identifier.replacingOccurrences(of: "-", with: "_").split(separator: "@")[0]) + ".UTF-8"
            env["LANG"] = FileManager.default.fileExists(atPath: "/usr/share/locale/\(preferred)") ? preferred : "en_US.UTF-8"
        }
        env["PLUM_TAB_ID"] = tab.id.uuidString
        env["PLUM_WORKSPACE"] = workspace.name
        env["PLUM_SOCKET"] = server?.path
        env["PLUM_CLAUDE_SETTINGS"] = hookSettingsPath
        return env
    }

    // MARK: Agent status

    private func isVisible(_ tab: TerminalTab) -> Bool {
        NSApp.isActive && selection == tab.workspaceID && activeTabs[tab.workspaceID] == tab.id
    }

    private func handle(_ signal: TerminalSignal, tab id: UUID) {
        switch signal {
        case let .status(status, message):
            setStatus(status, message: message, tab: id, structured: true)
        case let .notification(title, body):
            // A notification or bell in the tab being watched needs no flag.
            guard let tab = tab(id), !isVisible(tab) else { return }
            setStatus(.waiting, message: body.isEmpty ? title : body, tab: id, structured: false)
        case .bell:
            // Shells ring the bell for trivia such as a failed completion, so
            // it only counts where nothing better reports the tab's state.
            guard let tab = tab(id), !isVisible(tab), !tab.hasStructuredStatus else { return }
            setStatus(.waiting, message: "", tab: id, structured: false)
        }
    }

    /// Records a tab's state and tells the user if it needs them.
    public func setStatus(_ status: AgentStatus, message: String, tab id: UUID, structured: Bool) {
        guard let tab = tab(id) else { return } // unknown ids are ignored: the socket is external input
        if structured { tab.hasStructuredStatus = true }
        let visible = isVisible(tab)
        // "Done" only matters as something to come back to.
        let effective = status == .done && visible ? .idle : status
        guard statuses[id, default: .idle] != effective else { return }
        statuses[id] = effective == .idle ? nil : effective

        if !visible, effective == .waiting || effective == .done, let workspace = workspace(tab.workspaceID) {
            let project = project(workspace.projectID)?.name ?? ""
            let fallback = effective == .waiting ? "입력을 기다리고 있습니다." : "작업을 마쳤습니다."
            notify?("\(project) · \(workspace.name)", message.isEmpty ? fallback : message, id)
        }
    }

    /// The user is now looking at the active tab: a finished run is acknowledged.
    public func tabBecameVisible() {
        guard let tab = activeTab, isVisible(tab), statuses[tab.id] == .done else { return }
        statuses[tab.id] = nil
    }

    public func userTyped(in id: UUID) {
        // Answering a prompt resolves "waiting"; the agent reports again if not.
        if statuses[id] == .waiting || statuses[id] == .done { statuses[id] = nil }
    }

    /// Brings a tab to the front, e.g. from a clicked notification.
    public func reveal(tab id: UUID) {
        guard let tab = tab(id) else { return }
        selection = tab.workspaceID
        activateTab(id)
    }

    // MARK: Projects and settings

    public func addProject(at path: String) {
        guard let root = Git.repositoryRoot(of: path) else {
            errorMessage = "git 저장소가 아닙니다: \(path)"
            return
        }
        if let existing = state.projects.first(where: { WorkspaceService.samePath($0.path, root) }) {
            select(existing.id)
            return
        }
        var name = (root as NSString).lastPathComponent
        var suffix = 2
        while state.projects.contains(where: { $0.name == name }) {
            name = "\((root as NSString).lastPathComponent)-\(suffix)"
            suffix += 1
        }
        let project = Project(name: name, path: root)
        state.projects.append(project)
        save()
        select(project.id)
    }

    /// Forgets a project. Nothing on disk is touched.
    public func removeProject(_ id: UUID) {
        for workspace in state.workspaces where workspace.projectID == id { closeAllTabs(in: workspace.id) }
        closeAllTabs(in: id)
        state.workspaces.removeAll { $0.projectID == id }
        state.projects.removeAll { $0.id == id }
        save()
        if selection.flatMap(workspace) == nil { select(state.projects.first?.id) }
    }

    public func update(_ project: Project) {
        guard let index = state.projects.firstIndex(where: { $0.id == project.id }) else { return }
        state.projects[index] = project
        save()
    }

    public func update(_ settings: AppSettings) {
        var settings = settings
        settings.fontSize = min(40, max(8, settings.fontSize))
        state.settings = settings
        save()
    }

    // MARK: Workspace lifecycle

    /// What the first tab of a fresh worktree runs: setup, then the agent.
    private func setupCommand(for project: Project) -> String {
        [project.setupCommand, project.agentCommand]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " && ")
    }

    private func report(_ created: WorkspaceService.Created) {
        if !created.rejectedPatterns.isEmpty {
            errorMessage = "저장소 밖을 가리키는 복사 패턴은 건너뛰었습니다: \(created.rejectedPatterns.joined(separator: ", "))"
        }
    }

    public func createWorkspace(projectID: UUID, name: String, branch: String, choice: WorkspaceService.BranchChoice) async throws {
        guard let project = project(projectID) else { return }
        let root = state.settings.workspaceRoot
        let existing = state.workspaces
        let created = try await Task.detached {
            try WorkspaceService.create(project: project, name: name, branch: branch, choice: choice, root: root, existing: existing)
        }.value
        state.workspaces.append(created.workspace)
        save()
        report(created)
        selection = created.workspace.id
        openTab(in: created.workspace.id, command: setupCommand(for: project))
    }

    public func removalCheck(_ id: UUID, deletingBranch: Bool) async -> WorkspaceService.RemovalCheck {
        guard let workspace = state.workspaces.first(where: { $0.id == id }), let project = project(workspace.projectID) else {
            return .init()
        }
        return await Task.detached { WorkspaceService.inspect(workspace, project: project, deletingBranch: deletingBranch) }.value
    }

    /// Removes the worktree folder but keeps the branch and the record.
    public func archive(_ id: UUID, force: Bool) async throws {
        guard let workspace = state.workspaces.first(where: { $0.id == id }), !workspace.isArchived,
              let project = project(workspace.projectID) else { return }
        try await removeWorktree(of: workspace, project: project, force: force)
        if let index = state.workspaces.firstIndex(where: { $0.id == id }) { state.workspaces[index].isArchived = true }
        save()
        if selection == id { select(project.id) }
    }

    /// Removes the worktree, the local branch and the record.
    public func delete(_ id: UUID, force: Bool) async throws {
        guard let workspace = state.workspaces.first(where: { $0.id == id }), let project = project(workspace.projectID) else { return }
        if !workspace.isArchived { try await removeWorktree(of: workspace, project: project, force: force) }
        let branch = workspace.branch
        try await Task.detached {
            if Git.branchExists(branch, in: project.path) { try Git.deleteBranch(branch, in: project.path) }
        }.value
        state.workspaces.removeAll { $0.id == id }
        save()
        if selection == id { select(project.id) }
    }

    private func removeWorktree(of workspace: Workspace, project: Project, force: Bool) async throws {
        busy.insert(workspace.id)
        defer { busy.remove(workspace.id) }
        try await Task.detached { try WorkspaceService.removeWorktree(workspace, project: project, force: force) }.value
        // Only once the folder is really gone: if git refused, the user's
        // shells and agents must still be there.
        closeAllTabs(in: workspace.id)
    }

    public func restore(_ id: UUID) async throws {
        guard let workspace = state.workspaces.first(where: { $0.id == id }), workspace.isArchived,
              let project = project(workspace.projectID) else { return }
        busy.insert(id)
        defer { busy.remove(id) }
        let created = try await Task.detached { try WorkspaceService.restore(workspace, project: project) }.value
        if let index = state.workspaces.firstIndex(where: { $0.id == id }) { state.workspaces[index] = created.workspace }
        save()
        report(created)
        selection = id
        openTab(in: id, command: setupCommand(for: project))
    }
}
