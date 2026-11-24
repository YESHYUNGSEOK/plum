import AppKit
import Observation
import UserNotifications

/// Starts Plum. Never returns.
@MainActor
public func runApp() {
    // A write to a pipe or socket whose reader is gone fails with EPIPE, which
    // every write here handles, instead of ending the app without a trace
    // (a script that closed its connection before reading the answer to a
    // debug command did that). The terminal host does the same.
    signal(SIGPIPE, SIG_IGN)
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
    withExtendedLifetime(delegate) {}
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation, UNUserNotificationCenterDelegate {
    private let model = AppModel()
    /// Keeps macOS from putting Plum to sleep (App Nap) while its window is
    /// covered: the terminals behind it keep running agents and builds, and
    /// napped, their output was read and parsed 2-6x more slowly (scrolling
    /// in a region 16-22 MB/s instead of 108-113). Idle, Plum does almost
    /// nothing anyway; the Mac may still sleep.
    private var awake: NSObjectProtocol?
    private var windowController: MainWindowController!
    private let debug = ProcessInfo.processInfo.environment["PLUM_DEBUG"] == "1"
    /// Notifications need a real app bundle; a bare `swift run` binary has none.
    private var notifications: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : .current()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Read off the main thread while the window is set up (2 ms), not at the first frame.
        DispatchQueue.global(qos: .userInitiated).async { _ = CellLayout.current }
        awake = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep, reason: "Terminals keep running while the window is covered")
        NSApp.mainMenu = buildMenu()
        // Plum is dark, whatever the system is.
        NSApp.appearance = NSAppearance(named: .darkAqua)
        applyAccent()
        model.onLookChanged = { [weak self] in self?.applyAccent() }
        // PLUM_DEBUG_OCCLUSION keeps the real "draw only when visible" rule
        // in a scripted run, to check that rule itself.
        TerminalView.drawsWhileOccluded = debug && ProcessInfo.processInfo.environment["PLUM_DEBUG_OCCLUSION"] != "1"
        if debug {
            // Scripted checks click links and paste without opening a browser
            // or touching the user's clipboard.
            TerminalView.openLink = { DebugLog.links.append($0.absoluteString) }
            TerminalView.pasteboard = NSPasteboard(name: NSPasteboard.Name("dev.plum.debug"))
            TerminalSession.copyToClipboard = { DebugLog.copied.append($0) }
        }
        windowController = MainWindowController(model: model)
        windowController.window?.delegate = self
        // Once a day at most, at launch and while Plum stays open (for days,
        // often); silent unless there is something newer, then a toast.
        if !debug {
            checkForUpdatesDaily()
            Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkForUpdatesDaily() }
            }
        }
        model.debugWindowNumber = { [weak self] in self?.windowController.window?.windowNumber ?? 0 }
        model.debugTerminalView = { [weak self] in self?.currentArea.terminal }
        model.onShowWindow = { [weak self] id in self?.showWorkspaceWindow(id) }
        for id in model.ownWindows { showWorkspaceWindow(id, front: false) }
        model.debugWindow = { [weak self] in self?.windowController.window }
        model.debugTraceDialogClose = { [weak self] done in self?.windowController.traceDialogClose(done) }
        model.debugNotificationStatus = { [weak self] in self?.notificationLog.joined(separator: "; ") ?? "" }
        model.debugInstallUpdate = { zip, signature, version in
            do {
                let app = try Updates.install(try Data(contentsOf: zip), signature: try Data(contentsOf: signature), version: version)
                DispatchQueue.main.async { AppActions.relaunch(app) }
                return "installed " + app.path
            } catch {
                return "failed: " + error.localizedDescription
            }
        }
        model.notify = { [weak self] title, body, tab in self?.post(title: title, body: body, tab: tab) }
        notifications?.delegate = self
        // The Dock badge needs no permission, unlike notifications.
        updateBadge()
        model.start(debug: debug)
        // Someone coming from Orca: offered once what they had there.
        // (Until it has actually asked: Orca may be off on that launch.)
        if !debug, model.state.projects.isEmpty, !UserDefaults.standard.bool(forKey: AppActions.orcaOfferedKey), OrcaImport.cli() != nil {
            Task { await AppActions.importFromOrca(model, quietly: true) }
        }
        if debug {
            // Scripted runs must not grab the keyboard from whoever is
            // working, nor cover what they are looking at.
            windowController.window?.orderBack(nil)
        } else {
            windowController.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        windowController.focusTerminal()
    }

    private func checkForUpdatesDaily() {
        guard Date().timeIntervalSince1970 - UserDefaults.standard.double(forKey: "lastUpdateCheck") > 86400 else { return }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastUpdateCheck")
        Task { await AppActions.checkForUpdates(model, quietly: true) }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        model.tabBecameVisible()
    }

    // The red button only hides the window: Plum stays in the Dock, keeps
    // notifying, and its Dock icon brings the window back. ⌘Q quits.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    private func showMainWindow() {
        if windowController.window?.isVisible != true { windowController.showWindow(nil) }
    }

    /// The terminal host keeps every terminal; it gets their screens to keep too.
    func applicationWillTerminate(_ notification: Notification) {
        model.parkTerminals()
        AppActions.reopenIfUpdated()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil) // hidden, not closed: nothing ends
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard needsQuitConfirmation, !systemIsEndingSession else { return .terminateNow }
        // Ask in the window, then quit again. Waiting for the answer here
        // (.terminateLater) would stop the main queue the dialog runs on.
        askToQuit { confirmed in if confirmed { NSApp.terminate(nil) } }
        return .terminateCancel
    }

    /// Logging out or shutting down: macOS has asked already.
    private var systemIsEndingSession: Bool {
        guard let reason = NSAppleEventManager.shared().currentAppleEvent?
            .attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason))?.enumCodeValue else { return false }
        return [kAELogOut, kAEReallyLogOut, kAEShowRestartDialog, kAEShowShutdownDialog, kAERestart, kAEShutDown]
            .map { OSType($0) }.contains(reason)
    }

    /// Quitting leaves the terminal host's tabs running, to come back to.
    /// Only tabs it couldn't take (the host didn't start) end with the app,
    /// so only then is there something to ask about.
    private var needsQuitConfirmation: Bool {
        (!debug || ProcessInfo.processInfo.environment["PLUM_DEBUG_ASK_QUIT"] == "1")
            && !quitConfirmed && model.tabsEndingOnQuit > 0
    }

    private var quitConfirmed = false

    private func askToQuit(_ answer: @escaping (Bool) -> Void) {
        // The question is asked in the window, so the window must be seen.
        if let window = windowController.window {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        }
        // A scripted check must not take the screen from whoever is working.
        if !debug { NSApp.activate(ignoringOtherApps: true) }
        let running = model.tabsEndingOnQuit
        let programs = model.tabs.keys.flatMap { id in
            model.runningPrograms(in: id).map { "\(model.workspace(id)?.name ?? "") · \($0)" }
        }.sorted()
        let confirmation = Confirmation(
            title: String(localized: "Plum을 종료할까요?"),
            summary: String(localized: "열려 있는 터미널 \(running)개와 그 안에서 실행 중인 프로그램이 모두 종료됩니다."),
            sections: programs.isEmpty ? [] : [.init(title: String(localized: "실행 중인 프로그램"), lines: programs)],
            action: String(localized: "종료"), destructive: false)
        confirmation.onAnswer = { [weak self] confirmed in
            if confirmed { self?.quitConfirmed = true }
            answer(confirmed)
        }
        model.sheet = .confirm(confirmation)
    }

    // MARK: Notifications

    /// What happened to each notification, for scripted checks.
    private var notificationLog: [String] = []
    private func updateBadge() {
        withObservationTracking {
            let pending = model.statuses.values.filter { $0 == .waiting || $0 == .done }.count
            NSApp.dockTile.badgeLabel = pending == 0 ? nil : "\(pending)"
        } onChange: {
            // Called before the change lands: look again once it has.
            DispatchQueue.main.async { MainActor.assumeIsolated { self.updateBadge() } }
        }
    }

    /// The first time, macOS asks whether Plum may notify. Nothing else is
    /// tried when it may not: usernoted refuses the older API
    /// (NSUserNotification) to an app that has used this one ("You can't
    /// mix modern clients with legacy clients", macOS 26). A copy run from a
    /// temporary folder isn't asked about at all, only refused.
    private func post(title: String, body: String, tab: UUID) {
        // Always works, whatever the answer was.
        NSApp.requestUserAttention(.informationalRequest)
        guard let notifications else {
            notificationLog.append("no bundle")
            return
        }
        notifications.requestAuthorization(options: [.alert, .sound]) { granted, error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.notificationLog.append(granted ? "posted: \(title)" : "not allowed\(error.map { " (\($0.localizedDescription))" } ?? "")")
                    if !granted { self.sayNotificationsAreOff() }
                }
            }
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            content.userInfo = ["tab": tab.uuidString]
            // One notification per tab: a newer state replaces the older one.
            notifications.add(UNNotificationRequest(identifier: tab.uuidString, content: content, trigger: nil))
        }
    }

    /// Said once, ever: turned off in System Settings (a "Don't Allow" long
    /// forgotten), nothing else tells why no notification comes.
    private func sayNotificationsAreOff() {
        guard !UserDefaults.standard.bool(forKey: "saidNotificationsAreOff") else { return }
        notifications?.getNotificationSettings { settings in
            guard settings.authorizationStatus == .denied else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    UserDefaults.standard.set(true, forKey: "saidNotificationsAreOff")
                    self.model.notice = String(localized: "macOS 알림이 꺼져 있습니다. 시스템 설정 → 알림 → Plum에서 켜면 작업이 끝났을 때 알려 드립니다.")
                }
            }
        }
    }

    // Shown even while Plum is in front: they are about tabs out of sight.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let tab = (response.notification.request.content.userInfo["tab"] as? String).flatMap(UUID.init)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if let tab {
                    NSApp.activate(ignoringOtherApps: true)
                    self.showMainWindow()
                    self.model.reveal(tab: tab)
                }
            }
            completionHandler()
        }
    }

    // MARK: Menu

    private func buildMenu() -> NSMenu {
        let main = NSMenu()
        func menu(_ title: String.LocalizationValue, _ build: (NSMenu) -> Void) {
            let item = NSMenuItem()
            let submenu = NSMenu(title: String(localized: title))
            build(submenu)
            item.submenu = submenu
            main.addItem(item)
        }
        func arrow(_ key: Int) -> String { String(Character(UnicodeScalar(key)!)) }
        /// A second key for the item just above: hidden, but it still answers.
        func alternate(_ menu: NSMenu, _ action: Selector, _ key: String, _ mods: NSEvent.ModifierFlags = .command) {
            let item = NSMenuItem(title: menu.items.last?.title ?? "", action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = mods
            item.target = self
            item.isHidden = true
            item.allowsKeyEquivalentWhenHidden = true
            menu.addItem(item)
        }
        func add(_ menu: NSMenu, _ title: String.LocalizationValue, _ action: Selector, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command, mine: Bool = true, tag: Int = 0) {
            let item = NSMenuItem(title: String(localized: title), action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = mods
            item.tag = tag
            if mine { item.target = self } // otherwise the responder chain decides
            menu.addItem(item)
        }

        menu("Plum") { m in
            add(m, "Plum에 관하여", #selector(showAbout))
            add(m, "업데이트 확인…", #selector(checkForUpdates))
            m.addItem(.separator())
            add(m, "설정…", #selector(showSettings), ",")
            m.addItem(.separator())
            add(m, "Plum 가리기", #selector(NSApplication.hide(_:)), "h", mine: false)
            add(m, "기타 가리기", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option], mine: false)
            add(m, "모두 보기", #selector(NSApplication.unhideAllApplications(_:)), mine: false)
            add(m, "Plum 종료", #selector(NSApplication.terminate(_:)), "q", mine: false)
        }
        menu("파일") { m in
            add(m, "새 워크스페이스…", #selector(newWorkspace), "n")
            add(m, "새 탭", #selector(newTab), "t")
            add(m, "새 Claude 탭", #selector(newClaudeTab))
            add(m, "새 Codex 탭", #selector(newCodexTab))
            add(m, "프로젝트 추가…", #selector(addProject), "o")
            add(m, "Orca에서 가져오기…", #selector(importFromOrca))
            m.addItem(.separator())
            add(m, "탭 닫기", #selector(closeTab), "w")
            add(m, "닫은 탭 다시 열기", #selector(reopenClosedTab), "t", [.command, .shift])
            m.addItem(.separator())
            add(m, "새 창에서 열기", #selector(openInNewWindow), "n", [.command, .option])
            add(m, "오른쪽으로 나누기", #selector(splitRight), "d")
            add(m, "아래로 나누기", #selector(splitDown), "d", [.command, .shift])
        }
        menu("편집") { m in
            add(m, "실행 취소", Selector(("undo:")), "z", mine: false)
            add(m, "실행 복귀", Selector(("redo:")), "z", [.command, .shift], mine: false)
            m.addItem(.separator())
            add(m, "오려두기", #selector(NSText.cut(_:)), "x", mine: false)
            add(m, "복사", #selector(NSText.copy(_:)), "c", mine: false)
            add(m, "붙여넣기", #selector(NSText.paste(_:)), "v", mine: false)
            add(m, "전체 선택", #selector(NSText.selectAll(_:)), "a", mine: false)
            m.addItem(.separator())
            add(m, "찾기…", #selector(find), "f")
            add(m, "다음 찾기", #selector(findNext), "g")
            add(m, "이전 찾기", #selector(findPrevious), "g", [.command, .shift])
            add(m, "화면 지우기", #selector(clearTerminal), "k")
        }
        menu("보기") { m in
            add(m, "글자 크게", #selector(biggerFont), "+")
            add(m, "글자 작게", #selector(smallerFont), "-")
            add(m, "기본 크기", #selector(resetFont), "0")
            m.addItem(.separator())
            add(m, "전체 화면", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control], mine: false)
            add(m, "변경 보기", #selector(showChanges), "e", [.command, .shift])
            m.addItem(.separator())
            add(m, "이전 명령으로", #selector(previousPrompt), String(UnicodeScalar(NSUpArrowFunctionKey)!))
            add(m, "다음 명령으로", #selector(nextPrompt), String(UnicodeScalar(NSDownArrowFunctionKey)!))
        }
        // Shifted keys are given as the character Shift makes ("}" for ⇧]):
        // a key press reports that character, and "]" plus ⇧ never matches it.
        // Workspace and tab navigation, as in cmux; Orca's keys work too
        // (hidden alternates). Every one of them is a menu item, so the menu
        // is also the list of what the keyboard can do.
        menu("이동") { m in
            add(m, "워크스페이스로 이동…", #selector(switchWorkspace), "p")
            alternate(m, #selector(switchWorkspace), "j")
            m.addItem(.separator())
            add(m, "다음 워크스페이스", #selector(nextWorkspace), "]", [.command, .control])
            alternate(m, #selector(nextWorkspace), arrow(NSDownArrowFunctionKey), [.command, .shift])
            add(m, "이전 워크스페이스", #selector(previousWorkspace), "[", [.command, .control])
            alternate(m, #selector(previousWorkspace), arrow(NSUpArrowFunctionKey), [.command, .shift])
            for number in 1...8 { add(m, "워크스페이스 \(number)", #selector(selectWorkspace(_:)), "\(number)", tag: number - 1) }
            add(m, "마지막 워크스페이스", #selector(selectWorkspace(_:)), "9", tag: 8)
            m.addItem(.separator())
            add(m, "뒤로", #selector(goBack), "[")
            alternate(m, #selector(goBack), arrow(NSLeftArrowFunctionKey), [.command, .option])
            add(m, "앞으로", #selector(goForward), "]")
            alternate(m, #selector(goForward), arrow(NSRightArrowFunctionKey), [.command, .option])
            add(m, "직전 위치", #selector(goToLastPlace))
            add(m, "확인 필요로 이동", #selector(jumpToAttention), "U")
            add(m, "사이드바에서 고르기", #selector(focusSidebar), "e", [.command, .control])
            alternate(m, #selector(focusSidebar), ")")
            m.addItem(.separator())
            add(m, "다음 탭", #selector(nextTab), "}")
            alternate(m, #selector(nextTab), "]", [.command, .option])
            alternate(m, #selector(nextTab), arrow(NSPageDownFunctionKey), [.control])
            add(m, "이전 탭", #selector(previousTab), "{")
            alternate(m, #selector(previousTab), "[", [.command, .option])
            alternate(m, #selector(previousTab), arrow(NSPageUpFunctionKey), [.control])
            add(m, "직전 탭", #selector(recentTab), "\t", [.control])
            for number in 1...8 { add(m, "탭 \(number)", #selector(selectTab(_:)), "\(number)", [.control], tag: number - 1) }
            add(m, "마지막 탭", #selector(selectTab(_:)), "9", [.control], tag: 8)
            m.addItem(.separator())
            add(m, "워크스페이스를 위로", #selector(moveWorkspaceUp), "[", [.command, .control, .option])
            add(m, "워크스페이스를 아래로", #selector(moveWorkspaceDown), "]", [.command, .control, .option])
            let arrow = { (key: Int) in String(UnicodeScalar(UInt32(key))!) }
            add(m, "왼쪽 창으로", #selector(paneLeft), arrow(NSLeftArrowFunctionKey), [.command, .option])
            add(m, "오른쪽 창으로", #selector(paneRight), arrow(NSRightArrowFunctionKey), [.command, .option])
            add(m, "위 창으로", #selector(paneUp), arrow(NSUpArrowFunctionKey), [.command, .option])
            add(m, "아래 창으로", #selector(paneDown), arrow(NSDownArrowFunctionKey), [.command, .option])
            add(m, "탭을 왼쪽으로", #selector(moveTabLeft), "{", [.command, .option])
            add(m, "탭을 오른쪽으로", #selector(moveTabRight), "}", [.command, .option])
        }
        menu("윈도우") { m in
            add(m, "최소화", #selector(NSWindow.performMiniaturize(_:)), "m", mine: false)
            add(m, "확대/축소", #selector(NSWindow.performZoom(_:)), mine: false)
            m.addItem(.separator())
            add(m, "모두 앞으로 가져오기", #selector(NSApplication.arrangeInFront(_:)), mine: false)
            NSApp.windowsMenu = m
        }
        return main
    }

    /// Our commands act on the window behind an open dialog, so they wait for it.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        model.sheet == nil
    }

    private var currentProject: Project? {
        model.selectedWorkspace.flatMap { model.project($0.projectID) } ?? model.state.projects.first
    }

    @objc private func showSettings() { model.sheet = .settings }

    /// The accent from the settings, everywhere. Terminals are drawn by
    /// Plum, not AppKit: their cursor and selection are told the new color.
    private func applyAccent() {
        Theme.accentChoice = model.state.settings.accent
        guard let rgb = Theme.accentNS.usingColorSpace(.sRGB) else { return }
        let cursor = (UInt8(rgb.redComponent * 255), UInt8(rgb.greenComponent * 255), UInt8(rgb.blueComponent * 255))
        let theme = TerminalTheme.dark(cursor: cursor)
        guard theme.cursor != TerminalTheme.current.cursor else { return }
        TerminalTheme.current = theme
        model.applyTerminalTheme(theme)
        windowController?.terminalArea.setTheme(theme)
        for own in workspaceWindows.values { own.area.setTheme(theme) }
    }
    @objc private func checkForUpdates() { Task { await AppActions.checkForUpdates(model, quietly: false) } }
    @objc private func find() { currentArea.showFind() }
    @objc private func findNext() { currentArea.findNext(backward: false) }
    @objc private func findPrevious() { currentArea.findNext(backward: true) }
    @objc private func clearTerminal() { currentArea.terminal?.clear() }
    @objc private func previousPrompt() { currentArea.terminal?.scrollToPrompt(-1) }
    @objc private func nextPrompt() { currentArea.terminal?.scrollToPrompt(1) }
    @objc private func openInNewWindow() { if let id = model.selection { model.openInOwnWindow(id) } }

    // MARK: Windows of their own

    private var workspaceWindows: [UUID: WorkspaceWindowController] = [:]
    /// The main window's own selection, to go back to when it comes forward.
    private var mainSelection: UUID?

    private func showWorkspaceWindow(_ id: UUID, front: Bool = true) {
        let controller = workspaceWindows[id] ?? {
            let controller = WorkspaceWindowController(model: model, workspaceID: id)
            controller.onClose = { [weak self] in self?.workspaceWindows[id] = nil }
            workspaceWindows[id] = controller
            return controller
        }()
        if front {
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
        } else {
            controller.window?.orderFront(nil)
        }
    }

    /// The panel the menus act on: the window in front's, or the one
    /// showing the selected workspace.
    private var currentArea: TerminalAreaController {
        if let key = NSApp.keyWindow, let own = workspaceWindows.values.first(where: { $0.window === key }) { return own.area }
        if let selection = model.selection, let own = workspaceWindows[selection] { return own.area }
        return windowController.terminalArea
    }

    func windowDidResignKey(_ notification: Notification) {
        guard notification.object as? NSWindow === windowController.window,
              let selection = model.selection, !model.ownWindows.contains(selection) else { return }
        mainSelection = selection
    }

    /// Back in the main window: back to what it showed, not a workspace
    /// that lives in another window.
    func windowDidBecomeKey(_ notification: Notification) {
        guard notification.object as? NSWindow === windowController.window, model.sheet == nil,
              let selection = model.selection, model.ownWindows.contains(selection) else { return }
        let fallback = model.workspaceOrder.first { !model.ownWindows.contains($0) }
        model.select(mainSelection.flatMap { model.workspace($0) != nil && !model.ownWindows.contains($0) ? $0 : nil } ?? fallback)
    }
    @objc private func reopenClosedTab() { model.reopenClosedTab() }
    @objc private func splitRight() { model.splitPane(.horizontal) }
    @objc private func splitDown() { model.splitPane(.vertical) }
    @objc private func paneLeft() { model.focusPane(dx: -1, dy: 0) }
    @objc private func paneRight() { model.focusPane(dx: 1, dy: 0) }
    @objc private func paneUp() { model.focusPane(dx: 0, dy: -1) }
    @objc private func paneDown() { model.focusPane(dx: 0, dy: 1) }
    @objc private func showChanges() {
        if let workspace = model.selectedWorkspace, !workspace.isArchived, model.project(workspace.projectID)?.isFolder == false {
            model.sheet = .diff(workspace)
        }
    }
    @objc private func addProject() { AppActions.addProject(model) }
    @objc private func importFromOrca() { Task { await AppActions.importFromOrca(model, quietly: false) } }
    @objc private func nextTab() { model.cycleTab(1) }
    @objc private func previousTab() { model.cycleTab(-1) }
    @objc private func selectTab(_ sender: NSMenuItem) {
        // 1–8 by position, 9 the last, as in cmux.
        if sender.tag < 8 { model.activateTab(at: sender.tag) } else { model.activateLastTab() }
    }

    @objc private func recentTab() { model.activateRecentTab() }
    @objc private func switchWorkspace() { model.sheet = .switcher(SwitcherState()) }
    @objc private func selectWorkspace(_ sender: NSMenuItem) { model.selectWorkspace(at: sender.tag < 8 ? sender.tag : nil) }
    @objc private func goBack() { model.goBack() }
    @objc private func goForward() { model.goForward() }
    @objc private func goToLastPlace() { model.goToLastPlace() }
    @objc private func jumpToAttention() { model.jumpToAttention() }
    @objc private func focusSidebar() { windowController.focusSidebar() }
    @objc private func moveWorkspaceUp() { if let id = model.selection { model.moveWorkspace(id, by: -1) } }
    @objc private func moveWorkspaceDown() { if let id = model.selection { model.moveWorkspace(id, by: 1) } }
    @objc private func moveTabLeft() { if let tab = model.activeTab { model.moveTab(tab.id, by: -1) } }
    @objc private func moveTabRight() { if let tab = model.activeTab { model.moveTab(tab.id, by: 1) } }
    @objc private func biggerFont() { changeFontSize(by: 1) }
    @objc private func smallerFont() { changeFontSize(by: -1) }

    @objc private func newWorkspace() {
        guard let project = currentProject else { return addProject() }
        model.sheet = .newWorkspace(project)
    }

    @objc private func newClaudeTab() {
        if let selection = model.selection { model.openTab(in: selection, program: .claude) }
    }

    @objc private func newCodexTab() {
        if let selection = model.selection { model.openTab(in: selection, program: .codex) }
    }

    @objc private func newTab() {
        if let selection = model.selection { model.openTabBeside(in: selection) }
    }

    @objc private func closeTab() {
        if let tab = model.activeTab { AppActions.closeTab(model, tab.id) }
    }

    @objc private func nextWorkspace() { model.selectWorkspace(offset: 1) }
    @objc private func previousWorkspace() { model.selectWorkspace(offset: -1) }

    @objc private func showAbout() {
        // libghostty-vt is MIT licensed; its notice ships in the bundle.
        let credits = NSMutableAttributedString(
            string: String(localized: "터미널 해석: libghostty-vt (MIT), Ghostty 프로젝트\n라이선스 전문은 앱 안 Resources/LICENSE-ghostty.txt에 있습니다."),
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    @objc private func resetFont() {
        var settings = model.state.settings
        settings.fontSize = AppSettings().fontSize
        model.update(settings)
    }

    private func changeFontSize(by delta: Double) {
        var settings = model.state.settings
        settings.fontSize += delta
        model.update(settings)
    }
}
