import AppKit
import Foundation
import Observation

/// One terminal tab inside a workspace.
@Observable
public final class TerminalTab: Identifiable {
    @MainActor func status(in model: AppModel) -> AgentStatus { model.statuses[id] ?? .idle }

    public let id: UUID
    public let workspaceID: UUID
    public let session: TerminalSession
    /// A program in this tab reported its state through hooks or OSC 7501,
    /// so a plain bell no longer needs to be read as "wants attention".
    @ObservationIgnored var hasStructuredStatus = false
    /// What the program in it last called itself (OSC 0/2). Kept on the tab,
    /// not in one table for all tabs: agents retitle their tab as they work,
    /// and only that tab's label should redraw, not every view of every tab.
    public internal(set) var title = ""
    /// The agent running in it now, if any; looked up every few seconds.
    public internal(set) var agent: TabProgram?
    /// When its agent started or last changed state.
    public internal(set) var activeAt = Date()
    /// Ports its programs listen on, such as a dev server's.
    public internal(set) var ports: [UInt16] = []
    /// The title the user gave it, shown instead of its program's.
    public internal(set) var customTitle: String?

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
    /// The terminal with the keyboard in each workspace: a tab, or a pane
    /// of a split tab.
    public private(set) var activeTabs: [UUID: UUID] = [:]
    /// Tabs split into panes, keyed by the tab that heads each split (the one
    /// the tab bar shows). Every pane is a tab of the workspace too.
    public private(set) var splits: [UUID: SplitNode] = [:]
    /// The pane last used in each split, given the keyboard again when its
    /// tab is picked.
    @ObservationIgnored private var splitFocus: [UUID: UUID] = [:]
    public private(set) var statuses: [UUID: AgentStatus] = [:]
    /// The branch each project's own checkout is on.
    public private(set) var mainBranches: [UUID: String] = [:]
    /// Lines changed since the last commit in each workspace's checkout.
    public private(set) var changes: [UUID: Git.Changes] = [:]
    /// The newest pull request of each branch, per project.
    public private(set) var pullRequests: [UUID: [String: GitHub.PullRequest]] = [:]
    /// Workspaces being counted now; true if asked again meanwhile.
    @ObservationIgnored private var countingChanges: [UUID: Bool] = [:]
    @ObservationIgnored private var fetchingPullRequests: Set<UUID> = []
    /// Each workspace's tab output when its changes were last counted.
    @ObservationIgnored private var outputCounted: [UUID: Int] = [:]
    /// Two-second beats since launch, for checks that run less often.
    @ObservationIgnored private var beats = 0
    /// Workspaces whose worktree is being created or removed right now.
    public private(set) var busy: Set<UUID> = []
    public private(set) var pending: [PendingWorkspace] = []
    public var errorMessage: String?
    public var sheet: AppSheet?
    public var sidebarCollapsed = false
    /// The sidebar has the keyboard: arrows move between workspaces.
    public var sidebarHasKeyboard = false
    /// The workspace whose name is being edited in place in the sidebar.
    public var renaming: UUID?
    /// The tab whose title is being edited in place in the tab bar.
    public var renamingTab: UUID?

    /// Called when a tab needs the user and they aren't looking at it.
    @ObservationIgnored public var notify: ((_ title: String, _ body: String, _ tab: UUID) -> Void)?

    public let store: Store
    @ObservationIgnored private var server: StatusServer?
    /// Keeps terminals running while the app isn't. Nil in tests, and if
    /// it can't be started: tabs then end with the app, as they used to.
    @ObservationIgnored private var host: TerminalHostClient?
    @ObservationIgnored private var hookSettingsPath = ""
    /// A folder holding Plum's `.zshenv`, which zsh reads first: see `ShellIntegration`.
    @ObservationIgnored private var zshIntegrationPath = ""
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
        carryOverAgentCommand()
    }

    /// Older versions kept one agent command per project, run in the first
    /// tab of every new workspace. It becomes the matching command in the
    /// settings, and the agent new workspaces start with.
    private func carryOverAgentCommand() {
        let old = state.projects.map { $0.agentCommand.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let command = old.first(where: { !$0.isEmpty }) else { return }
        if command.contains("codex") {
            state.settings.codexCommand = command
            state.settings.newWorkspaceProgram = .codex
        } else {
            state.settings.claudeCommand = command
            state.settings.newWorkspaceProgram = .claude
        }
        for index in state.projects.indices { state.projects[index].agentCommand = "" }
        save()
    }

    /// Starts listening for agent hooks. Call once at launch.
    public func start(debug: Bool = false) {
        let settings = store.directory.appendingPathComponent("claude-hooks.json")
        try? HookSettings.claudeSettings().write(to: settings, options: .atomic)
        hookSettingsPath = settings.path
        let zsh = store.directory.appendingPathComponent("shell/zsh", isDirectory: true)
        if (try? FileManager.default.createDirectory(at: zsh, withIntermediateDirectories: true)) != nil,
           (try? Data(ShellIntegration.zshenv.utf8).write(to: zsh.appendingPathComponent(".zshenv"), options: .atomic)) != nil {
            zshIntegrationPath = zsh.path
        }

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
        if let executable = Bundle.main.executablePath {
            host = TerminalHostClient(socketPath: TerminalHost.socketPath(for: store), executable: executable)
        }
        restoreTabs()
        watchTabs()
        for project in state.projects { for workspace in workspaces(in: project) { refreshChanges(workspace.id) } }
        refreshPullRequests()
        let watch = Timer(timeInterval: 2, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.watchTabs() } }
        watch.tolerance = 0.5
        RunLoop.main.add(watch, forMode: .common)
        let last = state.lastSelection.flatMap(workspace)
        if let start = last.map(\.id) ?? state.projects.first?.id { select(start) }
    }

    /// Which agent runs in each tab and which ports its programs listen on,
    /// and the branch each project's checkout is on: what the sidebar shows
    /// under a workspace's name.
    // ponytail: polled every 2 s (a few syscalls per tab); a program can start
    // from any shell prompt, and no event says so.
    private func watchTabs() {
        beats += 1
        // Every 30 s, recount where something printed since the last count:
        // files rarely change in silence, and an idle workspace costs no git
        // run. Pull requests ask GitHub, every 3 minutes.
        if beats % 15 == 0 {
            for (id, list) in tabs where !list.isEmpty {
                let output = list.reduce(0) { $0 + $1.session.bytesReceived }
                if outputCounted[id] != output {
                    outputCounted[id] = output
                    refreshChanges(id)
                }
            }
        }
        if beats % 90 == 0 { refreshPullRequests() }
        for tab in tabs.values.joined() {
            if beats % 2 == 0 {
                let ports = tab.session.listeningPorts()
                if tab.ports != ports { tab.ports = ports }
            }
            let agent = tab.session.foregroundProgram().flatMap(TabProgram.init(rawValue:)).flatMap { $0 == .terminal ? nil : $0 }
            if tab.agent != agent {
                tab.agent = agent
                tab.activeAt = .now
            }
        }
        for project in state.projects {
            let branch = Git.currentBranch(in: project.path) ?? ""
            if mainBranches[project.id] != branch { mainBranches[project.id] = branch }
        }
    }

    /// Recounts a workspace's uncommitted changes in the background.
    func refreshChanges(_ id: UUID) {
        guard let workspace = workspace(id), !workspace.isArchived, folderExists(workspace) else { return }
        // Asked while counting: count once more after, or files changed
        // since the count began would go unseen until the next one.
        if countingChanges[id] != nil { return countingChanges[id] = true }
        countingChanges[id] = false
        let path = workspace.path
        Task {
            let counted = await Task.detached(priority: .utility) { Git.changes(in: path) }.value
            let again = countingChanges.removeValue(forKey: id) == true
            if changes[id] != counted { changes[id] = counted }
            if again { refreshChanges(id) }
        }
    }

    /// Asks GitHub for each project's pull requests in the background.
    func refreshPullRequests() {
        for project in state.projects where fetchingPullRequests.insert(project.id).inserted {
            let path = project.path
            Task {
                let found = await Task.detached(priority: .utility) { GitHub.pullRequests(in: path) }.value
                fetchingPullRequests.remove(project.id)
                if let found { setPullRequests(found, of: project.id) }
            }
        }
    }

    func setPullRequests(_ found: [String: GitHub.PullRequest], of projectID: UUID) {
        let before = pullRequests[projectID]
        guard before != found else { return }
        pullRequests[projectID] = found
        // The first look after launch has nothing to compare with.
        guard let before, let project = project(projectID) else { return }
        for workspace in workspaces(in: project) {
            let branch = branch(of: workspace)
            guard let news = found[branch]?.news(since: before[branch]),
                  !((NSApp?.isActive ?? false) && selection == workspace.id) else { continue }
            notify?("\(project.name) · \(workspace.name)", news, workspace.id)
        }
    }

    /// The branch a workspace is on: its own, or for a main checkout the one checked out now.
    public func branch(of workspace: Workspace) -> String {
        isMain(workspace) ? mainBranches[workspace.projectID] ?? "" : workspace.branch
    }

    public func pullRequest(of workspace: Workspace) -> GitHub.PullRequest? {
        let branch = branch(of: workspace)
        return branch.isEmpty ? nil : pullRequests[workspace.projectID]?[branch]
    }

    /// Gives a tab a title of the user's; an empty one gives it back its program's.
    public func renameTab(_ id: UUID, to title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        tab(id)?.customTitle = title.isEmpty ? nil : title
        saveTabs()
    }

    /// Clears "done" from a workspace's tabs, as if each had been looked at.
    public func markRead(_ workspaceID: UUID) {
        for tab in tabs[workspaceID] ?? [] where statuses[tab.id] == .done { statuses[tab.id] = nil }
    }

    /// Folds a project in the sidebar to its name, or opens it again.
    public func setCollapsed(_ projectID: UUID, _ collapsed: Bool) {
        if collapsed { state.collapsedProjects.insert(projectID) } else { state.collapsedProjects.remove(projectID) }
        save()
    }

    private func save() {
        do { try store.save(state) } catch { errorMessage = String(localized: "상태를 저장하지 못했습니다: \(error.localizedDescription)") }
    }

    // MARK: Lookup

    /// A project's own checkout, shown as a workspace named "main".
    public func mainWorkspace(of project: Project) -> Workspace {
        var workspace = Workspace(projectID: project.id, name: project.mainName ?? "main", branch: "", path: project.path)
        workspace.id = project.id
        return workspace
    }

    public func isMain(_ workspace: Workspace) -> Bool { workspace.id == workspace.projectID }

    public func workspaces(in project: Project, archived: Bool = false) -> [Workspace] {
        var own = state.workspaces.filter { $0.projectID == project.id && $0.isArchived == archived }
        // The stored project's place: the caller's copy may be older than a move.
        let position = self.project(project.id)?.mainPosition ?? 0
        if !archived { own.insert(mainWorkspace(of: project), at: min(position, own.count)) }
        return own
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

    // MARK: Windows

    /// Workspaces in windows of their own. The main window doesn't show
    /// their terminals (a terminal is drawn in one place at a time).
    public var ownWindows: [UUID] { state.windows }
    /// Shows (or brings forward) a workspace's own window.
    @ObservationIgnored public var onShowWindow: ((UUID) -> Void)?

    public func openInOwnWindow(_ id: UUID) {
        guard let workspace = workspace(id), !workspace.isArchived else { return }
        if !state.windows.contains(id) {
            state.windows.append(id)
            save()
        }
        onShowWindow?(id)
    }

    /// Its window closed: the workspace is the main window's again.
    public func closeOwnWindow(_ id: UUID) {
        guard state.windows.contains(id) else { return }
        state.windows.removeAll { $0 == id }
        save()
    }

    public func select(_ id: UUID?) {
        let before = place
        defer { record(before) }
        selection = id
        if let id, state.windows.contains(id) { onShowWindow?(id) }
        if let id, workspace(id) != nil, state.lastSelection != id {
            state.lastSelection = id
            save()
        }
        guard let id, let workspace = workspace(id), !workspace.isArchived, folderExists(workspace) else { return }
        refreshChanges(id)
        if (tabs[id] ?? []).isEmpty { openTab(in: id) }
        tabBecameVisible()
    }

    /// Opens a tab in the workspace running `program`: a shell, or an agent in one.
    @discardableResult
    public func openTab(in workspaceID: UUID, program: TabProgram) -> TerminalTab? {
        prepare(program, in: workspace(workspaceID)?.path)
        return openTab(in: workspaceID, command: state.settings.command(for: program))
    }

    /// A shell beside the open tab: in the folder that tab's shell is in
    /// now, as other terminals do. Agents still start at the workspace's
    /// top, where their project settings are.
    @discardableResult
    public func openTabBeside(in workspaceID: UUID) -> TerminalTab? {
        let here = activeTabs[workspaceID].flatMap(tab)?.session.currentDirectory()
        return openTab(in: workspaceID, cwd: here)
    }

    /// Opens a shell in the workspace, in `cwd` if given and still there.
    /// `command` is typed into it once it starts.
    @discardableResult
    public func openTab(in workspaceID: UUID, command: String? = nil, cwd: String? = nil) -> TerminalTab? {
        guard let workspace = workspace(workspaceID), folderExists(workspace) else { return nil }
        var isFolder: ObjCBool = false
        let folder = cwd.flatMap { FileManager.default.fileExists(atPath: $0, isDirectory: &isFolder) && isFolder.boolValue ? $0 : nil }
            ?? workspace.path
        let id = UUID()
        let session = TerminalSession(id: id)
        let tab = makeTab(session, in: workspaceID)
        let environment = environment(for: tab, workspace: workspace)
        if let host, let carried = host.open(
            id: id, workspace: workspaceID, shell: Self.loginShell, cwd: folder, environment: environment,
            cols: session.cols, rows: session.rows, command: command // the host types it, as writeWhenReady does
        ) {
            session.attach(fd: carried.fd, pid: carried.pid, remote: remote(for: id, host: host))
        } else {
            do {
                try session.start(shell: Self.loginShell, cwd: folder, environment: environment)
            } catch {
                errorMessage = String(localized: "셸을 시작하지 못했습니다: \(error.localizedDescription)")
                return nil
            }
            if let command, !command.isEmpty { session.writeWhenReady(command + "\n") }
        }

        tabs[workspaceID, default: []].append(tab)
        if let current = activeTabs[workspaceID] { recentTab[workspaceID] = current }
        activeTabs[workspaceID] = id
        saveTabs()
        return tab
    }

    /// A tab for `session`, wired to the model. The session and view call
    /// these on the main thread.
    private func makeTab(_ session: TerminalSession, in workspaceID: UUID) -> TerminalTab {
        let id = session.id
        let tab = TerminalTab(id: id, workspaceID: workspaceID, session: session)
        applyPreferences(to: session)
        session.onTitle = { [weak tab] title in MainActor.assumeIsolated { tab?.title = title } }
        session.onSignal = { [weak self] signal in MainActor.assumeIsolated { self?.handle(signal, tab: id) } }
        session.onExit = { [weak self] in MainActor.assumeIsolated { self?.closeTab(id) } }
        return tab
    }

    private func remote(for id: UUID, host: TerminalHostClient) -> TerminalSession.Remote {
        TerminalSession.Remote(
            resize: { cols, rows, width, height in host.resize(id, cols: cols, rows: rows, width: width, height: height) },
            end: { host.close(id) })
    }

    /// Attaches to the terminals the host kept while the app was away, in
    /// the order the tabs had, with their titles and which one was open.
    /// A terminal whose workspace is gone is ended.
    private func restoreTabs() {
        guard let host else { return }
        let alive = host.list()
        let saved = Dictionary(state.tabs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let rank = Dictionary(state.tabs.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Saved ones in their order, then any the app never saved (it crashed first).
        for session in alive.sorted(by: { rank[$0.id, default: .max] < rank[$1.id, default: .max] }) {
            guard let workspace = workspace(session.workspace), !workspace.isArchived else {
                host.close(session.id)
                continue
            }
            guard let carried = host.attach(id: session.id) else { continue }
            let terminal = TerminalSession(id: session.id, cols: carried.cols, rows: carried.rows)
            let tab = makeTab(terminal, in: workspace.id)
            tab.customTitle = saved[session.id]?.title
            terminal.attach(fd: carried.fd, pid: carried.pid, remote: remote(for: session.id, host: host))
            tabs[workspace.id, default: []].append(tab)
            // Waiting or done while the app was away: still to be seen to.
            if carried.status != .idle {
                tab.hasStructuredStatus = true
                statuses[session.id] = carried.status
            }
            if saved[session.id]?.active == true || activeTabs[workspace.id] == nil { activeTabs[workspace.id] = session.id }
        }
        // Splits again, with the panes whose terminals came back; a split
        // whose head is gone is headed by its next pane.
        let open = Set(tabs.values.joined().map(\.id))
        for (key, node) in state.splits {
            guard let head = UUID(uuidString: key), let kept = node.keeping(open), kept.panes.count > 1,
                  let workspace = tab(kept.panes[0])?.workspaceID,
                  kept.panes.allSatisfy({ tab($0)?.workspaceID == workspace }) else { continue }
            let newHead = kept.panes.contains(head) ? head : kept.panes[0]
            splits[newHead] = kept
        }
        saveTabs()
    }

    /// Remembers the open tabs, for attaching to them again next time.
    private func saveTabs() {
        let open = tabs.flatMap { workspace, list in
            list.map { SavedTab(id: $0.id, workspace: workspace, title: $0.customTitle, active: activeTabs[workspace] == $0.id) }
        }
        let layouts = Dictionary(uniqueKeysWithValues: splits.map { ($0.key.uuidString, $0.value) })
        guard open != state.tabs || layouts != state.splits else { return }
        state.tabs = open
        state.splits = layouts
        save()
    }

    /// The app is quitting: each terminal's screen goes to the host, which
    /// keeps it, and its program, until the app attaches again.
    public func parkTerminals() {
        guard let host else { return }
        for tab in tabs.values.joined() where tab.session.isRemote {
            let (screen, received) = tab.session.snapshot()
            host.park(tab.id, snapshot: screen, received: received, status: statuses[tab.id] ?? .idle)
        }
    }

    /// Tabs whose programs end when the app quits: those the host doesn't keep.
    public var tabsEndingOnQuit: Int {
        tabs.values.joined().filter { !$0.session.isRemote }.count
    }

    public func activateTab(_ id: UUID) {
        guard let tab = tab(id) else { return }
        splitFocus[head(of: id)] = id
        let before = place
        if let current = activeTabs[tab.workspaceID], current != id { recentTab[tab.workspaceID] = current }
        activeTabs[tab.workspaceID] = id
        tabBecameVisible()
        record(before)
        saveTabs()
    }

    /// Moves to the next (+1) or previous (-1) tab of the selected workspace.
    public func cycleTab(_ offset: Int) {
        guard let selection, let active = activeTabs[selection] else { return }
        let list = tabBarTabs(in: selection)
        guard list.count > 1, let index = list.firstIndex(where: { $0.id == head(of: active) }) else { return }
        selectTabBarTab(list[(index + offset + list.count) % list.count].id)
    }

    public func activateTab(at index: Int) {
        guard let selection else { return }
        let list = tabBarTabs(in: selection)
        guard list.indices.contains(index) else { return }
        selectTabBarTab(list[index].id)
    }

    /// Tabs closed lately, newest last: what ⇧⌘T opens again.
    struct ClosedTab {
        let workspace: UUID
        let folder: String?
        let title: String?
    }
    @ObservationIgnored private(set) var closedTabs: [ClosedTab] = []

    /// Opens the last closed tab again: a new shell where the old one was,
    /// with the title it was given. What ran in it is gone.
    @discardableResult
    public func reopenClosedTab() -> TerminalTab? {
        while let closed = closedTabs.popLast() {
            guard let workspace = workspace(closed.workspace), !workspace.isArchived, folderExists(workspace) else { continue }
            navigate { selection = closed.workspace }
            guard let tab = openTab(in: closed.workspace, cwd: closed.folder) else { return nil }
            if let title = closed.title { renameTab(tab.id, to: title) }
            return tab
        }
        return nil
    }

    public func closeTab(_ id: UUID) {
        guard let tab = tab(id), var list = tabs[tab.workspaceID], let index = list.firstIndex(where: { $0.id == id }) else { return }
        closedTabs.append(ClosedTab(workspace: tab.workspaceID, folder: tab.session.currentDirectory(), title: tab.customTitle))
        if closedTabs.count > 20 { closedTabs.removeFirst() }
        tab.session.onExit = nil
        tab.session.terminate()
        // A pane gives the keyboard to the pane next to it (the one it was
        // split from, usually), not to another tab.
        let order = layout(of: head(of: id)).panes
        let sibling = order.firstIndex(of: id).flatMap { at in
            order.count > 1 ? order[at > 0 ? at - 1 : at + 1] : nil
        }
        leaveSplit(id, workspace: tab.workspaceID)
        list = tabs[tab.workspaceID] ?? list
        guard let at = list.firstIndex(where: { $0.id == id }) else { return }
        list.remove(at: at)
        tabs[tab.workspaceID] = list
        statuses[id] = nil
        if activeTabs[tab.workspaceID] == id {
            let bar = tabBarTabs(in: tab.workspaceID)
            activeTabs[tab.workspaceID] = sibling ?? (bar.isEmpty ? nil : bar[min(index, bar.count - 1)].id)
        }
        saveTabs()
    }

    private func closeAllTabs(in workspaceID: UUID) {
        for tab in tabs[workspaceID] ?? [] { closeTab(tab.id) }
        tabs[workspaceID] = nil
        activeTabs[workspaceID] = nil
    }

    /// "zsh", "fish"…: what a tab is called while only the shell runs in it.
    static let shellName = (loginShell as NSString).lastPathComponent

    private static let loginShell: String = {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            let path = String(cString: shell)
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return "/bin/zsh"
    }()

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
        if host != nil { env["PLUM_HOST_SOCKET"] = TerminalHost.socketPath(for: store) }
        if state.settings.shellIntegration, !zshIntegrationPath.isEmpty, Self.shellName == "zsh" {
            // Plum's .zshenv puts the user's ZDOTDIR back before anything of theirs runs.
            env["PLUM_USER_ZDOTDIR"] = env["ZDOTDIR"]
            env["ZDOTDIR"] = zshIntegrationPath
        }
        return env
    }

    // MARK: Agent status

    /// On screen now: its tab is the open one (all of a split's panes show).
    private func isVisible(_ tab: TerminalTab) -> Bool {
        guard (NSApp?.isActive ?? false), selection == tab.workspaceID, let active = activeTabs[tab.workspaceID] else { return false }
        return head(of: active) == head(of: tab.id)
    }

    // MARK: Splits

    /// A terminal by id, wherever it is.
    public func terminal(_ id: UUID) -> TerminalTab? { tab(id) }

    /// The tab a terminal is shown under: itself, or the head of its split.
    public func head(of id: UUID) -> UUID {
        splits.first { $0.value.panes.contains(id) }?.key ?? id
    }

    /// How a tab's panes share its space: a single pane unless it's split.
    public func layout(of head: UUID) -> SplitNode {
        splits[head] ?? .pane(head)
    }

    /// The tabs the tab bar shows: every tab but the extra panes of splits.
    public func tabBarTabs(in workspaceID: UUID) -> [TerminalTab] {
        let hidden = Set(splits.flatMap { head, node in node.panes.filter { $0 != head } })
        return (tabs[workspaceID] ?? []).filter { !hidden.contains($0.id) }
    }

    /// The tab bar's choice: the tab, at the pane last used in it.
    public func selectTabBarTab(_ head: UUID) {
        let pane = splitFocus[head].flatMap { layout(of: head).panes.contains($0) ? $0 : nil } ?? head
        activateTab(pane)
    }

    /// Splits the pane with the keyboard in two: a new shell beside it
    /// (right) or below it, in the folder it's in. The new one gets the keyboard.
    @discardableResult
    public func splitPane(_ axis: SplitNode.Axis) -> TerminalTab? {
        guard let selection, let active = activeTabs[selection] else { return nil }
        let head = head(of: active)
        let folder = tab(active)?.session.currentDirectory()
        guard let pane = openTab(in: selection, cwd: folder) else { return nil }
        splits[head] = layout(of: head).replacing(active, with: .split(axis, ratio: 0.5, .pane(active), .pane(pane.id)))
        splitFocus[head] = pane.id
        saveTabs()
        return pane
    }

    /// ⌘⌥ and an arrow: the keyboard goes to the pane that way.
    public func focusPane(dx: Int, dy: Int) {
        guard let selection, let active = activeTabs[selection],
              let next = layout(of: head(of: active)).neighbor(of: active, dx: dx, dy: dy) else { return }
        activateTab(next)
    }

    /// A divider was dragged. `path` leads from the split's top to the
    /// divided pair (false: first part, true: second).
    public func setSplitRatio(_ head: UUID, path: [Bool], ratio: Double, done: Bool) {
        guard let node = splits[head] else { return }
        splits[head] = node.settingRatio(ratio, at: path)
        if done { saveTabs() }
    }

    /// The tab bar's tab as one: all its panes.
    public func panes(ofTab head: UUID) -> [UUID] { layout(of: head).panes }

    /// Drops a pane from its split. The next pane heads a split whose head
    /// went, in its place in the tab order.
    private func leaveSplit(_ id: UUID, workspace: UUID) {
        let head = head(of: id)
        guard let node = splits[head] else { return }
        splits[head] = nil
        guard let rest = node.removing(id), rest.panes.count > 1 else { return splitFocus[head] = nil }
        if head == id, let next = rest.panes.first {
            splits[next] = rest
            splitFocus[next] = splitFocus[head].flatMap { rest.panes.contains($0) ? $0 : nil }
            splitFocus[head] = nil
            // The new head stands where the old one stood in the tab bar.
            if var list = tabs[workspace], let from = list.firstIndex(where: { $0.id == next }),
               let to = list.firstIndex(where: { $0.id == id }) {
                list.insert(list.remove(at: from), at: to)
                tabs[workspace] = list
            }
        } else {
            splits[head] = rest
        }
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
        tab.activeAt = .now
        refreshChanges(tab.workspaceID) // an agent that stops has usually just edited files

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

    /// Workspaces in sidebar order: each project's main checkout, then its
    /// workspaces. A folded project's are out of sight, and skipped.
    public var workspaceOrder: [UUID] {
        state.projects.filter { !state.collapsedProjects.contains($0.id) }.flatMap { workspaces(in: $0) }.map(\.id)
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

    /// Moves a workspace, the main checkout included, `offset` places up
    /// (negative) or down among its project's workspaces.
    public func moveWorkspace(_ id: UUID, by offset: Int) {
        guard offset != 0, let moving = workspace(id), !moving.isArchived,
              let project = state.projects.firstIndex(where: { $0.id == moving.projectID }) else { return }
        var rows = workspaces(in: state.projects[project])
        guard let from = rows.firstIndex(where: { $0.id == id }), rows.indices.contains(from + offset) else { return }
        rows.insert(rows.remove(at: from), at: from + offset)
        // The main checkout's place is kept on the project; the others go
        // back into the slots the project's workspaces had in the list.
        let mainID = state.projects[project].id
        let main = rows.firstIndex { $0.id == mainID } ?? 0
        state.projects[project].mainPosition = main == 0 ? nil : main
        let slots = state.workspaces.indices.filter { state.workspaces[$0].projectID == mainID && !state.workspaces[$0].isArchived }
        for (slot, row) in zip(slots, rows.filter { $0.id != mainID }) { state.workspaces[slot] = row }
        save()
    }

    /// Starts a pull request for the workspace's branch in a new tab: gh
    /// asks there where to push, then opens GitHub's form in the browser.
    public func createPullRequest(_ workspaceID: UUID) {
        navigate { selection = workspaceID }
        openTab(in: workspaceID, command: "gh pr create --web")
    }

    /// Moves a tab to where another one is, as a drag drops it.
    public func moveTab(_ id: UUID, to target: UUID) {
        let (id, target) = (head(of: id), head(of: target))
        guard id != target, let tab = tab(id), var list = tabs[tab.workspaceID],
              let from = list.firstIndex(where: { $0.id == id }), let to = list.firstIndex(where: { $0.id == target }) else { return }
        list.insert(list.remove(at: from), at: to)
        tabs[tab.workspaceID] = list
        saveTabs()
    }

    /// Moves a tab one place left (-1) or right (+1) in the tab bar.
    public func moveTab(_ id: UUID, by offset: Int) {
        let head = head(of: id)
        guard let tab = tab(head) else { return }
        let bar = tabBarTabs(in: tab.workspaceID)
        guard let index = bar.firstIndex(where: { $0.id == head }), bar.indices.contains(index + offset) else { return }
        moveTab(head, to: bar[index + offset].id)
    }

    /// Programs running in the foreground of a workspace's tabs, by name.
    public func runningPrograms(in workspaceID: UUID) -> [String] {
        (tabs[workspaceID] ?? []).compactMap { $0.session.foregroundProgram() }
    }

    /// Brings a tab to the front, e.g. from a clicked notification.
    public func reveal(tab id: UUID) {
        guard let tab = tab(id) else {
            if workspace(id) != nil { select(id) } // a notification about a workspace (its pull request)
            return
        }
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
        refreshPullRequests() // now, not at the next three-minute beat
        // Worktrees the repository already has show up with it.
        Task { await importWorktrees(of: project.id) }
    }

    /// Lists as workspaces the worktrees git already has for a project and
    /// Plum doesn't: made by hand or by another tool. Nothing on disk
    /// changes. Detached ones (no branch) are left out: a workspace is a
    /// branch. Returns how many were added.
    @discardableResult
    public func importWorktrees(of projectID: UUID) async -> Int {
        guard let project = project(projectID) else { return 0 }
        let found = await Task.detached { Git.worktrees(in: project.path) }.value
        var added = 0
        for worktree in found {
            guard let branch = worktree.branch, !WorkspaceService.samePath(worktree.path, project.path),
                  FileManager.default.fileExists(atPath: worktree.path),
                  !state.workspaces.contains(where: { WorkspaceService.samePath($0.path, worktree.path) }) else { continue }
            let folder = (worktree.path as NSString).lastPathComponent
            var name = folder
            var suffix = 2
            while state.workspaces.contains(where: { $0.projectID == projectID && $0.name == name }) {
                name = "\(folder)-\(suffix)"
                suffix += 1
            }
            state.workspaces.append(Workspace(projectID: projectID, name: name, branch: branch, path: worktree.path))
            added += 1
        }
        if added > 0 {
            save()
            refreshPullRequests()
        }
        return added
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

    /// Gives a workspace a new name. Only the name shown changes: its folder
    /// and branch stay as they are. Returns why not, if it can't be done.
    @discardableResult
    public func renameWorkspace(_ id: UUID, to newName: String) -> String? {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let workspace = workspace(id), !name.isEmpty, name != workspace.name,
              let project = state.projects.firstIndex(where: { $0.id == workspace.projectID })
        else { return nil }
        let siblings = [mainWorkspace(of: state.projects[project])] + state.workspaces.filter { $0.projectID == workspace.projectID }
        if siblings.contains(where: { $0.id != id && $0.name == name }) {
            return String(localized: "같은 이름의 워크스페이스가 이미 있습니다: \(name)")
        }
        if isMain(workspace) {
            state.projects[project].mainName = name == "main" ? nil : name
        } else if let index = state.workspaces.firstIndex(where: { $0.id == id }) {
            state.workspaces[index].name = name
        }
        save()
        return nil
    }

    public func setSidebarWidth(_ width: Double?) {
        guard state.sidebarWidth != width else { return }
        state.sidebarWidth = width
        save()
    }

    public func update(_ settings: AppSettings) {
        var settings = settings
        settings.fontSize = min(40, max(8, settings.fontSize))
        settings.scrollbackMB = min(1000, max(1, settings.scrollbackMB))
        let terminalChanged = (settings.cursorShape, settings.cursorBlinks, settings.scrollbackMB)
            != (state.settings.cursorShape, state.settings.cursorBlinks, state.settings.scrollbackMB)
        let lookChanged = settings.accent != state.settings.accent
        state.settings = settings
        save()
        if terminalChanged { for tab in tabs.values.joined() { applyPreferences(to: tab.session) } }
        if lookChanged { onLookChanged?() }
    }

    /// The app redraws in the new accent.
    @ObservationIgnored public var onLookChanged: (() -> Void)?

    /// Every terminal in these colors (the accent changed).
    public func applyTerminalTheme(_ theme: TerminalTheme) {
        for tab in tabs.values.joined() { tab.session.applyTheme(theme) }
    }

    private func applyPreferences(to session: TerminalSession) {
        let settings = state.settings
        session.applyPreferences(cursor: settings.cursorShape, blink: settings.cursorBlinks, scrollbackMB: settings.scrollbackMB)
    }

    // MARK: Workspace lifecycle

    /// Before an agent opens in `folder`, Orca-style: its config is told the
    /// folder is trusted, so it starts working instead of asking.
    private func prepare(_ program: TabProgram, in folder: String?) {
        guard state.settings.trustWorkspaces, let folder else { return }
        switch program {
        case .claude: ClaudeTrust.grant(folder)
        case .codex: CodexTrust.grant(folder)
        case .terminal: break
        }
    }

    /// What the first tab of a fresh worktree runs: setup, then the program chosen.
    func firstCommand(for project: Project, program: TabProgram) -> String {
        [project.setupCommand, state.settings.command(for: program) ?? ""]
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

    public func createWorkspace(
        projectID: UUID, name: String, branch: String, choice: WorkspaceService.BranchChoice, program: TabProgram
    ) async throws {
        guard let project = project(projectID) else { return }
        if state.settings.newWorkspaceProgram != program {
            state.settings.newWorkspaceProgram = program
            save()
        }
        let root = state.settings.workspaceRoot
        let existing = state.workspaces
        let setup = firstCommand(for: project, program: program)
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
        refreshChanges(created.workspace.id)
        // The user may have moved on while git worked.
        if selection == id { selection = created.workspace.id }
        prepare(program, in: created.workspace.path)
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
        refreshChanges(id)
        selection = id
        prepare(state.settings.newWorkspaceProgram, in: created.workspace.path)
        openTab(in: id, command: firstCommand(for: project, program: state.settings.newWorkspaceProgram))
    }
}
