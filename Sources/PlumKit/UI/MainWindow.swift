import AppKit
import Combine
import SwiftUI

struct TabBarView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 2) {
            if let selection = model.selection, let workspace = model.workspace(selection), !workspace.isArchived {
                let tabs = model.tabs[selection] ?? []
                ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                    TabButton(
                        title: title(for: tab, index: index),
                        status: model.statuses[tab.id] ?? .idle,
                        isActive: model.activeTabs[selection] == tab.id,
                        select: { model.activateTab(tab.id) },
                        close: { model.closeTab(tab.id) })
                }
                Button {
                    model.openTab(in: selection)
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 24, height: 22)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("새 탭")
                .help("새 탭 (⌘T)")
                .disabled(!model.folderExists(workspace))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .frame(height: 30)
        .background(.bar)
    }

    private func title(for tab: TerminalTab, index: Int) -> String {
        let reported = model.titles[tab.id] ?? ""
        return reported.isEmpty ? "터미널 \(index + 1)" : reported
    }
}

private struct TabButton: View {
    let title: String
    let status: AgentStatus
    let isActive: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            StatusDot(status: status)
            Text(title)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 180)
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.borderless)
            .opacity(hovering || isActive ? 0.8 : 0)
            .accessibilityLabel("\(title) 탭 닫기")
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(RoundedRectangle(cornerRadius: 5).fill(isActive ? Color.primary.opacity(0.12) : hovering ? Color.primary.opacity(0.06) : .clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
    }
}

/// Shown instead of a terminal when the selection has none.
struct EmptyStateView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 12) {
            if model.state.projects.isEmpty {
                Text("프로젝트를 추가해 시작하세요")
                    .font(.title3)
                Text("git 저장소 폴더를 등록하면 워크스페이스마다 워크트리와 터미널이 만들어집니다.")
                    .foregroundStyle(.secondary)
                Button("프로젝트 추가…") { AppActions.addProject(model) }
                    .keyboardShortcut(.defaultAction)
            } else if let workspace = model.selectedWorkspace {
                if model.busy.contains(workspace.id) {
                    ProgressView()
                } else if workspace.isArchived {
                    Text("‘\(workspace.name)’은 아카이브되어 있습니다")
                        .font(.title3)
                    Text("브랜치 \(workspace.branch)는 남아 있습니다. 복원하면 워크트리를 다시 만듭니다.")
                        .foregroundStyle(.secondary)
                    Button("복원") { AppActions.restore(model, workspace) }
                } else if !model.folderExists(workspace) {
                    Text("폴더가 없습니다")
                        .font(.title3)
                    Text(workspace.path)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Text("앱 밖에서 지워진 것 같습니다. 사이드바에서 아카이브하거나 삭제해 정리할 수 있습니다.")
                        .foregroundStyle(.secondary)
                } else {
                    Button("터미널 열기") { model.openTab(in: workspace.id) }
                }
            } else {
                Text("워크스페이스를 선택하세요")
                    .foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.center)
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0x16 / 255, green: 0x18 / 255, blue: 0x1d / 255))
        .environment(\.colorScheme, .dark)
    }
}

/// The right-hand pane: tab bar on top, the active terminal below.
/// The terminal view is plain AppKit, kept out of SwiftUI so that a change in
/// the SwiftUI tree can never tear down what is on screen.
@MainActor
final class TerminalAreaController: NSViewController {
    private let model: AppModel
    private let container = NSView()
    private var emptyState: NSView!
    let terminal: TerminalView
    private var subscription: AnyCancellable?
    private var font: (String, Double)

    init(model: AppModel) {
        self.model = model
        font = (model.state.settings.fontName, model.state.settings.fontSize)
        terminal = TerminalView(fontName: font.0, fontSize: font.1)
        super.init(nibName: nil, bundle: nil)
        terminal.onUserInput = { [weak model] session in
            MainActor.assumeIsolated { model?.userTyped(in: session.id) }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let root = NSView()
        let tabBar = NSHostingView(rootView: TabBarView(model: model))
        emptyState = NSHostingView(rootView: EmptyStateView(model: model))
        for view in [tabBar, container] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: 30),
            container.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            container.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        for view in [terminal, emptyState!] {
            view.frame = container.bounds
            view.autoresizingMask = [.width, .height]
            container.addSubview(view)
        }
        terminal.isHidden = true
        view = root

        // objectWillChange fires before the change lands, so look afterwards.
        subscription = model.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.sync() }
        sync()
    }

    private func sync() {
        let settings = model.state.settings
        if font != (settings.fontName, settings.fontSize) {
            font = (settings.fontName, settings.fontSize)
            terminal.setFont(name: font.0, size: font.1)
        }
        view.window?.title = model.selectedWorkspace.map { workspace in
            "\(workspace.name) — \(model.project(workspace.projectID)?.name ?? "")"
        } ?? "Plum"

        let active = model.activeTab?.session
        guard active !== terminal.session || terminal.isHidden != (active == nil) else { return }
        terminal.session = active
        terminal.isHidden = active == nil
        emptyState.isHidden = active != nil
        // Don't steal focus from a text field in an open sheet.
        if active != nil, view.window?.attachedSheet == nil { view.window?.makeFirstResponder(terminal) }
    }

    func focusTerminal() {
        if !terminal.isHidden { view.window?.makeFirstResponder(terminal) }
    }
}

@MainActor
public final class MainWindowController: NSWindowController {
    private let terminalArea: TerminalAreaController
    private let split = NSSplitViewController()

    public init(model: AppModel) {
        terminalArea = TerminalAreaController(model: model)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Plum"
        window.minSize = NSSize(width: 640, height: 360)
        window.tabbingMode = .disallowed
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        super.init(window: window)

        let sidebar = NSSplitViewItem(sidebarWithViewController: NSHostingController(rootView: SidebarView(model: model)))
        sidebar.minimumThickness = 190
        sidebar.maximumThickness = 420
        sidebar.canCollapse = true
        split.addSplitViewItem(sidebar)
        split.addSplitViewItem(NSSplitViewItem(viewController: terminalArea))
        window.contentViewController = split
        window.setContentSize(NSSize(width: 1180, height: 760))
        window.center()
        window.setFrameAutosaveName("PlumMainWindow")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    public func toggleSidebar() { split.toggleSidebar(nil) }
    public func focusTerminal() { terminalArea.focusTerminal() }
    var terminalView: TerminalView { terminalArea.terminal }
}
