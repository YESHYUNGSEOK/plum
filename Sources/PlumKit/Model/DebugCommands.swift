import AppKit
import GhosttyVt

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
        case "add-project": // path[|folder]
            addProject(at: fields[0], asFolder: fields.count > 1 && fields[1] == "folder")
            return errorMessage ?? "ok"
        case "set-project": // name|copy patterns (comma separated)|setup
            guard fields.count >= 3, var project = state.projects.first(where: { $0.name == fields[0] }) else { return "bad arguments" }
            project.copyPatterns = fields[1].split(separator: ",").map(String.init)
            project.setupCommand = fields[2]
            update(project)
            return "ok"
        case "pr": // project|branch|number|open, draft, merged or closed|none, pending, passing or failing: as if GitHub reported it
            let states: [String: GitHub.PullRequest.State] = ["open": .open, "draft": .draft, "merged": .merged, "closed": .closed]
            let checks: [String: GitHub.PullRequest.Checks] = ["none": .none, "pending": .pending, "passing": .passing, "failing": .failing]
            guard fields.count >= 5, let project = state.projects.first(where: { $0.name == fields[0] }), let number = Int(fields[2]),
                  let state = states[fields[3]], let checks = checks[fields[4]],
                  let url = URL(string: "https://github.com/example/repo/pull/\(number)") else { return "bad arguments" }
            var found = pullRequests[project.id] ?? [:]
            found[fields[1]] = GitHub.PullRequest(number: number, state: state, checks: checks, url: url)
            setPullRequests(found, of: project.id)
            return "ok"
        case "create": // project|name|branch|new or existing[|terminal, claude or codex]
            guard fields.count >= 4, let project = state.projects.first(where: { $0.name == fields[0] }) else { return "bad arguments" }
            let program = fields.count > 4 ? TabProgram(rawValue: fields[4]) ?? .terminal : .terminal
            return background {
                try await self.createWorkspace(
                    projectID: project.id, name: fields[1], branch: fields[2],
                    choice: fields[3] == "existing" ? .existing : .new(base: nil), program: program)
            }
        case "check": // name|0 or 1 (branch would be deleted)
            guard fields.count == 2, let workspace = find(fields[0]), let project = project(workspace.projectID) else { return "bad arguments" }
            let check = WorkspaceService.inspect(workspace, project: project, deletingBranch: fields[1] == "1")
            return json(["missing": check.folderMissing, "uncommitted": check.uncommitted, "unpushed": check.unpushed,
                         "nested": check.nested.map(\.path)])
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
        case "newtab": // [terminal|claude|codex]
            let program = TabProgram(rawValue: argument) ?? .terminal
            return selection.flatMap { openTab(in: $0, program: program) }.map(\.id.uuidString) ?? "no workspace"
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
            // "+move": a press there may move the window instead of reaching the view.
            return view.map { String(describing: type(of: $0)) + ($0.mouseDownCanMoveWindow ? " +move" : "") } ?? "nothing"
        case "winsize": // width|height in points: the window's content size
            let size = fields.compactMap { Double($0) }
            guard size.count == 2, let window = debugWindow?() else { return "bad arguments" }
            window.setContentSize(NSSize(width: size[0], height: size[1]))
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
        case "notice": // shows a notice toast (not an error); empty clears it
            notice = argument.isEmpty ? nil : argument
            return "ok"
        case "update-available": // tag: as if the daily check had found that release on GitHub; empty clears it
            let base = "https://github.com/YESHYUNGSEOK/plum/releases/download/\(argument)/Plum-\(argument.drop { !$0.isNumber })-\(Updates.architecture).zip"
            let release = try? JSONSerialization.data(withJSONObject: [
                "tag_name": argument, "html_url": "https://github.com/YESHYUNGSEOK/plum/releases",
                "assets": [["name": (base as NSString).lastPathComponent, "browser_download_url": base],
                           ["name": (base as NSString).lastPathComponent + ".sig", "browser_download_url": base + ".sig"]],
            ])
            availableUpdate = argument.isEmpty ? nil : release.flatMap { try? JSONDecoder().decode(Updates.Release.self, from: $0) }
            return "ok"
        case "import-orca": // imports from Orca without asking (its CLI, read-only); the outcome lands in "result"
            guard let cli = OrcaImport.cli() else { return "not installed" }
            debugResult = "pending"
            Task {
                do {
                    let catalog = try await OrcaImport.load(cli: cli)
                    let result = await importFromOrca(catalog)
                    debugResult = "projects=\(result.projects) workspaces=\(result.workspaces) detached=\(catalog.detached) missing=\(catalog.missing)"
                } catch {
                    debugResult = "failed: \(error)"
                }
            }
            return "started"
        case "update-local": // zip|signature file|version: installs it as an update would, and restarts
            guard fields.count == 3, let install = debugInstallUpdate else { return "bad arguments" }
            return install(URL(fileURLWithPath: fields[0]), URL(fileURLWithPath: fields[1]), fields[2])
        case "quit": // as ⌘Q
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return "ok"
        case "close-window": // as the red button
            DispatchQueue.main.async { self.debugWindow?()?.performClose(nil) }
            return "ok"
        case "keywin": // keyCode|characters (\r and \e unescaped)[|modifier flags raw value]: a key press, as if typed
            let characters = fields.count > 1
                ? fields[1].replacingOccurrences(of: "\\r", with: "\r").replacingOccurrences(of: "\\e", with: "\u{1b}") : ""
            guard fields.count >= 2, let code = UInt16(fields[0]), let window = debugWindow?(),
                  let event = NSEvent.keyEvent(
                      with: .keyDown, location: .zero,
                      modifierFlags: NSEvent.ModifierFlags(rawValue: fields.count > 2 ? UInt(fields[2]) ?? 0 : 0),
                      timestamp: ProcessInfo.processInfo.systemUptime,
                      windowNumber: window.windowNumber, context: nil, characters: characters,
                      charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)
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
            // What a click there lands on: the terminal that was meant, or something over it.
            let landed = window.contentView?.superview?.hitTest(point)
            let target = landed === terminal ? "terminal" : landed.map { String(describing: type(of: $0)) } ?? "nothing"
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let event = NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)
                else { return "no event" }
                NSApp.sendEvent(event)
            }
            return "ok " + target
        case "press": // column|row[|right]: a press and release handed to the terminal itself, past
            // the background window's "first click only brings it forward"
            let numbers = fields.compactMap { Int($0) }
            guard numbers.count >= 2, let window = debugWindow?(), let terminal = debugTerminalView?() else { return "bad arguments" }
            let point = terminal.windowPoint(column: numbers[0], row: numbers[1])
            let right = fields.count > 2 && fields[2] == "right"
            for type in right ? [NSEvent.EventType.rightMouseDown, .rightMouseUp] : [.leftMouseDown, .leftMouseUp] {
                guard let event = NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
                else { return "no event" }
                switch type {
                case .leftMouseDown: terminal.mouseDown(with: event)
                case .leftMouseUp: terminal.mouseUp(with: event)
                case .rightMouseDown: terminal.rightMouseDown(with: event)
                default: terminal.rightMouseUp(with: event)
                }
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
        case "link": // column|row: the program's link at that viewport cell, and the line there
            let cell = fields.compactMap { Int($0) }
            guard cell.count == 2, let session = activeTab?.session else { return "bad arguments" }
            return (session.hyperlink(at: (cell[0], cell[1])) ?? "-") + " | " + (session.line(at: (cell[0], cell[1]))?.text ?? "-")
        case "links": // links a click would have opened
            return DebugLog.links.joined(separator: " ")
        case "paste": // text (\n unescaped) put on the debug pasteboard, then Edit > Paste
            TerminalView.pasteboard.clearContents()
            TerminalView.pasteboard.setString(argument.replacingOccurrences(of: "\\n", with: "\n"), forType: .string)
            // To what holds the keyboard: a window in the background has no key window to route by.
            guard let responder = debugWindow?()?.firstResponder else { return "no responder" }
            // A dialog may hold the keyboard (multi-line paste asks first);
            // sent straight to something without paste:, the action throws.
            guard responder.responds(to: #selector(NSText.paste(_:))) else { return "no paste in \(type(of: responder))" }
            NSApp.sendAction(#selector(NSText.paste(_:)), to: responder, from: nil)
            return "ok"
        case "trace-close": // closes the dialog; read the card's opacity over time with `trace`
            DebugLog.trace = "pending"
            debugTraceDialogClose? { DebugLog.trace = $0 }
            return "ok"
        case "trace":
            return DebugLog.trace
        case "pointer": // down|drag|up|right, x|y from the window's top-left[, modifier flags[, click count[, menu item to choose, or - to only look]]]
            guard fields.count >= 3, let x = Double(fields[1]), let y = Double(fields[2]), let window = debugWindow?(),
                  let frame = window.contentView?.superview else { return "bad arguments" }
            let types: [String: NSEvent.EventType] = ["down": .leftMouseDown, "drag": .leftMouseDragged, "up": .leftMouseUp, "right": .rightMouseDown]
            guard let type = types[fields[0]],
                  let event = NSEvent.mouseEvent(
                      with: type, location: NSPoint(x: x, y: frame.bounds.height - y),
                      modifierFlags: NSEvent.ModifierFlags(rawValue: fields.count > 3 ? UInt(fields[3]) ?? 0 : 0),
                      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                      eventNumber: 0, clickCount: fields.count > 4 ? Int(fields[4]) ?? 1 : 1, pressure: 1)
            else { return "bad arguments" }
            // A system menu a press opens, given a sixth field. Plum's own
            // menus (right-clicks too) open from the event queue like a click.
            guard fields.count > 5 else {
                // Into the event queue, where a real press arrives: a control
                // tracking a press takes the next events from there.
                NSApp.postEvent(event, atStart: false)
                return "ok"
            }
            // A context menu tracks the mouse until it closes. Note what it
            // offers (`menu` reads it back), leave it up a moment, then close it.
            DebugLog.menu = "pending"
            DebugLog.menuObserver = NotificationCenter.default.addObserver(
                forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
            ) { note in
                MainActor.assumeIsolated {
                    if let observer = DebugLog.menuObserver { NotificationCenter.default.removeObserver(observer) }
                    DebugLog.menuObserver = nil
                    guard let menu = note.object as? NSMenu else { return }
                    DebugLog.menu = menu.items.map { item in
                        item.isSeparatorItem ? "—" : item.title + (item.isEnabled ? "" : "(off)") + (item.hasSubmenu ? "▸" : "")
                    }.joined(separator: " | ") + " [" + menu.effectiveAppearance.name.rawValue + "]"
                    let choice = fields.count > 5 && fields[5] != "-" ? menu.items.firstIndex { $0.title == fields[5] } : nil
                    let close = Timer(timeInterval: 1.2, repeats: false) { _ in
                        menu.cancelTracking()
                        if let choice { menu.performActionForItem(at: choice) }
                    }
                    RunLoop.main.add(close, forMode: .common)
                }
            }
            DispatchQueue.main.async { NSApp.sendEvent(event) }
            return "ok"
        case "menu":
            return DebugLog.menu
        case "dropdown": // the open dropdown (choices, the one highlighted, its window); or a key code to press in it
            guard let panel = DropdownPanel.current else { return "none" }
            if let code = UInt16(argument) {
                guard let event = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: panel.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                    isARepeat: false, keyCode: code) else { return "bad arguments" }
                panel.keyDown(with: event)
                return "ok"
            }
            return json(["items": panel.list.items.map(\.id), "highlighted": panel.list.highlighted ?? "", "window": panel.windowNumber,
                         "key": panel.isKeyWindow])
        case "hitches": // start | stop: main run loop passes longer than a 120Hz frame while running
            return argument == "start" ? HitchMeter.start() : HitchMeter.stop()
        case "menus": // the menu bar's titles, to check translations
            return (NSApp.mainMenu?.items ?? []).compactMap { $0.submenu }.map { menu in
                menu.title + ": " + menu.items.filter { !$0.isSeparatorItem }.map(\.title).joined(separator: ", ")
            }.joined(separator: " | ")
        case "windows": // window numbers, for screencapture -l
            return NSApp.windows.filter(\.isVisible).map { "\($0.windowNumber) \(type(of: $0)) \(NSStringFromRect($0.frame))" }.joined(separator: "; ")
        case "notifications":
            return "badge=\(NSApp.dockTile.badgeLabel ?? "none"); " + (debugNotificationStatus?() ?? "unavailable")
        case "copied": // what programs wrote to the clipboard (OSC 52)
            return DebugLog.copied.joined(separator: "\n")
        case "prompt": // -1 or 1: jump between commands, as ⌘↑ / ⌘↓
            guard let delta = Int(argument), let terminal = debugTerminalView?() else { return "bad arguments" }
            terminal.scrollToPrompt(delta)
            return "ok"
        case "viewport": // the first row on screen, from the top of the scrollback
            guard let session = activeTab?.session else { return "no tab" }
            return session.withTerminal { terminal in
                var bar = GhosttyTerminalScrollbar()
                ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &bar)
                return "\(bar.offset)/\(bar.total)"
            }
        case "diff": // opens the diff view for the selected workspace
            guard let workspace = selectedWorkspace else { return "none" }
            sheet = .diff(workspace)
            return "ok"
        case "accent": // plum, blue…: as if chosen in Settings
            guard let accent = AccentChoice(rawValue: argument) else { return "bad arguments" }
            var settings = state.settings
            settings.accent = accent
            update(settings)
            return "ok"
        case "split": // right or down: splits the pane with the keyboard
            guard splitPane(argument == "down" ? .vertical : .horizontal) != nil else { return "no tab" }
            return "ok"
        case "close-own": // closes the selected workspace's own window
            guard let selection, let window = NSApp.windows.first(where: { $0.frameAutosaveName == "PlumWorkspace-\(selection.uuidString)" })
            else { return "none" }
            window.performClose(nil)
            return "ok"
        case "window": // opens the selected workspace in a window of its own
            guard let selection else { return "none" }
            openInOwnWindow(selection)
            return "ok"
        case "pane": // dx|dy: the keyboard to the pane that way
            let steps = fields.compactMap { Int($0) }
            guard steps.count == 2 else { return "bad arguments" }
            focusPane(dx: steps[0], dy: steps[1])
            return "ok"
        case "panes": // the open tab's panes, the one with the keyboard marked *
            guard let active = activeTab?.id else { return "none" }
            return layout(of: head(of: active)).panes.map { ($0 == active ? "*" : "") + (terminal($0).map(TabTitle.label) ?? "?") }
                .joined(separator: " | ")
        case "modes": // what the program in the active tab asked for
            guard let session = activeTab?.session else { return "no tab" }
            return "mouse=\(session.wantsMouse) alt=\(session.isAlternateScreen) kitty=\(session.usesKittyKeyboard)"
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
            "notice": notice ?? "",
            "update": availableUpdate?.tag ?? "",
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
                    "title": tab.title, "status": (statuses[tab.id] ?? .idle).rawValue,
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
    static var copied: [String] = []
    static var trace = ""
    static var menu = ""
    static var menuObserver: NSObjectProtocol?
}
