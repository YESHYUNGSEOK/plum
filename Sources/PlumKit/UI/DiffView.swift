import AppKit
import SwiftUI

/// What changed in a workspace: files on the left, the chosen one's lines
/// on the right. Since the last commit, or everything on the branch.
struct DiffSheet: View {
    let model: AppModel
    let workspace: Workspace
    let close: () -> Void

    @State private var scope = Diff.Scope.uncommitted
    @State private var files: [Diff.File] = []
    @State private var picked: String?
    @State private var loading = true
    @State private var problem: String?

    private var file: Diff.File? { files.first { $0.path == picked } ?? files.first }
    private var size: CGSize {
        let window = DialogCard.windowSize
        return CGSize(width: min(1040, window.width - 80), height: min(700, window.height - 90))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.divider).frame(height: 1)
            content
        }
        .frame(width: size.width, height: size.height)
        .onExitCommand(perform: close)
        .task(id: scope) { await load() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("변경 사항").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                Text(verbatim: "\(workspace.name) · \(model.branch(of: workspace))")
                    .font(.system(size: 11)).foregroundStyle(Theme.tertiary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Picker("범위", selection: $scope) {
                Text("커밋 안 한 변경").tag(Diff.Scope.uncommitted)
                Text("브랜치 전체").tag(Diff.Scope.branch)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 230)
            let added = files.reduce(0) { $0 + $1.added }, removed = files.reduce(0) { $0 + $1.removed }
            HStack(spacing: 4) {
                if added > 0 { Text(verbatim: "+\(added)").foregroundStyle(Theme.done) }
                if removed > 0 { Text(verbatim: "−\(removed)").foregroundStyle(Theme.danger) }
            }
            .font(.system(size: 12, weight: .medium).monospacedDigit())
            .opacity(loading ? 0.4 : 1)
            Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(PlumButtonStyle(kind: .ghost, height: 28))
                .help("새로 고침")
                .accessibilityLabel("새로 고침")
            if let pullRequest = model.pullRequest(of: workspace) {
                Button("PR #\(pullRequest.number) 열기") { NSWorkspace.shared.open(pullRequest.url) }
                    .buttonStyle(PlumButtonStyle(kind: .secondary, height: 28))
            } else if !model.isMain(workspace) {
                Button("PR 만들기") {
                    close()
                    model.createPullRequest(workspace.id)
                }
                .buttonStyle(PlumButtonStyle(kind: .primary, height: 28))
            }
            Button(action: close) { Image(systemName: "xmark") }
                .buttonStyle(PlumButtonStyle(kind: .ghost, height: 28))
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("닫기")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var content: some View {
        if loading && files.isEmpty {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let problem {
            message(problem, color: Theme.danger)
        } else if files.isEmpty {
            message(scope == .uncommitted ? String(localized: "커밋하지 않은 변경이 없습니다.") : String(localized: "이 브랜치에서 바뀐 것이 없습니다."), color: Theme.tertiary)
        } else {
            HStack(spacing: 0) {
                fileList.frame(width: 270)
                Rectangle().fill(Theme.divider).frame(width: 1)
                if let file { FileLines(file: file).id(file.path) }
            }
        }
    }

    private func message(_ text: String, color: Color) -> some View {
        Text(text).font(.system(size: 13)).foregroundStyle(color).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var fileList: some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                ForEach(files) { item in
                    let chosen = item.path == file?.path
                    Button { picked = item.path } label: {
                        HStack(spacing: 6) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text((item.path as NSString).lastPathComponent)
                                    .font(.system(size: 12, weight: chosen ? .semibold : .regular))
                                    .foregroundStyle(item.isDeleted ? Theme.secondary : Theme.text)
                                    .strikethrough(item.isDeleted)
                                    .lineLimit(1)
                                let folder = (item.path as NSString).deletingLastPathComponent
                                if !folder.isEmpty {
                                    Text(folder).font(.system(size: 10)).foregroundStyle(Theme.tertiary).lineLimit(1).truncationMode(.head)
                                }
                            }
                            Spacer(minLength: 4)
                            if item.isNew { Text("새 파일").font(.system(size: 9.5, weight: .medium)).foregroundStyle(Theme.done) }
                            HStack(spacing: 3) {
                                if item.added > 0 { Text(verbatim: "+\(item.added)").foregroundStyle(Theme.done) }
                                if item.removed > 0 { Text(verbatim: "−\(item.removed)").foregroundStyle(Theme.danger) }
                            }
                            .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 7).fill(chosen ? Theme.selectedRow : .clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "\(item.path), \(item.added)줄 추가, \(item.removed)줄 삭제"))
                    .accessibilityAddTraits(chosen ? .isSelected : [])
                }
            }
            .padding(6)
        }
    }

    private func load() async {
        loading = true
        problem = nil
        let path = workspace.path, scope = scope
        let base = model.mainBranches[workspace.projectID] ?? "main"
        let result = await Task.detached { Result { try Diff.files(in: path, scope: scope, base: base) } }.value
        switch result {
        case let .success(found):
            files = found
            if !found.contains(where: { $0.path == picked }) { picked = found.first?.path }
        case let .failure(error):
            files = []
            problem = error.localizedDescription
        }
        loading = false
    }
}

/// One file's lines with old and new line numbers, colored as in a review.
private struct FileLines: View {
    let file: Diff.File

    var body: some View {
        GeometryReader { proxy in
            ScrollView([.vertical, .horizontal]) {
                // At least as big as the pane: lines start top left, and
                // their color runs across it.
                LazyVStack(alignment: .leading, spacing: 0) {
                    if file.isBinary {
                        Text("바이너리 파일").font(.system(size: 12)).foregroundStyle(Theme.tertiary).padding(16)
                    }
                    ForEach(Array(file.lines.enumerated()), id: \.offset) { _, line in row(line) }
                    if file.omitted > 0 {
                        Text("… \(file.omitted)줄 더 있음").font(.system(size: 11)).foregroundStyle(Theme.tertiary).padding(12)
                    }
                }
                .padding(.vertical, 6)
                .frame(minWidth: proxy.size.width, minHeight: proxy.size.height, alignment: .topLeading)
            }
        }
        .textSelection(.enabled)
    }

    private func row(_ line: Diff.Line) -> some View {
        HStack(spacing: 0) {
            number(line.old)
            number(line.new)
            Text(verbatim: marker(line.kind) + line.text)
                .foregroundStyle(line.kind == .hunk ? Theme.accent.opacity(0.85) : Theme.terminalText)
                .padding(.leading, 8)
                .fixedSize()
            Spacer(minLength: 16)
        }
        .font(.system(size: 12, design: .monospaced))
        .frame(maxWidth: .infinity, minHeight: 18, alignment: .leading)
        .background(background(line.kind))
    }

    private func number(_ value: Int?) -> some View {
        Text(verbatim: value.map(String.init) ?? "")
            .foregroundStyle(Theme.tertiary.opacity(0.7))
            .frame(width: 44, alignment: .trailing)
    }

    private func marker(_ kind: Diff.Line.Kind) -> String {
        switch kind {
        case .added: "+ "
        case .removed: "- "
        case .context: "  "
        case .hunk: ""
        }
    }

    private func background(_ kind: Diff.Line.Kind) -> Color {
        switch kind {
        case .added: Theme.done.opacity(0.12)
        case .removed: Theme.danger.opacity(0.12)
        case .hunk: Theme.accent.opacity(0.07)
        case .context: .clear
        }
    }
}
