import AppKit
import Combine
import UserNotifications

/// Starts Plum. Never returns.
@MainActor
public func runApp() {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
    withExtendedLifetime(delegate) {}
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, UNUserNotificationCenterDelegate {
    private let model = AppModel()
    private var windowController: MainWindowController!
    private let debug = ProcessInfo.processInfo.environment["PLUM_DEBUG"] == "1"
    /// Notifications need a real app bundle; a bare `swift run` binary has none.
    private var notifications: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : .current()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = buildMenu()
        // PLUM_DEBUG_OCCLUSION keeps the real "draw only when visible" rule
        // in a scripted run, to check that rule itself.
        TerminalView.drawsWhileOccluded = debug && ProcessInfo.processInfo.environment["PLUM_DEBUG_OCCLUSION"] != "1"
        windowController = MainWindowController(model: model)
        windowController.window?.delegate = self
        model.debugWindowNumber = { [weak self] in self?.windowController.window?.windowNumber ?? 0 }
        model.debugTerminalView = { [weak self] in self?.windowController.terminalView }
        model.debugWindow = { [weak self] in self?.windowController.window }
        model.debugNotificationStatus = { [weak self] in self?.notificationLog.joined(separator: "; ") ?? "" }
        model.notify = { [weak self] title, body, tab in self?.post(title: title, body: body, tab: tab) }
        notifications?.delegate = self
        // The Dock badge needs no permission, unlike notifications.
        badgeSubscription = model.$statuses.receive(on: DispatchQueue.main).sink { statuses in
            let pending = statuses.values.filter { $0 == .waiting || $0 == .done }.count
            NSApp.dockTile.badgeLabel = pending == 0 ? nil : "\(pending)"
        }
        model.start(debug: debug)
        if debug {
            // Scripted runs must not grab the keyboard from whoever is working.
            windowController.window?.orderFrontRegardless()
        } else {
            windowController.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        windowController.focusTerminal()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        model.tabBecameVisible()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func windowShouldClose(_ sender: NSWindow) -> Bool { confirmQuit() }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // The window asked already if it is the one closing.
        sender.windows.contains { $0.isVisible && $0 === windowController.window } && !confirmQuit() ? .terminateCancel : .terminateNow
    }

    /// Quitting ends every shell and agent, so say so first.
    private func confirmQuit() -> Bool {
        let running = model.tabs.values.reduce(0) { $0 + $1.count }
        guard running > 0, !debug, !quitConfirmed else { return true }
        let alert = NSAlert()
        alert.messageText = "Plum을 종료할까요?"
        alert.informativeText = "열려 있는 터미널 \(running)개와 그 안에서 실행 중인 프로그램이 모두 종료됩니다."
        alert.addButton(withTitle: "종료")
        alert.addButton(withTitle: "취소")
        quitConfirmed = alert.runModal() == .alertFirstButtonReturn
        return quitConfirmed
    }

    private var quitConfirmed = false

    // MARK: Notifications

    /// What happened to each notification, for scripted checks.
    private var notificationLog: [String] = []
    private var badgeSubscription: AnyCancellable?

    private func post(title: String, body: String, tab: UUID) {
        // Always works, even where notifications are refused (macOS turns
        // them down for builds without a Developer ID signature).
        NSApp.requestUserAttention(.informationalRequest)
        guard let notifications else {
            notificationLog.append("no bundle")
            return
        }
        notifications.requestAuthorization(options: [.alert, .sound]) { granted, error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.notificationLog.append(granted ? "posted: \(title)" : "not allowed\(error.map { " (\($0.localizedDescription))" } ?? "")")
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

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let tab = (response.notification.request.content.userInfo["tab"] as? String).flatMap(UUID.init)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if let tab {
                    NSApp.activate(ignoringOtherApps: true)
                    self.model.reveal(tab: tab)
                }
            }
            completionHandler()
        }
    }

    // MARK: Menu

    private func buildMenu() -> NSMenu {
        let main = NSMenu()
        func menu(_ title: String, _ build: (NSMenu) -> Void) {
            let item = NSMenuItem()
            let submenu = NSMenu(title: title)
            build(submenu)
            item.submenu = submenu
            main.addItem(item)
        }
        func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command, mine: Bool = true, tag: Int = 0) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = mods
            item.tag = tag
            if mine { item.target = self } // otherwise the responder chain decides
            menu.addItem(item)
        }

        menu("Plum") { m in
            add(m, "Plum에 관하여", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), mine: false)
            m.addItem(.separator())
            add(m, "설정…", #selector(showSettings), ",")
            m.addItem(.separator())
            add(m, "Plum 가리기", #selector(NSApplication.hide(_:)), "h", mine: false)
            add(m, "Plum 종료", #selector(NSApplication.terminate(_:)), "q", mine: false)
        }
        menu("파일") { m in
            add(m, "새 워크스페이스…", #selector(newWorkspace), "n")
            add(m, "새 탭", #selector(newTab), "t")
            add(m, "프로젝트 추가…", #selector(addProject), "o")
            m.addItem(.separator())
            add(m, "탭 닫기", #selector(closeTab), "w")
        }
        menu("편집") { m in
            add(m, "실행 취소", Selector(("undo:")), "z", mine: false)
            add(m, "실행 복귀", Selector(("redo:")), "z", [.command, .shift], mine: false)
            m.addItem(.separator())
            add(m, "오려두기", #selector(NSText.cut(_:)), "x", mine: false)
            add(m, "복사", #selector(NSText.copy(_:)), "c", mine: false)
            add(m, "붙여넣기", #selector(NSText.paste(_:)), "v", mine: false)
            add(m, "전체 선택", #selector(NSText.selectAll(_:)), "a", mine: false)
        }
        menu("보기") { m in
            add(m, "글자 크게", #selector(biggerFont), "+")
            add(m, "글자 작게", #selector(smallerFont), "-")
            add(m, "기본 크기", #selector(resetFont), "0")
            m.addItem(.separator())
            add(m, "사이드바 보기/가리기", #selector(toggleSidebar), "s", [.command, .control])
        }
        menu("탭") { m in
            add(m, "다음 탭", #selector(nextTab), "]", [.command, .shift])
            add(m, "이전 탭", #selector(previousTab), "[", [.command, .shift])
            m.addItem(.separator())
            for number in 1...9 { add(m, "탭 \(number)", #selector(selectTab(_:)), "\(number)", tag: number - 1) }
        }
        menu("윈도우") { m in
            add(m, "최소화", #selector(NSWindow.performMiniaturize(_:)), "m", mine: false)
            add(m, "확대/축소", #selector(NSWindow.performZoom(_:)), mine: false)
            NSApp.windowsMenu = m
        }
        return main
    }

    private var currentProject: Project? {
        model.selectedWorkspace.flatMap { model.project($0.projectID) } ?? model.state.projects.first
    }

    @objc private func showSettings() { model.sheet = .settings }
    @objc private func addProject() { AppActions.addProject(model) }
    @objc private func toggleSidebar() { windowController.toggleSidebar() }
    @objc private func nextTab() { model.cycleTab(1) }
    @objc private func previousTab() { model.cycleTab(-1) }
    @objc private func selectTab(_ sender: NSMenuItem) { model.activateTab(at: sender.tag) }
    @objc private func biggerFont() { changeFontSize(by: 1) }
    @objc private func smallerFont() { changeFontSize(by: -1) }

    @objc private func newWorkspace() {
        guard let project = currentProject else { return addProject() }
        model.sheet = .newWorkspace(project)
    }

    @objc private func newTab() {
        if let selection = model.selection { model.openTab(in: selection) }
    }

    @objc private func closeTab() {
        if let tab = model.activeTab { model.closeTab(tab.id) }
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
