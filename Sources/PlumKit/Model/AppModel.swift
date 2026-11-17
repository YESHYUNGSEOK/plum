import AppKit
import Foundation
import Observation

/// One terminal tab inside a workspace.
public final class TerminalTab: Identifiable {
    @MainActor func status(in model: AppModel) -> AgentStatus { model.statuses[id] ?? .idle }

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

/// A workspace whose worktree is still being made. It shows in the sidebar,
/// with its steps in the panel, until it becomes a real workspace.
public struct PendingWorkspace: Identifiable {
    public struct Step {
        /// Nil for the setup command, which the first tab runs afterwards.
        public let kind: WorkspaceService.CreateStep?
        public let detail: String
    }

    public let id = UUID()
    public let projectID: UUID
    public let name: String
    public let steps: [Step]
    /// The step running now; nil until the first one starts.
    public var current: WorkspaceService.CreateStep?

    /// Index of the running step: those before it are done.
    public var currentIndex: Int { current.flatMap { step in steps.firstIndex { $0.kind == step } } ?? 0 }
}

/// Everything the windows show: projects, workspaces, tabs and agent states.
/// Observed per property: a view redraws only when something it read changes,
/// so a tab title that ticks ten times a second redraws the tab bar alone.
@MainActor
@Observable
public final class AppModel {
    public private(set) var state: AppState
    /// The selected workspace. A project's main checkout uses the project's id.
    public private(set) var selection: UUID?
    public private(set) var tabs: [UUID: [TerminalTab]] = [:]
    public private(set) var activeTabs: [UUID: UUID] = [:]
    public private(set) var statuses: [UUID: AgentStatus] = [:]
    public private(set) var titles: [UUID: String] = [:]
    /// Workspaces whose worktree is being created or removed right now.
    public private(set) var busy: Set<UUID> = []
    public private(set) var pending: [PendingWorkspace] = []
    public var errorMessage: String?
    public var sheet: AppSheet?
    public var sidebarCollapsed = false
    /// The sidebar has the keyboard: arrows move between workspaces.
    public var sidebarHasKeyboard = false

    /// Called when a tab needs the user and they aren't looking at it.
    @ObservationIgnored public var notify: ((_ title: String, _ body: String, _ tab: UUID) -> Void)?

    public let store: Store
    @ObservationIgnored private var server: StatusServer?
    @ObservationIgnored private var hookSettingsPath = ""
    @ObservationIgnored var debugResult = ""
    @ObservationIgnored var debugWindowNumber: (() -> Int)?
    @ObservationIgnored var debugTerminalView: (() -> TerminalView?)?
    @ObservationIgnored var debugNotificationStatus: (() -> String)?
    @ObservationIgnored var debugWindow: (() -> NSWindow?)?
    @ObservationIgnored var debugToggleSidebar: (() -> Void)?
    @ObservationIgnored var debugTraceDialogClose: ((@escaping (String) -> Void) -> Void)?

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
            errorMessage = String(localized: "에이전트 상태 수신을 시작하지 못했습니다: \(error.localizedDescription)")
        }
        let last = state.lastSelection.flatMap(workspace)
        if let start = last.map(\.id) ?? state.projects.first?.id { select(start) }
    }

    private func save() {
        do { try store.save(state) } catch { errorMessage = String(localized: "상태를 저장하지 못했습니다: \(error.localizedDescription)") }
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
        let before = place
        defer { record(before) }
        selection = id
        if let id, workspace(id) != nil, state.lastSelection != id {
            state.lastSelection = id
            save()
        }
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
            errorMessage = String(localized: "셸을 시작하지 못했습니다: \(error.localizedDescription)")
            return nil
        }
        if let command, !command.isEmpty { session.writeWhenReady(command + "\n") }

        tabs[workspaceID, default: []].append(tab)
        if let current = activeTabs[workspaceID] { recentTab[workspaceID] = current }
        activeTabs[workspaceID] = id
        return tab
    }

    public func activateTab(_ id: UUID) {
        guard let tab = tab(id) else { return }
        let before = place
        if let current = activeTabs[tab.workspaceID], current != id { recentTab[tab.workspaceID] = current }
        activeTabs[tab.workspaceID] = id
        tabBecameVisible()
        record(before)
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

    /// "zsh", "fish"…: what a tab is called while only the shell runs in it.
    static var shellName: String { (loginShell as NSString).lastPathComponent }

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
            let fallback = effective == .waiting ? String(localized: "입력을 기다리고 있습니다.") : String(localized: "작업을 마쳤습니다.")
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

    // MARK: Moving around

    /// Where the user is: a workspace and the tab showing in it.
    public struct Place: Equatable {
        public let workspace: UUID
        public let tab: UUID?
    }

    @ObservationIgnored private var past: [Place] = []
    @ObservationIgnored private var future: [Place] = []
    /// Set while going back, forward or anywhere in several steps, so the
    /// steps don't land in the history themselves.
    @ObservationIgnored private var replaying = false
    /// Per workspace, the tab shown before the current one.
    @ObservationIgnored private var recentTab: [UUID: UUID] = [:]

    private var place: Place? { selection.map { Place(workspace: $0, tab: activeTabs[$0]) } }

    private func record(_ before: Place?) {
        guard !replaying, let before, before != place else { return }
        past.append(before)
        if past.count > 100 { past.removeFirst() }
        future.removeAll()
    }

    /// Runs several steps as one move: one history entry, from where it began.
    private func navigate(_ steps: () -> Void) {
        let before = place
        let outer = replaying
        replaying = true
        steps()
        replaying = outer
        record(before)
    }

    private func canVisit(_ place: Place) -> Bool {
        guard let workspace = workspace(place.workspace) else { return false }
        return !workspace.isArchived
    }

    private func visit(_ place: Place) {
        let outer = replaying
        replaying = true
        defer { replaying = outer }
        select(place.workspace)
        if let tab = place.tab, tabs[place.workspace]?.contains(where: { $0.id == tab }) == true { activateTab(tab) }
    }

    /// Back and forward through the places visited, like a browser.
    public func goBack() { step(from: &past, to: &future) }
    public func goForward() { step(from: &future, to: &past) }

    private func step(from source: inout [Place], to destination: inout [Place]) {
        guard let current = place else { return }
        while let target = source.popLast() {
            guard canVisit(target), target != current else { continue }
            destination.append(current)
            visit(target)
            return
        }
    }

    /// The place before this one, and pressed again, back: two places to alternate between.
    public func goToLastPlace() {
        guard let current = place else { return }
        while let target = past.popLast() {
            guard canVisit(target), target.workspace != current.workspace || target.tab != current.tab else { continue }
            past.append(current)
            visit(target)
            return
        }
    }

    /// Workspaces visited before the current one, most recent first.
    public var recentWorkspaces: [UUID] {
        var seen: Set<UUID> = selection.map { [$0] } ?? []
        return past.reversed().map(\.workspace).filter { canVisit(Place(workspace: $0, tab: nil)) && seen.insert($0).inserted }
    }

    /// Workspaces in sidebar order: each project's main checkout, then its workspaces.
    public var workspaceOrder: [UUID] {
        state.projects.flatMap { workspaces(in: $0) }.map(\.id)
    }

    /// The next (+1) or previous (-1) workspace in sidebar order, wrapping.
    public func selectWorkspace(offset: Int) {
        let order = workspaceOrder
        guard !order.isEmpty else { return }
        let index = selection.flatMap { order.firstIndex(of: $0) } ?? (offset > 0 ? -1 : 0)
        select(order[(index + offset + order.count) % order.count])
    }

    /// The workspace at a position in the sidebar; nil index means the last one.
    public func selectWorkspace(at index: Int?) {
        let order = workspaceOrder
        guard let target = index.map({ order.indices.contains($0) ? order[$0] : nil }) ?? order.last else { return }
        select(target)
    }

    /// The next workspace that waits for an answer or has finished, waiting
    /// ones first; pressed again, the one after. Shows the tab that asked.
    public func jumpToAttention() {
        let order = workspaceOrder
        let wanting = order.filter { status(of: $0) == .waiting } + order.filter { status(of: $0) == .done }
        guard !wanting.isEmpty else { return }
        let target = selection.flatMap { wanting.firstIndex(of: $0) }.map { wanting[($0 + 1) % wanting.count] } ?? wanting[0]
        navigate {
            select(target)
            let asking = (tabs[target] ?? []).max { ($0.status(in: self)).urgency < ($1.status(in: self)).urgency }
            if let asking, asking.status(in: self) != .idle { activateTab(asking.id) }
        }
    }

    /// The tab shown before this one in the same workspace; again, back.
    public func activateRecentTab() {
        guard let selection, let previous = recentTab[selection],
              tabs[selection]?.contains(where: { $0.id == previous }) == true else { return }
        activateTab(previous)
    }

    /// The last tab of the selected workspace.
    public func activateLastTab() {
        guard let selection, let last = tabs[selection]?.last else { return }
        activateTab(last.id)
    }

    /// Moves a workspace one place up (-1) or down (+1) among its project's
    /// workspaces. The main checkout stays first.
    public func moveWorkspace(_ id: UUID, by offset: Int) {
        guard let moving = state.workspaces.first(where: { $0.id == id }), !moving.isArchived else { return }
        let siblings = state.workspaces.indices.filter {
            state.workspaces[$0].projectID == moving.projectID && !state.workspaces[$0].isArchived
        }
        guard let position = siblings.firstIndex(where: { state.workspaces[$0].id == id }),
              siblings.indices.contains(position + offset) else { return }
        state.workspaces.swapAt(siblings[position], siblings[position + offset])
        save()
    }

    /// Moves a tab one place left (-1) or right (+1).
    public func moveTab(_ id: UUID, by offset: Int) {
        guard let tab = tab(id), var list = tabs[tab.workspaceID], let index = list.firstIndex(where: { $0.id == id }),
              list.indices.contains(index + offset) else { return }
        list.swapAt(index, index + offset)
        tabs[tab.workspaceID] = list
    }

    /// Programs running in the foreground of a workspace's tabs, by name.
    public func runningPrograms(in workspaceID: UUID) -> [String] {
        (tabs[workspaceID] ?? []).compactMap { $0.session.foregroundProgram() }
    }

    /// Brings a tab to the front, e.g. from a clicked notification.
    public func reveal(tab id: UUID) {
        guard let tab = tab(id) else { return }
        navigate {
            selection = tab.workspaceID
            activateTab(id)
        }
    }

    // MARK: Projects and settings

    public func addProject(at path: String) {
        guard let root = Git.repositoryRoot(of: path) else {
            errorMessage = String(localized: "git 저장소가 아닙니다: \(path)")
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
            errorMessage = String(localized: "저장소 밖을 가리키는 복사 패턴은 건너뛰었습니다: \(created.rejectedPatterns.joined(separator: ", "))")
        }
    }

    /// Why a workspace with these settings can't be made, or nil if it can.
    /// Runs `create`'s own checks, so the form can stay open to fix them.
    public func problemCreatingWorkspace(projectID: UUID, name: String, branch: String, choice: WorkspaceService.BranchChoice) async -> String? {
        guard let project = project(projectID) else { return String(localized: "프로젝트가 없습니다.") }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if pending.contains(where: { $0.projectID == projectID && $0.name == trimmed }) {
            return String(localized: "같은 이름의 워크스페이스를 만드는 중입니다: \(trimmed)")
        }
        let root = state.settings.workspaceRoot
        let existing = state.workspaces
        return await Task.detached {
            do {
                _ = try WorkspaceService.validate(project: project, name: name, branch: branch, choice: choice, root: root, existing: existing)
                return nil
            } catch {
                return error.localizedDescription
            }
        }.value
    }

    public func createWorkspace(projectID: UUID, name: String, branch: String, choice: WorkspaceService.BranchChoice) async throws {
        guard let project = project(projectID) else { return }
        let root = state.settings.workspaceRoot
        let existing = state.workspaces
        let setup = setupCommand(for: project)
        var steps: [PendingWorkspace.Step] = []
        if case .new = choice { steps.append(.init(kind: .fetch, detail: "git fetch")) }
        steps.append(.init(kind: .worktree, detail: branch))
        if !project.copyPatterns.isEmpty { steps.append(.init(kind: .copy, detail: project.copyPatterns.joined(separator: " "))) }
        if !setup.isEmpty { steps.append(.init(kind: nil, detail: setup)) }
        let placeholder = PendingWorkspace(projectID: projectID, name: name.trimmingCharacters(in: .whitespaces), steps: steps)
        let id = placeholder.id
        let previous = selection
        pending.append(placeholder)
        selection = id
        defer { pending.removeAll { $0.id == id } }

        let created: WorkspaceService.Created
        do {
            created = try await Task.detached {
                try WorkspaceService.create(project: project, name: name, branch: branch, choice: choice, root: root, existing: existing) { step in
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            if let index = self.pending.firstIndex(where: { $0.id == id }) { self.pending[index].current = step }
                        }
                    }
                }
            }.value
        } catch {
            if selection == id { select(previous) }
            throw error
        }
        state.workspaces.append(created.workspace)
        save()
        report(created)
        // The user may have moved on while git worked.
        if selection == id { selection = created.workspace.id }
        openTab(in: created.workspace.id, command: setup)
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
