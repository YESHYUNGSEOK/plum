import AppKit

/// Test hooks, reachable over the status socket only when the app was
/// started with PLUM_DEBUG=1. They let a script drive the app and read back
/// what it shows, which is how the end-to-end checks in README were run.
extension AppModel {
    func handleDebug(_ line: String) -> String {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        let argument = parts.count > 1 ? parts[1] : ""
        let fields = argument.components(separatedBy: "|")

        func find(_ name: String) -> Workspace? {
            state.workspaces.first { $0.name == name } ?? state.projects.first { $0.name == name }.map(mainWorkspace)
        }
        func background(_ operation: @escaping () async throws -> Void) -> String {
            debugResult = "pending"
            Task {
                do {
                    try await operation()
                    debugResult = "ok"
                } catch {
                    debugResult = "error: \(error.localizedDescription)"
                }
            }
            return "started"
        }

        switch parts.first ?? "" {
        case "state":
            return debugState()
        case "add-project":
            addProject(at: argument)
            return errorMessage ?? "ok"
        case "set-project": // name|copy patterns (comma separated)|setup|agent
            guard fields.count == 4, var project = state.projects.first(where: { $0.name == fields[0] }) else { return "bad arguments" }
            project.copyPatterns = fields[1].split(separator: ",").map(String.init)
            project.setupCommand = fields[2]
            project.agentCommand = fields[3]
            update(project)
            return "ok"
        case "create": // project|name|branch|new or existing
            guard fields.count == 4, let project = state.projects.first(where: { $0.name == fields[0] }) else { return "bad arguments" }
            return background {
                try await self.createWorkspace(
                    projectID: project.id, name: fields[1], branch: fields[2],
                    choice: fields[3] == "existing" ? .existing : .new(base: nil))
            }
        case "check": // name|0 or 1 (branch would be deleted)
            guard fields.count == 2, let workspace = find(fields[0]), let project = project(workspace.projectID) else { return "bad arguments" }
            let check = WorkspaceService.inspect(workspace, project: project, deletingBranch: fields[1] == "1")
            return json(["missing": check.folderMissing, "uncommitted": check.uncommitted, "unpushed": check.unpushed])
        case "archive", "delete": // name|0 or 1 (force)
            guard fields.count == 2, let workspace = find(fields[0]) else { return "bad arguments" }
            let force = fields[1] == "1"
            return background {
                if parts[0] == "archive" { try await self.archive(workspace.id, force: force) } else { try await self.delete(workspace.id, force: force) }
            }
        case "restore":
            guard let workspace = find(argument) else { return "bad arguments" }
            return background { try await self.restore(workspace.id) }
        case "select":
            guard let workspace = find(argument) else { return "bad arguments" }
            select(workspace.id)
            return "ok"
        case "newtab":
            return selection.flatMap { openTab(in: $0) }.map(\.id.uuidString) ?? "no workspace"
        case "closetab":
            activeTab.map { closeTab($0.id) }
            return "ok"
        case "type": // text typed into the active tab; \n and \e are unescaped
            guard let tab = activeTab else { return "no tab" }
            tab.session.write(argument.replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\e", with: "\u{1b}"))
            return "ok"
        case "key": // keyCode|modifier flags raw value|characters
            guard fields.count == 3, activeTab != nil, let code = UInt16(fields[0]), let flags = UInt(fields[1]),
                  let event = NSEvent.keyEvent(
                      with: .keyDown, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: flags),
                      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: debugWindowNumber?() ?? 0, context: nil,
                      characters: fields[2], charactersIgnoringModifiers: fields[2], isARepeat: false, keyCode: code)
            else { return "bad arguments" }
            debugTerminalView?()?.keyDown(with: event)
            return "ok"
        case "drag": // column|row|column|row, in viewport cells
            let cells = fields.compactMap { Int($0) }
            guard cells.count == 4, let tab = activeTab else { return "bad arguments" }
            tab.session.select(from: (cells[0], cells[1]), to: (cells[2], cells[3]))
            debugTerminalView?()?.selectionChanged()
            return "ok"
        case "stats":
            let received = tabs.values.joined().reduce(0) { $0 + $1.session.bytesReceived }
            return "frames=\(TerminalView.framesDrawn) bytes=\(received)"
        case "occlusion":
            return debugWindow?()?.occlusionState.contains(.visible) == true ? "visible" : "occluded"
        case "miniaturize":
            debugWindow?()?.miniaturize(nil)
            return "ok"
        case "deminiaturize":
            debugWindow?()?.deminiaturize(nil)
            return "ok"
        case "show-everywhere": // puts the window on the current Space without taking focus
            guard let window = debugWindow?() else { return "no window" }
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.orderFrontRegardless()
            return "ok"
        case "notifications":
            return "badge=\(NSApp.dockTile.badgeLabel ?? "none"); " + (debugNotificationStatus?() ?? "unavailable")
        case "text":
            return activeTab?.session.screenText() ?? ""
        case "selected":
            return activeTab?.session.selectedText() ?? ""
        default:
            return "unknown command"
        }
    }

    private func json(_ object: Any) -> String {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    private func debugState() -> String {
        json([
            "window": debugWindowNumber?() ?? 0,
            "result": debugResult,
            "error": errorMessage ?? "",
            "selection": selectedWorkspace?.name ?? "",
            "projects": state.projects.map { ["name": $0.name, "path": $0.path] },
            "workspaces": state.workspaces.map { workspace in
                [
                    "name": workspace.name, "branch": workspace.branch, "path": workspace.path,
                    "archived": workspace.isArchived, "exists": folderExists(workspace),
                    "status": status(of: workspace.id).rawValue,
                ] as [String: Any]
            },
            "tabs": tabs.values.joined().map { tab in
                [
                    "id": tab.id.uuidString, "workspace": workspace(tab.workspaceID)?.name ?? "",
                    "title": titles[tab.id] ?? "", "status": (statuses[tab.id] ?? .idle).rawValue,
                    "cols": Int(tab.session.cols), "rows": Int(tab.session.rows), "running": tab.session.isRunning,
                    "active": activeTabs[tab.workspaceID] == tab.id,
                ] as [String: Any]
            },
        ] as [String: Any])
    }
}
