import AppKit

/// A one-time import of what someone had in Orca: its repositories become
/// projects and their worktrees workspaces. Read through Orca's own CLI
/// (`repo list --json`, `worktree list --json`), the interface Orca offers
/// tools; nothing of Orca's is written. Its output is input from outside:
/// paths are checked on disk before use (`load`), and output in a shape
/// Plum doesn't know imports nothing.
enum OrcaImport {
    struct Repo: Equatable {
        var id: String
        var path: String
        var name: String
    }

    struct Worktree: Equatable {
        var repoID: String
        var path: String
        /// Without "refs/heads/".
        var branch: String
        var name: String
    }

    struct Catalog: Equatable {
        var repos: [Repo] = []
        var worktrees: [Worktree] = []
        /// Worktrees left out: no branch (a workspace is a branch), folder gone.
        var detached = 0
        var missing = 0
    }

    struct Result: Equatable {
        var projects = 0
        var workspaces = 0
    }

    enum Failure: Error, Equatable {
        case notInstalled, notRunning, unreadable
    }

    static let bundleID = "com.stablyai.orca"

    /// Orca's CLI inside its app, if Orca is installed. Run by this path,
    /// never looked up in PATH.
    static func cli() -> URL? {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let cli = app.appendingPathComponent("Contents/Resources/bin/orca")
        return FileManager.default.isExecutableFile(atPath: cli.path) ? cli : nil
    }

    /// Orca's version, for saying which Orca's output couldn't be read.
    static func version() -> String? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .flatMap { Bundle(url: $0)?.infoDictionary?["CFBundleShortVersionString"] as? String }
    }

    /// What Orca has, from its CLI, with every path checked on disk: a
    /// repository's folder must be a git repository (its root is kept), a
    /// worktree's folder must exist (else it counts as missing) and be one
    /// of that repository's worktrees by git's own list.
    static func load(cli: URL, timeout: TimeInterval = 15) async throws -> Catalog {
        try await Task.detached {
            var catalog = try parse(repos: run(cli, ["repo", "list", "--json"], timeout: timeout),
                                    worktrees: run(cli, ["worktree", "list", "--json", "--limit", "10000"], timeout: timeout))
            catalog.repos = catalog.repos.compactMap { repo in
                guard FileManager.default.fileExists(atPath: repo.path), let root = Git.repositoryRoot(of: repo.path) else { return nil }
                var repo = repo
                repo.path = root
                return repo
            }
            // Orca names worktrees; git says which are this repository's
            // (not its main checkout) and on what branch. A branch from Orca
            // never reaches git's arguments.
            var known: [String: (root: String, worktrees: [Git.Worktree])] = [:]
            for repo in catalog.repos { known[repo.id] = (repo.path, Git.worktrees(in: repo.path)) }
            var worktrees: [Worktree] = []
            for var worktree in catalog.worktrees {
                guard let (root, gits) = known[worktree.repoID] else { continue }
                guard FileManager.default.fileExists(atPath: worktree.path) else {
                    catalog.missing += 1
                    continue
                }
                guard !WorkspaceService.samePath(worktree.path, root),
                      let git = gits.first(where: { WorkspaceService.samePath($0.path, worktree.path) }) else { continue }
                guard let branch = git.branch else {
                    catalog.detached += 1
                    continue
                }
                worktree.branch = branch
                worktrees.append(worktree)
            }
            catalog.worktrees = worktrees
            return catalog
        }.value
    }

    /// The CLI's output whatever its exit status: Orca exits 1 with a JSON
    /// reply when it isn't running. One that doesn't finish in `timeout`
    /// is stopped and counts as unreadable.
    private static func run(_ cli: URL, _ arguments: [String], timeout: TimeInterval) throws -> Data {
        let process = Process()
        process.executableURL = cli
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { throw Failure.unreadable }
        var output = Data()
        let read = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            output = stdout.fileHandleForReading.readDataToEndOfFile()
            read.signal()
        }
        let deadline = DispatchTime.now() + timeout
        guard read.wait(timeout: deadline) == .success, exited.wait(timeout: deadline) == .success else {
            process.terminate()
            throw Failure.unreadable
        }
        return output
    }

    /// The two lists as the CLI prints them, filtered: no folder (non-git)
    /// or hidden repositories, no main checkouts, no detached worktrees.
    static func parse(repos: Data, worktrees: Data) throws -> Catalog {
        let repoItems = try items(repos, "repos")
        let worktreeResult = try result(worktrees)
        guard let worktreeItems = worktreeResult["worktrees"] as? [[String: Any]],
              worktreeResult["truncated"] as? Bool != true else { throw Failure.unreadable }

        var catalog = Catalog()
        for item in repoItems {
            guard let id = item["id"] as? String, let path = item["path"] as? String else { throw Failure.unreadable }
            // A missing kind is git; folders aren't repositories.
            guard (item["kind"] as? String ?? "git") == "git", item["hiddenAt"] == nil || item["hiddenAt"] is NSNull else { continue }
            catalog.repos.append(Repo(id: id, path: path, name: named(item["displayName"], or: path)))
        }
        let kept = Set(catalog.repos.map(\.id))
        for item in worktreeItems {
            guard let repoID = item["repoId"] as? String, let path = item["path"] as? String,
                  let branch = item["branch"] as? String else { throw Failure.unreadable }
            guard kept.contains(repoID), item["isMainWorktree"] as? Bool != true else { continue }
            guard !branch.isEmpty else {
                catalog.detached += 1
                continue
            }
            let short = branch.hasPrefix("refs/heads/") ? String(branch.dropFirst(11)) : branch
            catalog.worktrees.append(Worktree(repoID: repoID, path: path, branch: short, name: named(item["displayName"], or: path)))
        }
        return catalog
    }

    /// `result` of a reply that says `ok`; Orca not running and anything
    /// else that isn't a result are told apart.
    private static func result(_ data: Data) throws -> [String: Any] {
        guard let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ok = reply["ok"] as? Bool else { throw Failure.unreadable }
        guard ok else {
            let code = (reply["error"] as? [String: Any])?["code"] as? String
            throw code == "runtime_unavailable" ? Failure.notRunning : Failure.unreadable
        }
        guard let result = reply["result"] as? [String: Any] else { throw Failure.unreadable }
        return result
    }

    private static func items(_ data: Data, _ key: String) throws -> [[String: Any]] {
        guard let items = try result(data)[key] as? [[String: Any]] else { throw Failure.unreadable }
        return items
    }

    /// Orca's name for it, else its folder's.
    private static func named(_ name: Any?, or path: String) -> String {
        if let name = name as? String, !name.trimmingCharacters(in: .whitespaces).isEmpty { return name }
        return (path as NSString).lastPathComponent
    }
}
