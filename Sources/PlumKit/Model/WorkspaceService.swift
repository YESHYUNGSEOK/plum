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
        var fileSnapshot: [String]?

        public var isClean: Bool { uncommitted.isEmpty && unpushed.isEmpty }

        /// The `uncommitted` lines that are work: changes to tracked files and new
        /// files (and a line saying the state couldn't be read: unknown is not clean).
        public var changes: [String] { uncommitted.filter { !$0.hasPrefix("!! ") } }

        /// The ignored files and folders among them (paths), apart: ones an
        /// install or a build makes again, and the rest, which may be gone for
        /// good with the folder (`.env.local`).
        public var ignored: (kept: [String], rebuildable: [String]) {
            let paths = uncommitted.filter { $0.hasPrefix("!! ") }.map { String($0.dropFirst(3)) }
            return (paths.filter { !Self.isRebuildable($0) }, paths.filter(Self.isRebuildable))
        }

        /// Something would be lost that nothing makes again.
        public var hasLosses: Bool { !changes.isEmpty || !ignored.kept.isEmpty || !unpushed.isEmpty }

        /// By name alone: a folder tools fill (`node_modules`, `.next`, `dist`,
        /// `build`, generated code) anywhere in the path, or a file they write.
        /// ponytail: a fixed list of names; a project that keeps work in a
        /// folder called `build` has it folded away with the rest.
        static func isRebuildable(_ path: String) -> Bool {
            let parts = path.trimmingCharacters(in: CharacterSet(charactersIn: "\"")).split(separator: "/").map(String.init)
            let folders: Set = ["node_modules", ".next", ".nuxt", "dist", "build", ".build", "target", ".turbo", ".cache", ".parcel-cache",
                                "coverage", "__pycache__", ".pytest_cache", ".venv", "venv", ".gradle", "DerivedData", "Pods", ".swiftpm", "generated"]
            guard let name = parts.last else { return false }
            return parts.contains(where: folders.contains) || name.hasSuffix(".tsbuildinfo") || name == "next-env.d.ts" || name == ".DS_Store"
        }
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
        if !check.folderMissing, !workspace.isArchived {
            check.nested = nestedWorktrees(workspace, project: project)
            check.fileSnapshot = fileSnapshot(in: workspace.path, excluding: check.nested)
        }
        return check
    }

    private static func fileSnapshot(in path: String, excluding nested: [Git.Worktree]) -> [String]? {
        let root = URL(fileURLWithPath: canonical(path))
        let canonicalRoot = root.path + "/"
        let excluded = nested.map { String(canonical($0.path).dropFirst(canonicalRoot.count)) }
        var failed = false
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
                                                         errorHandler: { _, _ in failed = true; return false }) else { return nil }
        var snapshot: [String] = []
        for case let file as URL in files {
            guard file.path.hasPrefix(canonicalRoot) else { return nil }
            let relative = String(file.path.dropFirst(canonicalRoot.count))
            if relative == ".git" || excluded.contains(where: { relative == $0 || relative.hasPrefix($0 + "/") }) {
                files.skipDescendants()
                continue
            }
            var details = stat()
            guard lstat(file.path, &details) == 0 else { failed = true; break }
            let kind = details.st_mode & S_IFMT
            let stamp = kind == S_IFDIR ? "" : "\(details.st_ino):\(details.st_size):\(details.st_mtimespec.tv_sec):\(details.st_mtimespec.tv_nsec):\(details.st_ctimespec.tv_sec):\(details.st_ctimespec.tv_nsec)"
            snapshot.append("\(relative):\(kind):\(stamp)")
            if snapshot.count > 200_000 { return nil }
        }
        return failed ? nil : snapshot.sorted()
    }

    private static func matchesApproval(_ changes: [String], in path: String, approved: RemovalCheck?) -> Bool {
        guard let approved, let snapshot = approved.fileSnapshot else { return false }
        return changes == approved.uncommitted && fileSnapshot(in: path, excluding: approved.nested) == snapshot
    }

    /// The worktrees git has inside a workspace's folder, deepest first.
    public static func nestedWorktrees(_ workspace: Workspace, project: Project) -> [Git.Worktree] {
        let folder = canonical(workspace.path) + "/"
        return Git.worktrees(in: project.path).dropFirst() // never the main checkout
            .filter { canonical($0.path).hasPrefix(folder) }
            .sorted { $0.path.count > $1.path.count }
    }

    /// Deletes as Orca does: the worktrees inside the folder first, deepest first,
    /// then the workspace's own, each branch only if merged. `approved` is
    /// what the user confirmed; if it changed, nothing is removed.
    /// Returns the branches kept because they aren't merged.
    public static func delete(_ workspace: Workspace, project: Project, force: Bool,
                              approved: RemovalCheck? = nil) throws -> [Git.Branch] {
        var kept: [Git.Branch] = []
        if !workspace.isArchived {
            if FileManager.default.fileExists(atPath: workspace.path) {
                if approved != nil, approved?.fileSnapshot == nil {
                    throw GitError(message: String(localized: "워크트리의 파일을 확인하지 못해 삭제하지 않았습니다."))
                }
                let changes = try Git.uncommittedChanges(in: workspace.path)
                if force, !matchesApproval(changes, in: workspace.path, approved: approved) {
                    throw GitError(message: String(localized: "확인 후 워크트리의 파일이 바뀌었습니다. 다시 확인한 뒤 삭제하세요."))
                }
            }
            let nested = FileManager.default.fileExists(atPath: workspace.path) ? nestedWorktrees(workspace, project: project) : []
            guard nested == (approved?.nested ?? []) else {
                throw GitError(message: String(localized: "안쪽 워크트리 목록이 바뀌었습니다. 다시 확인한 뒤 삭제하세요."))
            }
            for inner in nested where !(try Git.uncommittedChanges(in: inner.path)).isEmpty {
                throw GitError(message: String(localized: "안쪽 워크트리에 저장되지 않은 변경이 있습니다. 확인 후 다시 시도하세요: \(inner.path)"))
            }
            for inner in nested {
                try Git.removeWorktree(repository: project.path, path: inner.path, force: false)
                if let branch = inner.branch, let left = Git.deleteBranchIfMerged(branch, in: project.path) { kept.append(left) }
            }
            let remaining = force && !nested.isEmpty ? try Git.uncommittedChanges(in: workspace.path) : approved?.uncommitted ?? []
            if force, !Set(remaining).isSubset(of: Set(approved?.uncommitted ?? [])) {
                throw GitError(message: String(localized: "확인 후 워크트리의 파일이 바뀌었습니다. 다시 확인한 뒤 삭제하세요."))
            }
            var afterApproval = approved
            afterApproval?.uncommitted = remaining
            try removeWorktree(workspace, project: project, force: force, approved: afterApproval)
        }
        if let left = Git.deleteBranchIfMerged(workspace.branch, in: project.path) { kept.append(left) }
        return kept
    }

    /// Removes the worktree folder and git's record of it. Without `force`,
    /// uncommitted or ignored files are kept until their loss is confirmed.
    public static func removeWorktree(_ workspace: Workspace, project: Project, force: Bool,
                                      approved: RemovalCheck? = nil) throws {
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
        if FileManager.default.fileExists(atPath: workspace.path) {
            if approved != nil, approved?.fileSnapshot == nil {
                throw GitError(message: String(localized: "워크트리의 파일을 확인하지 못해 삭제하지 않았습니다."))
            }
            let changes = try Git.uncommittedChanges(in: workspace.path)
            if force, !matchesApproval(changes, in: workspace.path, approved: approved) {
                throw GitError(message: String(localized: "확인 후 워크트리의 파일이 바뀌었습니다. 다시 확인한 뒤 삭제하세요."))
            }
            if !force, !changes.isEmpty {
                throw GitError(message: String(localized: "워크트리에 저장되지 않은 파일이 있습니다. 확인 후 다시 시도하세요."))
            }
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
