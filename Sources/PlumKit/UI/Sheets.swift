import AppKit
import SwiftUI

public enum AppSheet: Identifiable {
    case newWorkspace(Project)
    case projectSettings(Project)
    case settings
    case confirm(Confirmation)
    case switcher(SwitcherState)
    case diff(Workspace)

    public var id: String {
        switch self {
        case let .newWorkspace(project): "new-\(project.id)"
        case let .projectSettings(project): "project-\(project.id)"
        case .settings: "settings"
        case let .confirm(confirmation): "confirm-\(confirmation.id)"
        case .switcher: "switcher"
        case let .diff(workspace): "diff-\(workspace.id)"
        }
    }
}

/// The workspace switcher's query and picked row. The view edits the query;
/// the window controller moves the pick with the arrow keys, which a text
/// field would otherwise keep for itself.
@MainActor
@Observable
public final class SwitcherState {
    var query = ""
    var picked = 0
    /// How many rows match, so the pick stays on one of them.
    var count = 0

    func move(_ offset: Int) {
        guard count > 0 else { return }
        picked = (min(picked, count - 1) + offset + count) % count
    }
}

/// A question that needs an answer before something is lost or ended,
/// with the details listed: changed files, commits, running programs, text.
@MainActor
public final class Confirmation {
    struct Section {
        let title: String
        let lines: [String]
        /// Longest leading word shown apart as a code (a git status, a hash); 0 = none.
        var maxCode = 0
        /// More lines, shown as a count until asked for: what matters less.
        var folded: [String] = []
        var foldedTitle = ""
    }

    let id = UUID()
    let title: String
    let summary: String
    let sections: [Section]
    let note: String?
    let action: String
    /// Destructive answers are drawn red and are never the Return key.
    let destructive: Bool
    /// Told the answer once: true to go ahead.
    var onAnswer: ((Bool) -> Void)?

    init(title: String, summary: String, sections: [Section] = [], note: String? = nil, action: String, destructive: Bool) {
        self.title = title
        self.summary = summary
        self.sections = sections
        self.note = note
        self.action = action
        self.destructive = destructive
    }

    func finish(_ confirmed: Bool) {
        onAnswer?(confirmed)
        onAnswer = nil
    }

    /// The answer a key gives: Return takes the default, which is "cancel"
    /// when the action destroys something; Esc always cancels.
    func answerForKey(_ keyCode: UInt16) -> Bool? {
        switch keyCode {
        case 36, 76: !destructive // Return, keypad Enter
        case 53: false // Esc
        default: nil
        }
    }

    /// "M path" or "a1c9e27 message" → its leading code and the rest. A line
    /// whose first word is longer than `maxCode` (an error message) is all rest.
    nonisolated static func split(_ line: String, maxCode: Int) -> (code: String, rest: String) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard maxCode > 0, let space = trimmed.firstIndex(of: " ") else { return ("", trimmed) }
        let code = String(trimmed[..<space])
        guard code.count <= maxCode else { return ("", trimmed) }
        return (code, trimmed[space...].trimmingCharacters(in: .whitespaces))
    }
}

// MARK: - Dialog card

/// A dialog's content on Plum's dark card. The window controller places it
/// over a dimmed window and animates it with Core Animation.
struct DialogCard: View {
    /// The app's window, for dialogs that grow with it. Not only while it
    /// is the main window: an inactive app has none.
    static var windowSize: CGSize {
        (NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible && $0.canBecomeMain })?.frame.size ?? CGSize(width: 1200, height: 800)
    }

    let model: AppModel
    /// Held, not read from the model, so the card keeps its content while it fades out.
    let sheet: AppSheet?

    var body: some View {
        if let sheet {
            content(sheet)
                .background(Theme.card)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.hairline))
                .accessibilityAddTraits(.isModal)
                .id(model.state.settings.accent)
        }
    }

    @ViewBuilder
    private func content(_ sheet: AppSheet) -> some View {
        let close = { model.sheet = nil }
        switch sheet {
        case let .newWorkspace(project): NewWorkspaceSheet(model: model, project: project, close: close)
        case let .projectSettings(project): ProjectSettingsSheet(model: model, project: project, close: close)
        case .settings: SettingsSheet(model: model, settings: model.state.settings, close: close)
        case let .confirm(confirmation): ConfirmSheet(confirmation: confirmation, close: close)
        case let .switcher(state): WorkspaceSwitcher(model: model, state: state, close: close)
        case let .diff(workspace): DiffSheet(model: model, workspace: workspace, close: close)
        }
    }
}

// MARK: - Workspace switcher

/// Type part of a name, pick with the arrows, Return to go there.
struct WorkspaceSwitcher: View {
    let model: AppModel
    @Bindable var state: SwitcherState
    let close: () -> Void
    @FocusState private var focused: Bool

    struct Entry: Identifiable, Equatable {
        let id: UUID
        let name: String
        let project: String
        let branch: String
    }

    /// With no query: recent workspaces first, the rest in sidebar order,
    /// the current one last. With a query: names starting with it, then names
    /// containing it, then projects or branches containing it, then names
    /// holding its letters in order.
    static func entries(_ model: AppModel, query: String) -> [Entry] {
        let recent = model.recentWorkspaces
        let current = model.selection.map { [$0] } ?? []
        let rest = model.workspaceOrder.filter { !recent.contains($0) && !current.contains($0) }
        let all: [Entry] = (recent + rest + current).compactMap { id in
            guard let workspace = model.workspace(id) else { return nil }
            return Entry(id: id, name: workspace.name, project: model.project(workspace.projectID)?.name ?? "", branch: workspace.branch)
        }
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return all }
        func rank(_ entry: Entry) -> Int? {
            let name = entry.name.lowercased()
            if name.hasPrefix(needle) { return 0 }
            if name.contains(needle) { return 1 }
            if entry.project.lowercased().contains(needle) || entry.branch.lowercased().contains(needle) { return 2 }
            var rest = Substring(name)
            for character in needle {
                guard let found = rest.firstIndex(of: character) else { return nil }
                rest = rest[rest.index(after: found)...]
            }
            return 3
        }
        return all.enumerated()
            .compactMap { offset, entry in rank(entry).map { (rank: $0, offset: offset, entry: entry) } }
            .sorted { ($0.rank, $0.offset) < ($1.rank, $1.offset) }
            .map(\.entry)
    }

    var body: some View {
        let entries = Self.entries(model, query: state.query)
        let picked = entries.isEmpty ? nil : min(state.picked, entries.count - 1)
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .accessibilityHidden(true)
                TextField("워크스페이스로 이동", text: $state.query, prompt: Text("워크스페이스로 이동").foregroundColor(Theme.tertiary))
                    .textFieldStyle(.plain)
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.text)
                    .focused($focused)
            }
            .padding(.horizontal, 18)
            .frame(height: 54)
            Rectangle().fill(Theme.divider).frame(height: 1)

            if entries.isEmpty {
                Text("맞는 워크스페이스가 없습니다")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                                row(entry, picked: index == picked)
                                    .id(entry.id)
                                    .onHover { if $0 { state.picked = index } }
                                    .onTapGesture { go(entry.id) }
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 320)
                    .fixedSize(horizontal: false, vertical: true)
                    .onChange(of: state.picked) {
                        if let picked { withAnimation(Motion.hover) { proxy.scrollTo(entries[picked].id) } }
                    }
                }
            }
            Rectangle().fill(Theme.divider).frame(height: 1)
            HStack(spacing: 16) {
                hint("↑↓", "고르기")
                hint("↵", "이동")
                hint("esc", "닫기")
                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(height: 36)
        }
        .frame(width: 520)
        .onChange(of: entries.map(\.id), initial: true) { state.count = entries.count }
        .onChange(of: state.query) { state.picked = 0 }
        .onSubmit { if let picked { go(entries[picked].id) } }
        .onExitCommand(perform: close)
        .onAppear { focused = true }
    }

    private func row(_ entry: Entry, picked: Bool) -> some View {
        HStack(spacing: 10) {
            StatusMark(status: model.status(of: entry.id))
            Text(entry.name)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(picked ? Theme.strongText : Theme.rowText)
                .lineLimit(1)
            Text(entry.branch.isEmpty ? entry.project : "\(entry.project) · \(entry.branch)")
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(Theme.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if entry.id == model.selection {
                Text("지금").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 8).fill(picked ? Theme.selectedRow : .clear))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(picked ? .isSelected : [])
    }

    private func hint(_ key: String, _ label: LocalizedStringKey) -> some View {
        HStack(spacing: 6) {
            KeyHint(key)
            Text(label).font(.system(size: 12)).foregroundStyle(Theme.tertiary)
        }
    }

    private func go(_ id: UUID) {
        close()
        model.select(id)
    }
}

// MARK: - New workspace

/// A palette: type a name and press Return; the rest has sensible defaults.
struct NewWorkspaceSheet: View {
    let model: AppModel
    let project: Project
    let close: () -> Void

    private enum Field { case name, branch, base }

    @State private var name = ""
    @State private var branch = ""
    @State private var branchEdited = false
    @State private var useExisting = false
    @State private var base = ""
    @State private var existingBranch = ""
    @State private var branches: [String] = []
    @State private var defaultBase = ""
    @State private var error: String?
    @State private var checking = false
    /// What the first tab starts: a plain terminal unless another is picked.
    @State private var program = TabProgram.terminal
    @FocusState private var focus: Field?

    init(model: AppModel, project: Project, close: @escaping () -> Void) {
        self.model = model
        self.project = project
        self.close = close
    }

    private var suggestedBranch: String {
        WorkspaceNaming.branchName(for: name, prefix: model.state.settings.branchPrefix)
    }

    private var chosenBranch: String { useExisting ? existingBranch : branch }

    private var location: String {
        if project.isFolder { return (project.path as NSString).abbreviatingWithTildeInPath } // its workspaces share it
        let root = model.state.settings.workspaceRoot
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let path = trimmed.isEmpty ? nil : WorkspaceNaming.worktreePath(root: root, project: project.name, workspace: trimmed)
        return path.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "\(root)/\(project.name)/…"
    }

    private var canCreate: Bool {
        !checking && !name.trimmingCharacters(in: .whitespaces).isEmpty && (project.isFolder || !chosenBranch.isEmpty)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.accent)
                    .accessibilityHidden(true)
                TextField("워크스페이스 이름", text: $name, prompt: Text("워크스페이스 이름").foregroundColor(Theme.tertiary))
                    .textFieldStyle(.plain)
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.text)
                    .focused($focus, equals: .name)
                    .onChange(of: name) { if !branchEdited { branch = suggestedBranch } }
                Text(project.name)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.control))
                    .accessibilityLabel("프로젝트 \(project.name)")
            }
            .padding(.horizontal, 18)
            .frame(height: 58)
            Rectangle().fill(Theme.divider).frame(height: 1)

            VStack(spacing: 2) {
                if !project.isFolder { // no git: no branch, no start point
                    OptionRow(symbol: "arrow.triangle.branch", label: useExisting ? "기존 브랜치" : "새 브랜치", focused: focus == .branch) {
                        if useExisting {
                            Picker("체크아웃할 브랜치", selection: $existingBranch) {
                                ForEach(branches, id: \.self) { Text($0).tag($0) }
                            }
                            .labelsHidden()
                        } else {
                            TextField("브랜치 이름", text: Binding(get: { branch }, set: { branch = $0; branchEdited = true }))
                                .textFieldStyle(.plain)
                                .font(.system(size: 12.5, design: .monospaced))
                                .foregroundStyle(Theme.text)
                                .focused($focus, equals: .branch)
                        }
                        Button(LocalizedStringKey(useExisting ? "새 브랜치로" : "기존 브랜치로")) { useExisting.toggle() }
                            .buttonStyle(PlumButtonStyle(kind: .ghost, height: 24))
                    }
                    if !useExisting {
                        OptionRow(symbol: "arrow.right", label: "시작 지점", focused: focus == .base) {
                            TextField(
                                "시작 지점", text: $base,
                                prompt: (defaultBase.isEmpty ? Text("기본 브랜치") : Text(verbatim: defaultBase)).foregroundColor(Theme.tertiary))
                                .textFieldStyle(.plain)
                                .font(.system(size: 12.5, design: .monospaced))
                                .foregroundStyle(Theme.text)
                                .focused($focus, equals: .base)
                        }
                    }
                }
                OptionRow(symbol: "sparkles", label: "에이전트", focused: false) {
                    ProgramPicker(program: $program)
                        .padding(.leading, -8) // the choice's text lines up with the fields above
                    Spacer(minLength: 0)
                }
                OptionRow(symbol: "folder", label: "위치", focused: false) {
                    Text(location)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
            .padding(6)

            if let error {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 10)
                    .transition(.opacity)
            }
            Rectangle().fill(Theme.divider).frame(height: 1)
            HStack(spacing: 8) {
                if checking { ProgressView().controlSize(.small) }
                Spacer()
                Button("취소", role: .cancel, action: close)
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(PlumButtonStyle(kind: .ghost, height: 28))
                Button(action: create) {
                    HStack(spacing: 8) { Text("만들기"); ButtonKey("↵") }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(PlumButtonStyle(kind: .primary, height: 28))
                .disabled(!canCreate)
            }
            .padding(.horizontal, 14)
            .frame(height: 48)
        }
        .frame(width: 540)
        .animation(.easeOut(duration: 0.15), value: useExisting)
        .animation(.easeOut(duration: 0.15), value: error)
        .onSubmit(create)
        .onExitCommand(perform: close)
        .task {
            focus = .name
            guard !project.isFolder else { return } // git would answer for a repository above it
            let path = project.path
            let configured = project.baseBranch
            let loaded = await Task.detached { (Git.branches(in: path), Git.defaultBase(in: path)) }.value
            branches = loaded.0
            existingBranch = loaded.0.first ?? ""
            defaultBase = configured.isEmpty ? loaded.1 : configured
        }
    }

    /// Checks first with the palette still open, so a clash can be fixed in
    /// place; then closes it and makes the workspace, its steps in the panel.
    private func create() {
        guard canCreate else { return }
        let trimmedBase = base.trimmingCharacters(in: .whitespaces)
        let choice: WorkspaceService.BranchChoice = useExisting ? .existing : .new(base: trimmedBase.isEmpty ? nil : trimmedBase)
        let (model, projectID, name, branch, program) = (model, project.id, name, chosenBranch, program)
        checking = true
        error = nil
        Task {
            if let problem = await model.problemCreatingWorkspace(projectID: projectID, name: name, branch: branch, choice: choice) {
                error = problem
                checking = false
                return
            }
            close()
            do {
                try await model.createWorkspace(projectID: projectID, name: name, branch: branch, choice: choice, program: program)
            } catch {
                model.errorMessage = error.localizedDescription
            }
        }
    }
}

private struct OptionRow<Content: View>: View {
    let symbol: String
    let label: LocalizedStringKey
    let focused: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary)
                .frame(width: 16)
                .accessibilityHidden(true)
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .fixedSize()
                .frame(minWidth: 72, alignment: .leading)
                .accessibilityHidden(true)
            content()
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(RoundedRectangle(cornerRadius: 8).fill(focused ? Theme.focusRow : .clear))
        .animation(.easeOut(duration: 0.12), value: focused)
        .transition(.opacity)
    }
}

// MARK: - Settings

struct ProjectSettingsSheet: View {
    let model: AppModel
    @State var project: Project
    let close: () -> Void
    @State private var patterns: String
    @FocusState private var patternsFocused: Bool

    init(model: AppModel, project: Project, close: @escaping () -> Void) {
        self.model = model
        self.close = close
        _project = State(initialValue: project)
        _patterns = State(initialValue: project.copyPatterns.joined(separator: "\n"))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(project.name) 설정").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text)
                Text((project.path as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Theme.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(project.path)
            }
            if !project.isFolder { // a folder project's workspaces have no branch and no worktree to copy into
                PlumField(label: "시작 지점", text: $project.baseBranch, prompt: "원격 기본 브랜치", mono: true)
            }
            SectionLabel("워크스페이스를 만들 때")
            if !project.isFolder {
                VStack(alignment: .leading, spacing: 6) {
                    Text("복사할 파일 (한 줄에 하나)").font(.system(size: 12)).foregroundStyle(Theme.secondary).accessibilityHidden(true)
                    TextEditor(text: $patterns)
                        .font(.system(size: 12.5, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .focused($patternsFocused)
                        .padding(.vertical, 6)
                        .fieldWell(focused: patternsFocused, height: 64)
                        .accessibilityLabel("복사할 파일 패턴")
                    Text("기본 체크아웃에서 새 워크트리로 복사합니다. 예: .env*")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.tertiary)
                }
            }
            PlumField(
                label: "준비 명령", text: $project.setupCommand, prompt: "예: pnpm install", mono: true,
                hint: String(localized: "새 워크스페이스의 첫 탭에서, 고른 에이전트보다 먼저 실행합니다."))
            HStack(spacing: 8) {
                // Asks in a dialog of its own, which takes this one's place.
                Button("목록에서 제거", role: .destructive) { AppActions.removeProject(model, project) }
                .buttonStyle(PlumButtonStyle(kind: .danger))
                Spacer()
                Button("취소", role: .cancel, action: close)
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(PlumButtonStyle(kind: .ghost))
                Button(action: save) {
                    HStack(spacing: 8) { Text("저장"); ButtonKey("↵") }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(PlumButtonStyle(kind: .primary))
            }
        }
        .padding(22)
        .frame(width: 480)
        .onSubmit(save)
        .onExitCommand(perform: close)
    }

    private func save() {
        project.copyPatterns = patterns.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        project.baseBranch = project.baseBranch.trimmingCharacters(in: .whitespaces)
        model.update(project)
        close()
    }
}

/// The UI language: the system's unless one is chosen in Settings. macOS
/// reads AppleLanguages from the app's own defaults as it starts, so a
/// change shows once Plum restarts.
enum AppLanguage {
    /// "" follows the system.
    static var chosen: String {
        let own = Bundle.main.bundleIdentifier.flatMap { UserDefaults.standard.persistentDomain(forName: $0) }
        return (own?["AppleLanguages"] as? [String])?.first.flatMap { ["ko", "en"].contains($0) ? $0 : nil } ?? ""
    }

    static func choose(_ code: String) {
        if code.isEmpty {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([code], forKey: "AppleLanguages")
        }
    }
}

struct SettingsSheet: View {
    let model: AppModel
    @State var settings: AppSettings
    let close: () -> Void
    @State private var language = AppLanguage.chosen
    @State private var fonts: [String] = []
    @State private var problem: String?

    /// What the terminal will draw with, resolved the way the terminal does.
    private var previewFont: Font {
        Font(FontSpec.font(named: settings.fontName, size: settings.fontSize) as NSFont)
    }

    var body: some View {
        // Whole when it fits; scrolling in a short window.
        ViewThatFits(in: .vertical) {
            form
            ScrollView { form }.scrollBounceBehavior(.basedOnSize)
        }
        .frame(maxHeight: DialogCard.windowSize.height - 90)
        .frame(width: 480)
        .animation(Motion.settle, value: problem)
        .onSubmit(save)
        .onExitCommand(perform: close)
        .task { fonts = await Task.detached { FontSpec.monospacedFamilies() }.value }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("설정").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text)
            SectionLabel("모양")
            VStack(alignment: .leading, spacing: 6) {
                Text("강조 색").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                HStack(spacing: 8) {
                    ForEach(AccentChoice.allCases, id: \.self) { choice in
                        AccentSwatch(choice: choice, selected: settings.accent == choice) { settings.accent = choice }
                    }
                }
                .frame(height: 32)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("언어").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                Picker("언어", selection: $language) {
                    Text("시스템 언어").tag("")
                    // Each in its own language, so it can be found in either.
                    Text(verbatim: "한국어").tag("ko")
                    Text(verbatim: "English").tag("en")
                }
                .labelsHidden()
                .frame(width: 200, height: 32)
            }
            SectionLabel("터미널")
            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("글꼴").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    Picker("글꼴", selection: $settings.fontName) {
                        Text("시스템 고정폭").tag("")
                        // A name typed in an older version, or a font since removed.
                        if !settings.fontName.isEmpty, !fonts.contains(settings.fontName) {
                            Text(settings.fontName).tag(settings.fontName)
                        }
                        if !fonts.isEmpty { Divider() }
                        ForEach(fonts, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .frame(height: 32)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 6) {
                    Text("크기").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    HStack(spacing: 0) {
                        step("minus", "글자 작게", by: -1)
                        Text("\(Int(settings.fontSize))")
                            .font(.system(size: 13).monospacedDigit())
                            .foregroundStyle(Theme.text)
                            .frame(width: 30)
                        step("plus", "글자 크게", by: 1)
                    }
                    .frame(height: 32)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.well))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.fieldBorder))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("글꼴 크기")
                    .accessibilityValue("\(Int(settings.fontSize))")
                    .accessibilityAdjustableAction { direction in
                        switch direction {
                        case .increment: resize(by: 1)
                        case .decrement: resize(by: -1)
                        @unknown default: break
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("❯ ").foregroundColor(Theme.accent) + Text("claude")
                Text(verbatim: "가나다 한글 abc 0O 1lI ✓")
            }
            .font(previewFont)
            .foregroundStyle(Theme.terminalText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panelColor))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.divider))
            .accessibilityHidden(true)

            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("커서").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    Picker("커서", selection: $settings.cursorShape) {
                        Text("블록").tag(TerminalSession.CursorShape.block)
                        Text("막대").tag(TerminalSession.CursorShape.bar)
                        Text("밑줄").tag(TerminalSession.CursorShape.underline)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(height: 32)
                }
                Toggle(isOn: $settings.cursorBlinks) {
                    Text("깜빡임").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
                .toggleStyle(.checkbox)
                .frame(height: 32)
                Spacer()
                VStack(alignment: .leading, spacing: 6) {
                    Text("스크롤백(탭마다, MB)").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    TextField("10", value: $settings.scrollbackMB, format: .number)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(Theme.text)
                        .padding(.horizontal, 10)
                        .frame(width: 90, height: 32)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.well))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.fieldBorder))
                        .accessibilityLabel("스크롤백 크기, 메가바이트")
                }
            }
            Toggle(isOn: $settings.shellIntegration) {
                Text("zsh 연동: 명령 사이를 ⌘↑ ⌘↓로 이동 (새 탭부터)")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
            }
            .toggleStyle(.checkbox)
            Toggle(isOn: $settings.optionAsMeta) {
                Text("⌥를 Meta 키로 사용 (⌥B, ⌥. 같은 셸 단축키)")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
            }
            .toggleStyle(.checkbox)

            SectionLabel("워크스페이스")
            HStack(alignment: .bottom, spacing: 8) {
                PlumField(label: "위치", text: $settings.workspaceRoot, mono: true)
                Button("선택…", action: chooseFolder)
                    .buttonStyle(PlumButtonStyle(kind: .secondary, height: 32))
            }
            PlumField(
                label: "브랜치 접두사", text: $settings.branchPrefix, prompt: "예: dev/", mono: true,
                hint: String(localized: "새 브랜치 이름 예: \(WorkspaceNaming.branchName(for: "release-notes", prefix: settings.branchPrefix))"))

            SectionLabel("에이전트")
            PlumField(
                label: "Claude 명령", text: $settings.claudeCommand, prompt: LocalizedStringKey(AppSettings.defaultClaudeCommand), mono: true,
                hint: String(localized: "--settings \"$PLUM_CLAUDE_SETTINGS\"를 붙이면 작업 중·입력 대기·완료 상태가 사이드바에 보입니다."))
            PlumField(label: "Codex 명령", text: $settings.codexCommand, prompt: LocalizedStringKey(AppSettings.defaultCodexCommand), mono: true)
            VStack(alignment: .leading, spacing: 6) {
                Text("권한").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                Picker("권한", selection: $settings.agentPermission) {
                    Text("전체 허용").tag(AgentPermission.fullAccess)
                    Text("자동 승인").tag(AgentPermission.auto)
                    Text("에이전트 자체 설정").tag(AgentPermission.own)
                }
                .labelsHidden()
                .frame(height: 32)
                Text(permissionHint)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Toggle(isOn: $settings.trustWorkspaces) {
                Text("에이전트를 열 폴더를 미리 신뢰한 폴더로 기록")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
            }
            .toggleStyle(.checkbox)
            if let problem {
                Text(problem)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
            HStack(spacing: 8) {
                Spacer()
                Button("취소", role: .cancel, action: close)
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(PlumButtonStyle(kind: .ghost))
                Button(action: save) {
                    HStack(spacing: 8) { Text("저장"); ButtonKey("↵") }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(PlumButtonStyle(kind: .primary))
            }
        }
        .padding(22)
    }

    /// What the choice adds to the commands, so it's never a surprise.
    private var permissionHint: String {
        let claude = settings.agentPermission.flag(for: .claude)
        let codex = settings.agentPermission.flag(for: .codex)
        switch settings.agentPermission {
        case .fullAccess:
            return String(localized: "묻지 않고 모든 명령을 실행합니다. Claude에 \(claude ?? ""), Codex에 \(codex ?? "")를 붙입니다.")
        case .auto:
            return String(localized: "안전한 작업은 에이전트가 스스로 승인하고 나머지는 묻습니다. Claude에 \(claude ?? ""), Codex에 \(codex ?? "")를 붙입니다.")
        case .own:
            return String(localized: "플래그를 붙이지 않고 각 에이전트의 권한 설정을 따릅니다.")
        }
    }

    private func step(_ symbol: String, _ label: LocalizedStringKey, by delta: Double) -> some View {
        Button { resize(by: delta) } label: {
            Image(systemName: symbol).font(.system(size: 11, weight: .medium)).frame(width: 32, height: 32).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.secondary)
        .help(label)
    }

    private func resize(by delta: Double) {
        settings.fontSize = min(40, max(8, settings.fontSize + delta))
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "선택")
        panel.directoryURL = URL(fileURLWithPath: (settings.workspaceRoot as NSString).expandingTildeInPath)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.workspaceRoot = (url.path as NSString).abbreviatingWithTildeInPath
    }

    private func save() {
        settings.workspaceRoot = settings.workspaceRoot.trimmingCharacters(in: .whitespaces)
        if settings.workspaceRoot.isEmpty { settings.workspaceRoot = AppSettings().workspaceRoot }
        settings.branchPrefix = settings.branchPrefix.trimmingCharacters(in: .whitespaces)
        // Emptied: back to the command that works out of the box.
        settings.claudeCommand = settings.claudeCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        if settings.claudeCommand.isEmpty { settings.claudeCommand = AppSettings.defaultClaudeCommand }
        settings.codexCommand = settings.codexCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        if settings.codexCommand.isEmpty { settings.codexCommand = AppSettings.defaultCodexCommand }
        // Relative to what? A relative location would follow whatever the
        // current directory happens to be.
        guard settings.workspaceRoot.hasPrefix("/") || settings.workspaceRoot.hasPrefix("~") else {
            problem = String(localized: "워크스페이스 위치는 /나 ~로 시작하는 전체 경로여야 합니다.")
            return
        }
        guard settings.branchPrefix.isEmpty || Git.isValidBranchName(settings.branchPrefix + "x") else {
            problem = String(localized: "브랜치 이름에 쓸 수 없는 접두사입니다: \(settings.branchPrefix)")
            return
        }
        model.update(settings)
        close()
        guard language != AppLanguage.chosen else { return }
        AppLanguage.choose(language)
        Task {
            let restart = await AppActions.ask(model, Confirmation(
                title: String(localized: "언어를 바꿨습니다"),
                summary: String(localized: "Plum을 다시 시작하면 적용됩니다. 지금 다시 시작할까요? 터미널과 그 안의 프로그램은 그대로 이어집니다."),
                action: String(localized: "다시 시작"), destructive: false))
            if restart { AppActions.relaunch(Bundle.main.bundleURL) }
        }
    }
}

// MARK: - Confirmation

struct ConfirmSheet: View {
    let confirmation: Confirmation
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(confirmation.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                Text(confirmation.summary)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(confirmation.sections.enumerated()), id: \.offset) { _, section in
                LineList(section: section)
            }
            if let note = confirmation.note {
                Label(note, systemImage: "terminal")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
            }
            // The safe choice is the default: Return never destroys work.
            HStack(spacing: 8) {
                Spacer()
                // Return and Esc are handled below, for the whole dialog.
                Button(role: confirmation.destructive ? .destructive : nil) { finish(true) } label: {
                    HStack(spacing: 8) {
                        Text(confirmation.action)
                        if !confirmation.destructive { ButtonKey("↵") }
                    }
                }
                .buttonStyle(PlumButtonStyle(kind: confirmation.destructive ? .danger : .primary))
                Button(role: .cancel) { finish(false) } label: {
                    HStack(spacing: 8) {
                        Text("취소")
                        ButtonKey(confirmation.destructive ? "↵" : "esc")
                    }
                }
                .buttonStyle(PlumButtonStyle(kind: .secondary))
            }
        }
        .padding(22)
        .frame(width: 500)
        // Return and Esc are caught by the window controller while this is
        // open (`Confirmation.answerForKey`): SwiftUI doesn't deliver Return
        // to a view without a text field.
        .onDisappear { confirmation.finish(false) }
    }

    private func finish(_ confirmed: Bool) {
        confirmation.finish(confirmed)
        close()
    }
}

/// One section of a confirmation, one item per line: a short code (status,
/// hash) when there is one, then the rest.
private struct LineList: View {
    let section: Confirmation.Section
    private var title: String { section.title }
    private var lines: [String] { section.lines }
    private var maxCode: Int { section.maxCode }
    @State private var unfolded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.text)
                Text("\(lines.count + section.folded.count)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.panelColor)
                    .padding(.horizontal, 6)
                    .frame(height: 16)
                    .background(Capsule().fill(lines.isEmpty ? Theme.secondary : Theme.waiting))
            }
            .accessibilityElement(children: .combine)
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(lines.prefix(12).enumerated()), id: \.offset) { _, line in
                    let parts = Confirmation.split(line, maxCode: maxCode)
                    HStack(spacing: 10) {
                        if !parts.code.isEmpty {
                            Text(parts.code)
                                .foregroundStyle(maxCode > 2 || parts.code == "??" ? Theme.tertiary : Theme.waiting)
                                .frame(minWidth: maxCode > 2 ? nil : 18, alignment: .leading)
                        }
                        Text(parts.rest).foregroundStyle(Theme.rowText).lineLimit(1).truncationMode(.middle)
                    }
                }
                if lines.count > 12 {
                    Text("… 외 \(lines.count - 12)개").foregroundStyle(Theme.tertiary)
                }
                if !section.folded.isEmpty {
                    Button { unfolded.toggle() } label: {
                        HStack(spacing: 6) {
                            Image(systemName: unfolded ? "chevron.down" : "chevron.right").font(.system(size: 8, weight: .bold))
                            Text(verbatim: section.foldedTitle)
                        }
                        .foregroundStyle(Theme.secondary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if unfolded {
                        ForEach(Array(section.folded.prefix(12).enumerated()), id: \.offset) { _, line in
                            Text(line).foregroundStyle(Theme.tertiary).lineLimit(1).truncationMode(.middle).padding(.leading, 14)
                        }
                        if section.folded.count > 12 {
                            Text("… 외 \(section.folded.count - 12)개").foregroundStyle(Theme.tertiary).padding(.leading, 14)
                        }
                    }
                }
            }
            .font(.system(size: 12, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.well))
        }
    }
}

/// One accent color to pick: a dot, ringed when it's the one chosen.
private struct AccentSwatch: View {
    let choice: AccentChoice
    let selected: Bool
    let pick: () -> Void

    private var name: LocalizedStringKey {
        switch choice {
        case .plum: "자두"
        case .blue: "파랑"
        case .green: "초록"
        case .orange: "주황"
        case .pink: "분홍"
        case .graphite: "흑연"
        }
    }

    var body: some View {
        Button(action: pick) {
            Circle()
                .fill(Color(nsColor: choice.color))
                .frame(width: 18, height: 18)
                .padding(3)
                .overlay(Circle().strokeBorder(selected ? Theme.text : .clear, lineWidth: 1.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(Text(name))
        .accessibilityLabel(Text(name))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
