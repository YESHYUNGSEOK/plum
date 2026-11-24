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
    public static func run(_ arguments: [String], in directory: String, timeout: TimeInterval = 60, using tool: URL? = nil,
                           input: String? = nil) throws -> String {
        let disabled = tool == nil ? disabledConfiguredCommands(in: directory) : []
        return try execute(disabled + arguments, in: directory, timeout: timeout, using: tool, input: input)
    }

    private static func disabledConfiguredCommands(in directory: String) -> [String] {
        let keys = (try? execute(["config", "--includes", "--name-only", "--get-regexp",
                                  "^(filter\\..*\\.(clean|smudge|process)|merge\\..*\\.driver)$"],
                                 in: directory, timeout: 5)) ?? ""
        return Set(keys.split(separator: "\n")).sorted().flatMap { ["-c", "\($0)="] }
    }

    private static func execute(_ arguments: [String], in directory: String, timeout: TimeInterval,
                                using tool: URL? = nil, input: String? = nil) throws -> String {
        let process = Process()
        process.executableURL = tool ?? executable
        process.arguments = tool == nil
            ? ["-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "-c", "credential.helper="] + arguments
            : arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0" // never hang waiting for a password
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_SSH_COMMAND"] = "/usr/bin/ssh -o BatchMode=yes"
        environment["GIT_ALLOW_PROTOCOL"] = "https:ssh:file"
        environment["GIT_ASKPASS"] = "/usr/bin/false"
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let stdin = input.map { _ in Pipe() }
        process.standardInput = stdin ?? FileHandle.nullDevice

        // waitUntilExit() spins the run loop and can return ~100 ms late.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { throw GitError(message: String(localized: "git을 실행할 수 없습니다: \(error.localizedDescription)")) }
        if let stdin, let input {
            let writer = stdin.fileHandleForWriting
            _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1) // git exiting early must not kill the app
            DispatchQueue.global().async { try? writer.write(contentsOf: Data(input.utf8)); try? writer.close() }
        }

        // Drain both pipes while git runs, or a chatty command fills one and stalls.
        var errorOutput = (data: Data(), exceeded: false)
        let errorReader = DispatchQueue(label: "plum.git.stderr")
        errorReader.async { errorOutput = readBounded(stderr.fileHandleForReading, limit: 1 << 20) }
        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let output = readBounded(stdout.fileHandleForReading, limit: 64 << 20)
        exited.wait()
        killer.cancel()
        errorReader.sync {}

        guard !output.exceeded, !errorOutput.exceeded else {
            throw GitError(message: String(localized: "git 출력이 너무 큽니다"))
        }
        let text = String(decoding: output.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            let detail = String(decoding: errorOutput.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let reason = process.terminationReason == .uncaughtSignal ? String(localized: "시간 초과 또는 중단됨") : detail
            throw GitError(message: reason.isEmpty ? String(localized: "git \(arguments.first ?? "") 실패") : reason)
        }
        return text
    }

    private static func readBounded(_ handle: FileHandle, limit: Int) -> (data: Data, exceeded: Bool) {
        var data = Data()
        var exceeded = false
        while true {
            let chunk = handle.readData(ofLength: 1 << 16)
            if chunk.isEmpty { break }
            let remaining = max(0, limit - data.count)
            data.append(contentsOf: chunk.prefix(remaining))
            if chunk.count > remaining { exceeded = true }
        }
        return (data, exceeded)
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
        guard let numstat = try? run(["diff", "--no-ext-diff", "--no-textconv", "HEAD", "--numstat"], in: checkout, timeout: 15),
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
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true, let size = values.fileSize, size <= 1 << 20,
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
        _ = try? run(["fetch", "--quiet", "--upload-pack=git-upload-pack", "origin"], in: repository, timeout: 20)
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
    /// Includes untracked and ignored files, which removing the worktree would delete.
    public static func uncommittedChanges(in worktree: String) throws -> [String] {
        try run(["status", "--porcelain", "--untracked-files=all", "--ignored=matching"], in: worktree)
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

    /// A local branch and the commit it pointed at.
    public struct Branch: Equatable, Sendable {
        public var name: String
        public var head: String
    }

    /// Deletes a local branch only when its work is already in a base, as Orca
    /// does after removing a worktree: `git branch -d`, then Orca's checks for
    /// squash and rebase merges. Returns the branch when it was kept.
    public static func deleteBranchIfMerged(_ branch: String, in repository: String) -> Branch? {
        guard let head = try? run(["rev-parse", "--verify", "--quiet", "refs/heads/\(branch)^{commit}"], in: repository),
              !worktrees(in: repository).contains(where: { $0.branch == branch }) else { return nil }
        if (try? run(["branch", "-d", "--", branch], in: repository)) != nil { return nil }
        if isMerged(branch, in: repository), (try? deleteBranch(branch, at: head, in: repository)) != nil { return nil }
        return Branch(name: branch, head: head)
    }

    /// Deletes `branch` whatever it holds, but only while it still points at `head`.
    public static func deleteBranch(_ branch: String, at head: String, in repository: String) throws {
        guard !worktrees(in: repository).contains(where: { $0.branch == branch }) else {
            throw GitError(message: String(localized: "브랜치 \(branch)가 다른 워크트리에 체크아웃되어 있습니다."))
        }
        do { try run(["update-ref", "-d", "refs/heads/\(branch)", head], in: repository) } catch {
            throw GitError(message: String(localized: "브랜치 \(branch)가 그 사이 바뀌었습니다. 확인한 뒤 지우세요."))
        }
        _ = try? run(["config", "--remove-section", "branch.\(branch)"], in: repository)
    }

    /// Orca's test: is the branch's work in its base (`branch.<name>.base`), the
    /// remote's default branch (fetched first) or HEAD, merged, squashed or rebased?
    static func isMerged(_ branch: String, in repository: String) -> Bool {
        var targets: [String] = []
        for target in [try? run(["config", "--get", "branch.\(branch).base"], in: repository),
                       try? run(["symbolic-ref", "--quiet", "refs/remotes/origin/HEAD"], in: repository), "HEAD"] {
            if let target, !target.isEmpty, !target.hasPrefix("-"), !targets.contains(target) { targets.append(target) }
        }
        let ref = "refs/heads/\(branch)"
        let local = targets.filter { $0 == "HEAD" || $0.hasPrefix("refs/heads/") || $0.hasPrefix("refs/tags/") }
        return holds(ref, in: local, repository)
            || holds(ref, in: refreshed(targets.filter { !local.contains($0) }, in: repository), repository)
    }

    /// Fetches each remote-tracking target from its remote; only those that came in count.
    private static func refreshed(_ targets: [String], in repository: String) -> [String] {
        let remotes = ((try? run(["remote"], in: repository)) ?? "").split(separator: "\n").map(String.init)
            .filter { !$0.hasPrefix("-") }.sorted { $0.count > $1.count }
        return targets.filter { target in
            guard let remote = remotes.first(where: { target.hasPrefix("refs/remotes/\($0)/") }) else { return false }
            let specs = ((try? run(["config", "--get-all", "remote.\(remote).fetch"], in: repository)) ?? "").split(separator: "\n")
            guard let source = specs.lazy.compactMap({ source(of: target, refspec: String($0)) }).first else { return false }
            return (try? run(["fetch", "--quiet", "--no-tags", "--upload-pack=git-upload-pack", remote, "+\(source):\(target)"], in: repository, timeout: 20)) != nil
        }
    }

    /// The remote ref a fetch refspec maps onto `target`, e.g. refs/heads/main for
    /// refs/remotes/origin/main under `+refs/heads/*:refs/remotes/origin/*`.
    private static func source(of target: String, refspec: String) -> String? {
        let spec = refspec.hasPrefix("+") ? String(refspec.dropFirst()) : refspec
        let sides = spec.split(separator: ":", maxSplits: 1).map(String.init)
        guard sides.count == 2, !spec.hasPrefix("^") else { return nil }
        let (from, to) = (sides[0], sides[1])
        guard let star = to.firstIndex(of: "*") else { return to == target ? from : nil }
        let (prefix, suffix) = (String(to[..<star]), String(to[to.index(after: star)...]))
        guard target.hasPrefix(prefix), target.hasSuffix(suffix), target.count >= prefix.count + suffix.count else { return nil }
        return from.replacingOccurrences(of: "*", with: String(target.dropFirst(prefix.count).dropLast(suffix.count)))
    }

    /// Whether any of `targets` already has the work on `ref`.
    private static func holds(_ ref: String, in targets: [String], _ repository: String) -> Bool {
        guard let branchCommit = try? run(["rev-parse", "--verify", "--quiet", "\(ref)^{commit}"], in: repository) else { return false }
        for target in targets {
            guard let commit = try? run(["rev-parse", "--verify", "--quiet", "\(target)^{commit}"], in: repository), !commit.isEmpty,
                  commit != branchCommit,
                  let base = try? run(["merge-base", commit, ref], in: repository), !base.isEmpty else { continue }
            let files = (try? run(["diff", "--no-ext-diff", "--no-textconv", "--name-only", "--no-renames", base, ref], in: repository)) ?? ""
            if files.isEmpty, (try? run(["merge-base", "--is-ancestor", ref, commit], in: repository)) == nil { continue }
            if mergeChangesNothing(ref, into: commit, repository) { return true }
            let merges = Int((try? run(["rev-list", "--right-only", "--merges", "--count", "\(commit)...\(ref)"], in: repository)) ?? "") ?? 0
            if merges > 0 {
                if squashed(ref, into: commit, base: base, files: files, repository) { return true }
            } else if let cherry = try? run(["cherry", commit, ref], in: repository), !cherry.isEmpty,
                      cherry.split(separator: "\n").allSatisfy({ $0.hasPrefix("-") }) {
                return true // every commit is in the target as a patch: rebased
            }
        }
        return false
    }

    /// Merging `ref` into `commit` would leave its tree as it is.
    private static func mergeChangesNothing(_ ref: String, into commit: String, _ repository: String) -> Bool {
        guard let merged = try? run(["merge-tree", "--write-tree", commit, ref], in: repository),
              let tree = try? run(["rev-parse", "--verify", "--quiet", "\(commit)^{tree}"], in: repository) else { return false }
        return merged.split(separator: "\n").first.map(String.init) == tree
    }

    /// A commit on the target since `base` that is the branch's whole diff as one patch.
    private static func squashed(_ ref: String, into commit: String, base: String, files: String, _ repository: String) -> Bool {
        let log = (try? run(["log", "--no-show-signature", "--format=%x00%H %P", "--name-only", "--no-renames",
                             "--ancestry-path", "--max-count=201", "\(base)..\(commit)"], in: repository)) ?? ""
        let entries = log.split(separator: "\0").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !entries.isEmpty, entries.count <= 200 else { return false }
        func fileSet(_ text: some StringProtocol) -> [String] {
            text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.sorted()
        }
        let wanted = fileSet(files)
        let candidates = entries.compactMap { entry -> String? in
            let lines = entry.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            let ids = lines[0].trimmingCharacters(in: .whitespaces).split(separator: " ")
            guard let hash = ids.first else { return nil }
            return ids.count > 2 || fileSet(lines.count > 1 ? lines[1] : "") == wanted ? String(hash) : nil
        }
        guard let patch = patchID(["diff", "--no-ext-diff", "--no-textconv", base, ref], repository) else { return false }
        return candidates.contains { patchID(["show", "--no-ext-diff", "--no-textconv", "--format=", $0], repository) == patch && mergeChangesNothing(ref, into: $0, repository) }
    }

    private static func patchID(_ diff: [String], _ repository: String) -> String? {
        guard let text = try? run(diff, in: repository), !text.isEmpty,
              let id = try? run(["patch-id", "--stable"], in: repository, input: text + "\n") else { return nil }
        return id.split(separator: " ").first.map(String.init)
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

        /// What changed since the last look, worth telling someone not watching.
        public func news(since before: PullRequest?) -> String? {
            guard let before, before.number == number else {
                return state == .open || state == .draft ? String(localized: "PR #\(number)이 열렸습니다.") : nil
            }
            switch state {
            case .merged where before.state != .merged: return String(localized: "PR #\(number)이 머지되었습니다.")
            case .closed where before.state != .closed: return String(localized: "PR #\(number)이 닫혔습니다.")
            default: break
            }
            guard checks != before.checks else { return nil }
            switch checks {
            case .passing: return String(localized: "PR #\(number)의 체크를 모두 통과했습니다.")
            case .failing: return String(localized: "PR #\(number)의 체크가 실패했습니다.")
            case .none, .pending: return nil
            }
        }
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
                  let url = (item["url"] as? String).flatMap(URL.init(string:)),
                  url.scheme == "https", url.host == "github.com" else { continue }
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
