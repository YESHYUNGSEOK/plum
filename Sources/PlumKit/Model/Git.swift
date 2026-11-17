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
    public static func run(_ arguments: [String], in directory: String, timeout: TimeInterval = 60) throws -> String {
        let process = Process()
        process.executableURL = executable
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
