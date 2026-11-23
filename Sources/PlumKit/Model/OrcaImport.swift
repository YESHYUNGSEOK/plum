import Foundation

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
