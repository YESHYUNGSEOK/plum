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
        case "closetab": // as ⌘W: asks first if a program runs in the tab
            activeTab.map { AppActions.closeTab(self, $0.id) }
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
        case "hit": // x|y from the window's top-left: which view would get a click there
            guard fields.count == 2, let x = Double(fields[0]), let y = Double(fields[1]), let window = debugWindow?(),
                  let frame = window.contentView?.superview else { return "bad arguments" }
            let view = frame.hitTest(NSPoint(x: x, y: frame.bounds.height - y))
            return view.map { String(describing: type(of: $0)) } ?? "nothing"
        case "toggle-sidebar":
            debugToggleSidebar?()
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
        case "sheet": // new|project, project|project, settings, archive|workspace, delete|workspace, close
            let project = state.projects.first { $0.name == fields.last }
            switch fields[0] {
            case "new": sheet = project.map(AppSheet.newWorkspace)
            case "project": sheet = project.map(AppSheet.projectSettings)
            case "settings": sheet = .settings
            case "archive", "delete":
                guard fields.count == 2, let workspace = find(fields[1]) else { return "bad arguments" }
                if fields[0] == "archive" { AppActions.archive(self, workspace) } else { AppActions.delete(self, workspace) }
            case "close": sheet = nil
            default: return "bad arguments"
            }
            return "ok"
        case "error": // shows the error toast; empty clears it
            errorMessage = argument.isEmpty ? nil : argument
            return "ok"
        case "quit": // as ⌘Q
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return "ok"
        case "close-window": // as the red button
            DispatchQueue.main.async { self.debugWindow?()?.performClose(nil) }
            return "ok"
        case "keywin": // keyCode|characters[|modifier flags raw value]: a key press, as if typed
            guard fields.count >= 2, let code = UInt16(fields[0]), let window = debugWindow?(),
                  let event = NSEvent.keyEvent(
                      with: .keyDown, location: .zero,
                      modifierFlags: NSEvent.ModifierFlags(rawValue: fields.count > 2 ? UInt(fields[2]) ?? 0 : 0),
                      timestamp: ProcessInfo.processInfo.systemUptime,
                      windowNumber: window.windowNumber, context: nil, characters: fields[1],
                      charactersIgnoringModifiers: fields[1], isARepeat: false, keyCode: code)
            else { return "bad arguments" }
            // Through the application, as a real key press goes: key
            // equivalents (default buttons) are matched there first.
            NSApp.sendEvent(event)
            return "ok"
        case "responder": // what holds the keyboard, and the views it sits in
            guard let responder = debugWindow?()?.firstResponder else { return "none" }
            var chain = [String(describing: type(of: responder))]
            var view = (responder as? NSView)?.superview
            while let current = view, chain.count < 6 {
                chain.append((String(describing: type(of: current)).components(separatedBy: "<").first ?? "") + (current.isHidden ? "(hidden)" : ""))
                view = current.superview
            }
            return chain.joined(separator: " < ")
        case "click": // column|row[|modifier flags raw value[|click count]]: a real mouse click on a terminal cell
            let numbers = fields.compactMap { UInt($0) }
            guard numbers.count >= 2, let window = debugWindow?(), let terminal = debugTerminalView?() else { return "bad arguments" }
            let point = terminal.windowPoint(column: Int(numbers[0]), row: Int(numbers[1]))
            let flags = NSEvent.ModifierFlags(rawValue: numbers.count > 2 ? numbers[2] : 0)
            let clicks = numbers.count > 3 ? Int(numbers[3]) : 1
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let event = NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)
                else { return "no event" }
                NSApp.sendEvent(event)
            }
            return "ok"
        case "mousedrag": // column|row|column|row[|modifier flags on the press]: press, drag and release
            // A window in the background takes a plain first click only to come
            // forward; ⌘ makes it a click, as on any Mac.
            let cells = fields.compactMap { Int($0) }
            guard cells.count >= 4, let window = debugWindow?(), let terminal = debugTerminalView?() else { return "bad arguments" }
            let pressFlags = NSEvent.ModifierFlags(rawValue: cells.count > 4 ? UInt(cells[4]) : 0)
            let from = terminal.windowPoint(column: cells[0], row: cells[1]), to = terminal.windowPoint(column: cells[2], row: cells[3])
            let steps: [(NSEvent.EventType, NSPoint)] = [(.leftMouseDown, from)]
                + (1...4).map { (.leftMouseDragged, NSPoint(x: from.x + (to.x - from.x) * Double($0) / 4, y: from.y + (to.y - from.y) * Double($0) / 4)) }
                + [(.leftMouseUp, to)]
            for (type, point) in steps {
                guard let event = NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: type == .leftMouseDown ? pressFlags : [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
                else { return "no event" }
                NSApp.sendEvent(event)
            }
            return "ok"
        case "scroll": // lines (positive: up, to older output): a wheel turned over the terminal
            guard let lines = Int32(argument), let window = debugWindow?(), let terminal = debugTerminalView?(),
                  let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0)
            else { return "bad arguments" }
            // Over the middle of the terminal, in screen coordinates (origin top left).
            let inWindow = terminal.windowPoint(column: 10, row: 3)
            let onScreen = window.convertPoint(toScreen: inWindow)
            wheel.location = CGPoint(x: onScreen.x, y: (NSScreen.screens.first?.frame.height ?? 0) - onScreen.y)
            guard let event = NSEvent(cgEvent: wheel) else { return "no event" }
            terminal.scrollWheel(with: event)
            return "deltaY=\(event.scrollingDeltaY) precise=\(event.hasPreciseScrollingDeltas)"
        case "ime": // marked|text or commit|text: what an input method calls while composing and when done
            guard fields.count == 2, let terminal = debugTerminalView?() else { return "bad arguments" }
            let none = NSRange(location: NSNotFound, length: 0)
            if fields[0] == "marked" {
                terminal.setMarkedText(fields[1], selectedRange: NSRange(location: fields[1].utf16.count, length: 0), replacementRange: none)
            } else {
                terminal.insertText(fields[1], replacementRange: none)
            }
            return terminal.hasMarkedText() ? "composing" : "committed"
        case "links": // links a click would have opened
            return DebugLog.links.joined(separator: " ")
        case "paste": // text (\n unescaped) put on the debug pasteboard, then Edit > Paste
            TerminalView.pasteboard.clearContents()
            TerminalView.pasteboard.setString(argument.replacingOccurrences(of: "\\n", with: "\n"), forType: .string)
            // To what holds the keyboard: a window in the background has no key window to route by.
            guard let responder = debugWindow?()?.firstResponder else { return "no responder" }
            NSApp.sendAction(#selector(NSText.paste(_:)), to: responder, from: nil)
            return "ok"
        case "trace-close": // closes the dialog; read the card's opacity over time with `trace`
            DebugLog.trace = "pending"
            debugTraceDialogClose? { DebugLog.trace = $0 }
            return "ok"
        case "trace":
            return DebugLog.trace
        case "hitches": // start | stop: main run loop passes longer than a 120Hz frame while running
            return argument == "start" ? HitchMeter.start() : HitchMeter.stop()
        case "menus": // the menu bar's titles, to check translations
            return (NSApp.mainMenu?.items ?? []).compactMap { $0.submenu }.map { menu in
                menu.title + ": " + menu.items.filter { !$0.isSeparatorItem }.map(\.title).joined(separator: ", ")
            }.joined(separator: " | ")
        case "windows": // window numbers, for screencapture -l
            return NSApp.windows.filter(\.isVisible).map { "\($0.windowNumber) \(type(of: $0))" }.joined(separator: "; ")
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
            "sheet": sheet?.id ?? "",
            "selectionProject": selectedWorkspace.flatMap { project($0.projectID)?.name } ?? "",
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

/// Counts main-thread run loop passes long enough to drop a frame: the
/// window can't animate or draw while the main thread is busy.
@MainActor
enum HitchMeter {
    private static var observer: CFRunLoopObserver?
    private static var wokeAt: CFAbsoluteTime = 0
    private static var long: [Double] = []

    static func start() -> String {
        _ = stop()
        long = []
        let observer = CFRunLoopObserverCreateWithHandler(
            nil, CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue, true, 0
        ) { _, activity in
            let now = CFAbsoluteTimeGetCurrent()
            if activity == .afterWaiting {
                wokeAt = now
            } else if wokeAt > 0 {
                if now - wokeAt > 1.0 / 120 { long.append((now - wokeAt) * 1000) }
                wokeAt = 0
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
        return "ok"
    }

    static func stop() -> String {
        if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        observer = nil
        let sorted = long.sorted(by: >)
        return "count=\(long.count) max=\(Int(sorted.first ?? 0))ms top=\(sorted.prefix(6).map { Int($0) })"
    }
}

/// What scripted checks read back.
@MainActor
enum DebugLog {
    static var links: [String] = []
    static var trace = ""
}
