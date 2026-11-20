import Foundation

public struct GitError: LocalizedError, Equatable {
    public let message: String
    public var errorDescription: String? { message }
}

/// Thin wrapper over the `git` command line. Blocking: call off the main thread.
public enum Git {
    public struct Worktree: Equatable {
        public var path: String
        public var branch: String?
    }

    /// /usr/bin/git is a shim that looks up the real binary on every call,
    /// which costs tens of milliseconds each time. Look it up once.
    private static let executable: URL = {
        let lookup = Process()
        lookup.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        lookup.arguments = ["-f", "git"]
        let pipe = Pipe()
        lookup.standardOutput = pipe
        lookup.standardError = FileHandle.nullDevice
        if (try? lookup.run()) != nil {
            let path = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            lookup.waitUntilExit()
            if lookup.terminationStatus == 0, FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return URL(fileURLWithPath: "/usr/bin/git")
    }()

    /// Runs git in `directory` and returns trimmed stdout. Throws with git's
    /// own error text when it exits non-zero or takes longer than `timeout`.
    @discardableResult
    public static func run(_ arguments: [String], in directory: String, timeout: TimeInterval = 60, using tool: URL? = nil) throws -> String {
        let process = Process()
        process.executableURL = tool ?? executable
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0" // never hang waiting for a password
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice

        // waitUntilExit() spins the run loop and can return ~100 ms late.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { throw GitError(message: String(localized: "git을 실행할 수 없습니다: \(error.localizedDescription)")) }

        // Drain both pipes while git runs, or a chatty command fills one and stalls.
        var errorData = Data()
        let errorReader = DispatchQueue(label: "plum.git.stderr")
        errorReader.async { errorData = stderr.fileHandleForReading.readDataToEndOfFile() }
        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        exited.wait()
        killer.cancel()
        errorReader.sync {}

        let text = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            let detail = String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let reason = process.terminationReason == .uncaughtSignal ? String(localized: "시간 초과 또는 중단됨") : detail
            throw GitError(message: reason.isEmpty ? String(localized: "git \(arguments.first ?? "") 실패") : reason)
        }
        return text
    }

    /// The top-level directory of the repository containing `path`, if any.
    public static func repositoryRoot(of path: String) -> String? {
        try? run(["rev-parse", "--show-toplevel"], in: path)
    }

    /// The ref new branches start from when the project doesn't say:
    /// the remote's default branch, else whatever is checked out.
    public static func defaultBase(in repository: String) -> String {
        if let remoteHead = try? run(["symbolic-ref", "--short", "refs/remotes/origin/HEAD"], in: repository), !remoteHead.isEmpty {
            return remoteHead
        }
        if let current = try? run(["branch", "--show-current"], in: repository), !current.isEmpty { return current }
        return "HEAD"
    }

    /// Lines added and removed since the last commit, new files counted in full.
    public struct Changes: Equatable, Sendable {
        public var added = 0
        public var removed = 0
        public var isEmpty: Bool { added == 0 && removed == 0 }
    }

    /// What changed in a checkout since its last commit; nil when it can't
    /// tell (no commit yet, not a repository).
    public static func changes(in checkout: String) -> Changes? {
        guard let numstat = try? run(["diff", "HEAD", "--numstat"], in: checkout, timeout: 15),
              let untracked = try? run(["ls-files", "--others", "--exclude-standard", "-z"], in: checkout, timeout: 15)
        else { return nil }
        var changes = Changes()
        for line in numstat.split(separator: "\n") {
            let fields = line.split(separator: "\t", maxSplits: 2)
            guard fields.count == 3 else { continue }
            changes.added += Int(fields[0]) ?? 0 // "-" for a binary file
            changes.removed += Int(fields[1]) ?? 0
        }
        // New files count as all added, as `git diff` shows them once staged.
        // ponytail: only the first 200 new text files under 1 MB are read.
        for path in untracked.split(separator: "\0").prefix(200) {
            let url = URL(fileURLWithPath: checkout).appendingPathComponent(String(path))
            guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= 1 << 20,
                  let data = try? Data(contentsOf: url), !data.prefix(8000).contains(0) else { continue }
            changes.added += data.reduce(0) { $1 == 10 ? $0 + 1 : $0 } + (data.last.map { $0 == 10 ? 0 : 1 } ?? 0)
        }
        return changes
    }

    /// The branch a checkout is on, read from its HEAD; nil when detached.
    public static func currentBranch(in checkout: String) -> String? {
        guard let head = try? String(contentsOfFile: checkout + "/.git/HEAD", encoding: .utf8),
              head.hasPrefix("ref: refs/heads/") else { return nil }
        return head.dropFirst("ref: refs/heads/".count).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func branches(in repository: String) -> [String] {
        let output = (try? run(["for-each-ref", "--format=%(refname:short)", "refs/heads", "refs/remotes"], in: repository)) ?? ""
        return output.split(separator: "\n").map(String.init).filter { !$0.hasSuffix("/HEAD") }
    }

    public static func branchExists(_ branch: String, in repository: String) -> Bool {
        (try? run(["show-ref", "--verify", "--quiet", "refs/heads/\(branch)"], in: repository)) != nil
    }

    public static func isValidBranchName(_ name: String) -> Bool {
        guard !name.isEmpty, !name.hasPrefix("-") else { return false }
        return (try? run(["check-ref-format", "--branch", name], in: NSTemporaryDirectory())) != nil
    }

    /// Best effort. A failed fetch (offline, no remote) is not an error.
    public static func fetch(in repository: String) {
        _ = try? run(["fetch", "--quiet", "origin"], in: repository, timeout: 20)
    }

    public static func worktrees(in repository: String) -> [Worktree] {
        let output = (try? run(["worktree", "list", "--porcelain"], in: repository)) ?? ""
        var result: [Worktree] = []
        for line in output.split(separator: "\n") {
            if line.hasPrefix("worktree ") {
                result.append(Worktree(path: String(line.dropFirst(9)), branch: nil))
            } else if line.hasPrefix("branch refs/heads/"), !result.isEmpty {
                result[result.count - 1].branch = String(line.dropFirst(18))
            }
        }
        return result
    }

    /// Creates a worktree at `path`. With `newBranchFrom` set, `branch` is
    /// created there; otherwise `branch` must exist (locally or on a remote).
    public static func addWorktree(repository: String, path: String, branch: String, newBranchFrom base: String?) throws {
        if let base {
            // --no-track: a feature branch must not get the base as upstream.
            try run(["worktree", "add", "--no-track", "-b", branch, path, base], in: repository, timeout: 300)
        } else if branchExists(branch, in: repository) {
            try run(["worktree", "add", path, branch], in: repository, timeout: 300)
        } else {
            // A remote branch such as "origin/feature": track it under its short name.
            let local = branch.split(separator: "/", maxSplits: 1).last.map(String.init) ?? branch
            try run(["worktree", "add", "--track", "-b", local, path, branch], in: repository, timeout: 300)
        }
    }

    /// Uncommitted work in a worktree, one `git status --porcelain` line each.
    /// Includes untracked files, which removing the worktree would delete.
    public static func uncommittedChanges(in worktree: String) throws -> [String] {
        try run(["status", "--porcelain", "--untracked-files=all"], in: worktree)
            .split(separator: "\n").map(String.init)
    }

    /// Commits on `branch` that exist on no remote: deleting the branch loses them.
    public static func unpushedCommits(on branch: String, in repository: String) -> [String] {
        let output = (try? run(["log", "--oneline", "--max-count=50", branch, "--not", "--remotes"], in: repository)) ?? ""
        return output.split(separator: "\n").map(String.init)
    }

    public static func removeWorktree(repository: String, path: String, force: Bool) throws {
        try run(["worktree", "remove"] + (force ? ["--force"] : []) + [path], in: repository, timeout: 300)
    }

    public static func deleteBranch(_ branch: String, in repository: String) throws {
        try run(["branch", "-D", branch], in: repository)
    }
}

/// Pull requests on GitHub, through the `gh` command line when it is
/// installed and signed in. Anything else (no gh, no GitHub remote, offline)
/// just means no pull requests are shown.
public enum GitHub {
    public struct PullRequest: Equatable, Sendable {
        public enum State: Sendable { case open, draft, merged, closed }
        public enum Checks: Sendable { case none, pending, passing, failing }
        public let number: Int
        public let state: State
        public let checks: Checks
        public let url: URL
    }

    /// Apps started from Finder don't get the shell's PATH.
    private static let executable: URL? = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"]
        .map { URL(fileURLWithPath: $0) }
        .first { FileManager.default.isExecutableFile(atPath: $0.path) }

    /// The newest pull request from each of the repository's own branches, by branch name.
    public static func pullRequests(in repository: String) -> [String: PullRequest]? {
        guard let gh = executable,
              let output = try? Git.run(
                  ["pr", "list", "--state", "all", "--limit", "100",
                   "--json", "number,state,isDraft,url,headRefName,isCrossRepository,statusCheckRollup"],
                  in: repository, timeout: 30, using: gh)
        else { return nil }
        return parse(Data(output.utf8))
    }

    static func parse(_ json: Data) -> [String: PullRequest]? {
        guard let list = try? JSONSerialization.jsonObject(with: json) as? [[String: Any]] else { return nil }
        var found: [String: PullRequest] = [:]
        for item in list { // newest first
            guard let branch = item["headRefName"] as? String, found[branch] == nil,
                  item["isCrossRepository"] as? Bool != true, // a fork's branch of the same name isn't ours
                  let number = item["number"] as? Int,
                  let url = (item["url"] as? String).flatMap(URL.init(string:)) else { continue }
            let state: PullRequest.State = switch item["state"] as? String {
            case "MERGED": .merged
            case "CLOSED": .closed
            default: item["isDraft"] as? Bool == true ? .draft : .open
            }
            found[branch] = PullRequest(number: number, state: state, checks: checks(item["statusCheckRollup"] as? [[String: Any]] ?? []), url: url)
        }
        return found
    }

    /// One state for all of a pull request's checks: any failure fails them,
    /// then any still running.
    static func checks(_ rollup: [[String: Any]]) -> PullRequest.Checks {
        guard !rollup.isEmpty else { return .none }
        let failures: Set = ["FAILURE", "ERROR", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE"]
        var running = false
        for check in rollup {
            // Check runs have a conclusion once done; status contexts a state.
            let result = (check["conclusion"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? check["state"] as? String ?? ""
            if failures.contains(result) { return .failing }
            if result.isEmpty || result == "PENDING" || result == "EXPECTED" { running = true }
        }
        return running ? .pending : .passing
    }
}
