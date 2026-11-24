import Foundation

/// Creating, archiving, restoring and deleting workspaces on disk.
/// Everything here blocks on git: call off the main thread.
public enum WorkspaceService {
    public enum BranchChoice: Equatable {
        /// Create the branch from `base` (nil = the project's default base).
        case new(base: String?)
        /// Check out a branch that already exists, locally or on a remote.
        case existing
    }

    /// What would be lost by removing a workspace.
    public struct RemovalCheck: Equatable {
        public var folderMissing = false
        /// `git status --porcelain` lines: modified, staged, untracked and ignored files.
        public var uncommitted: [String] = []
        /// Commits that are on no remote. Only filled when the branch would be deleted.
        public var unpushed: [String] = []
        /// Other worktrees inside the folder, deepest first: removing it takes them too.
        public var nested: [Git.Worktree] = []

        public var isClean: Bool { uncommitted.isEmpty && unpushed.isEmpty }
    }

    public struct Created {
        public var workspace: Workspace
        public var copiedFiles: [String]
        public var rejectedPatterns: [String]
    }

    /// The steps of making a workspace, in the order they run.
    public enum CreateStep: Equatable, Sendable { case fetch, worktree, copy }

    /// The checks `create` makes before touching anything: quick enough to
    /// run while the user is still in the form. Returns the worktree path.
    public static func validate(
        project: Project, name: String, branch: String, choice: BranchChoice,
        root: String, existing: [Workspace]
    ) throws -> String {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { throw GitError(message: String(localized: "워크스페이스 이름을 입력하세요.")) }
        guard let path = WorkspaceNaming.worktreePath(root: root, project: project.name, workspace: name) else {
            throw GitError(message: String(localized: "이 이름으로는 폴더를 만들 수 없습니다: \(name)"))
        }
        guard !existing.contains(where: { $0.projectID == project.id && (samePath($0.path, path) || $0.name == name) }) else {
            throw GitError(message: String(localized: "같은 이름의 워크스페이스가 이미 있습니다: \(name)"))
        }
        guard !FileManager.default.fileExists(atPath: path) else {
            throw GitError(message: String(localized: "폴더가 이미 있습니다: \(path)"))
        }
        guard Git.isValidBranchName(branch) else {
            throw GitError(message: String(localized: "브랜치 이름으로 쓸 수 없습니다: \(branch)"))
        }
        if case .new = choice, Git.branchExists(branch, in: project.path) {
            throw GitError(message: String(localized: "브랜치가 이미 있습니다: \(branch). \"기존 브랜치\"를 선택하세요."))
        }
        return path
    }

    /// `progress` is told each step as it starts, on the calling thread.
    public static func create(
        project: Project, name: String, branch: String, choice: BranchChoice,
        root: String, existing: [Workspace], progress: (CreateStep) -> Void = { _ in }
    ) throws -> Created {
        let path = try validate(project: project, name: name, branch: branch, choice: choice, root: root, existing: existing)
        let name = name.trimmingCharacters(in: .whitespaces)

        var base: String?
        if case let .new(requested) = choice {
            progress(.fetch)
            Git.fetch(in: project.path)
            let chosen = requested ?? project.baseBranch
            base = chosen.isEmpty ? Git.defaultBase(in: project.path) : chosen
        }

        progress(.worktree)
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
        try Git.addWorktree(repository: project.path, path: path, branch: branch, newBranchFrom: base)

        // For a remote branch, the worktree's local branch drops the remote name.
        let actualBranch = Git.worktrees(in: project.path).first { samePath($0.path, path) }?.branch ?? branch
        if !project.copyPatterns.isEmpty { progress(.copy) }
        let files = WorkspaceFiles.copy(patterns: project.copyPatterns, from: project.path, to: path)
        return Created(
            workspace: Workspace(projectID: project.id, name: name, branch: actualBranch, path: path),
            copiedFiles: files.copied, rejectedPatterns: files.rejected)
    }

    public static func inspect(_ workspace: Workspace, project: Project, deletingBranch: Bool) -> RemovalCheck {
        var check = RemovalCheck()
        check.folderMissing = !FileManager.default.fileExists(atPath: workspace.path)
        if !check.folderMissing, !workspace.isArchived {
            do {
                check.uncommitted = try Git.uncommittedChanges(in: workspace.path)
            } catch {
                // Unknown is not clean: make the user confirm explicitly.
                check.uncommitted = [String(localized: "상태를 확인하지 못했습니다: \(error.localizedDescription)")]
            }
        }
        if deletingBranch { check.unpushed = Git.unpushedCommits(on: workspace.branch, in: project.path) }
        if !check.folderMissing, !workspace.isArchived { check.nested = nestedWorktrees(workspace, project: project) }
        return check
    }

    /// The worktrees git has inside a workspace's folder, deepest first.
    public static func nestedWorktrees(_ workspace: Workspace, project: Project) -> [Git.Worktree] {
        let folder = canonical(workspace.path) + "/"
        return Git.worktrees(in: project.path).dropFirst() // never the main checkout
            .filter { canonical($0.path).hasPrefix(folder) }
            .sorted { $0.path.count > $1.path.count }
    }

    /// Deletes as Orca does: the worktrees inside the folder first, deepest first,
    /// then the workspace's own, each branch only if merged. `approvedNested` is
    /// the list the user confirmed; if git now has another, nothing is removed.
    /// Returns the branches kept because they aren't merged.
    public static func delete(_ workspace: Workspace, project: Project, force: Bool,
                              approvedNested: [Git.Worktree]) throws -> [Git.Branch] {
        var kept: [Git.Branch] = []
        if !workspace.isArchived {
            let nested = FileManager.default.fileExists(atPath: workspace.path) ? nestedWorktrees(workspace, project: project) : []
            guard nested == approvedNested else {
                throw GitError(message: String(localized: "안쪽 워크트리 목록이 바뀌었습니다. 다시 확인한 뒤 삭제하세요."))
            }
            for inner in nested where !(try Git.uncommittedChanges(in: inner.path)).isEmpty {
                throw GitError(message: String(localized: "안쪽 워크트리에 저장되지 않은 변경이 있습니다. 확인 후 다시 시도하세요: \(inner.path)"))
            }
            for inner in nested {
                try Git.removeWorktree(repository: project.path, path: inner.path, force: false)
                if let branch = inner.branch, let left = Git.deleteBranchIfMerged(branch, in: project.path) { kept.append(left) }
            }
            try removeWorktree(workspace, project: project, force: force)
        }
        if let left = Git.deleteBranchIfMerged(workspace.branch, in: project.path) { kept.append(left) }
        return kept
    }

    /// Removes the worktree folder and git's record of it. Without `force`,
    /// uncommitted or ignored files are kept until their loss is confirmed.
    public static func removeWorktree(_ workspace: Workspace, project: Project, force: Bool) throws {
        guard nestedWorktrees(workspace, project: project).isEmpty else {
            throw GitError(message: String(localized: "안쪽 워크트리가 있어 아카이브할 수 없습니다. 안쪽 워크트리를 먼저 정리하세요."))
        }
        let registered = Git.worktrees(in: project.path)
        guard let index = registered.firstIndex(where: { samePath($0.path, workspace.path) }) else {
            // git doesn't know this path. If the folder is gone too there is
            // nothing left to do; otherwise it isn't ours to delete.
            guard !FileManager.default.fileExists(atPath: workspace.path) else {
                throw GitError(message: String(localized: "이 폴더는 \(project.name)의 워크트리가 아니어서 지우지 않았습니다: \(workspace.path)"))
            }
            return
        }
        guard index != 0, !samePath(workspace.path, project.path) else {
            throw GitError(message: String(localized: "프로젝트의 기본 체크아웃은 지울 수 없습니다."))
        }
        if !force, FileManager.default.fileExists(atPath: workspace.path), !(try Git.uncommittedChanges(in: workspace.path)).isEmpty {
            throw GitError(message: String(localized: "워크트리에 저장되지 않은 파일이 있습니다. 확인 후 다시 시도하세요."))
        }
        try Git.removeWorktree(repository: project.path, path: workspace.path, force: force)
    }

    /// Recreates the worktree of an archived workspace from its kept branch.
    public static func restore(_ workspace: Workspace, project: Project) throws -> Created {
        guard !FileManager.default.fileExists(atPath: workspace.path) else {
            throw GitError(message: String(localized: "폴더가 이미 있습니다: \(workspace.path)"))
        }
        guard Git.branchExists(workspace.branch, in: project.path) else {
            throw GitError(message: String(localized: "브랜치가 없어 복원할 수 없습니다: \(workspace.branch)"))
        }
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: workspace.path).deletingLastPathComponent(), withIntermediateDirectories: true)
        try Git.addWorktree(repository: project.path, path: workspace.path, branch: workspace.branch, newBranchFrom: nil)
        let files = WorkspaceFiles.copy(patterns: project.copyPatterns, from: project.path, to: workspace.path)
        var restored = workspace
        restored.isArchived = false
        return Created(workspace: restored, copiedFiles: files.copied, rejectedPatterns: files.rejected)
    }

    /// git reports real paths (/private/var…) while we may hold a symlinked
    /// spelling (/var…), so compare canonical forms.
    static func samePath(_ a: String, _ b: String) -> Bool {
        canonical(a) == canonical(b)
    }

    /// `realpath` that also works when the last components no longer exist:
    /// a worktree folder deleted behind our back must still match git's record.
    static func canonical(_ path: String) -> String {
        var url = URL(fileURLWithPath: path).standardizedFileURL
        var missing: [String] = []
        while url.path != "/" {
            if let real = realpath(url.path, nil) {
                defer { free(real) }
                return ([String(cString: real)] + missing.reversed()).joined(separator: "/")
            }
            missing.append(url.lastPathComponent)
            url.deleteLastPathComponent()
        }
        return path
    }
}
