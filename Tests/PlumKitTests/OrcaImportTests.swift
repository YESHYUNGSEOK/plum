import XCTest
@testable import PlumKit

/// Orca's repositories and worktrees, read from its CLI's JSON (made-up
/// samples in the shape Orca 1.4 prints; no real data).
final class OrcaImportTests: XCTestCase {
    private func repos(_ items: String) -> Data {
        Data(#"{"id":"local","ok":true,"result":{"repos":[\#(items)]},"_meta":{"runtimeId":"r"}}"#.utf8)
    }

    private func worktrees(_ items: String, truncated: Bool = false) -> Data {
        Data(#"{"id":"local","ok":true,"result":{"worktrees":[\#(items)],"totalCount":0,"truncated":\#(truncated)},"_meta":{"runtimeId":"r"}}"#.utf8)
    }

    func testReposAndWorktreesAreRead() throws {
        let catalog = try OrcaImport.parse(
            repos: repos(#"""
                {"id":"r1","path":"/tmp/a","displayName":"Alpha","kind":"git","badgeColor":"#fff"},
                {"id":"r2","path":"/tmp/b"}
                """#),
            worktrees: worktrees(#"""
                {"id":"w0","repoId":"r1","path":"/tmp/a","branch":"refs/heads/main","isMainWorktree":true,"displayName":"main"},
                {"id":"w1","repoId":"r1","path":"/tmp/a-x","branch":"refs/heads/feat/x","isMainWorktree":false,"displayName":"X work","isArchived":false},
                {"id":"w2","repoId":"r2","path":"/tmp/b-fix","branch":"refs/heads/fix","isMainWorktree":false,"displayName":""}
                """#))
        XCTAssertEqual(catalog.repos, [
            OrcaImport.Repo(id: "r1", path: "/tmp/a", name: "Alpha"),
            OrcaImport.Repo(id: "r2", path: "/tmp/b", name: "b"),
        ])
        XCTAssertEqual(catalog.worktrees, [
            OrcaImport.Worktree(repoID: "r1", path: "/tmp/a-x", branch: "feat/x", name: "X work"),
            OrcaImport.Worktree(repoID: "r2", path: "/tmp/b-fix", branch: "fix", name: "b-fix"),
        ])
        XCTAssertEqual(catalog.detached, 0)
    }

    func testFoldersHiddenReposAndDetachedAreLeftOut() throws {
        let catalog = try OrcaImport.parse(
            repos: repos(#"""
                {"id":"r1","path":"/tmp/a","displayName":"Alpha"},
                {"id":"f","path":"/tmp/notes","displayName":"Notes","kind":"folder"},
                {"id":"h","path":"/tmp/old","displayName":"Old","hiddenAt":1795000000000}
                """#),
            worktrees: worktrees(#"""
                {"id":"w1","repoId":"r1","path":"/tmp/a-d","branch":"","isMainWorktree":false,"displayName":"detached"},
                {"id":"w2","repoId":"h","path":"/tmp/old-x","branch":"refs/heads/x","isMainWorktree":false,"displayName":"x"}
                """#))
        XCTAssertEqual(catalog.repos.map(\.id), ["r1"])
        XCTAssertEqual(catalog.worktrees, [])
        XCTAssertEqual(catalog.detached, 1)
    }

    func testAnEmptyListIsAnEmptyCatalog() throws {
        XCTAssertEqual(try OrcaImport.parse(repos: repos(""), worktrees: worktrees("")), OrcaImport.Catalog())
    }

    func testOrcaNotRunning() {
        let off = Data(#"{"id":"local","ok":false,"error":{"code":"runtime_unavailable","message":"Start the Orca app first."},"_meta":{"runtimeId":null}}"#.utf8)
        XCTAssertThrowsError(try OrcaImport.parse(repos: off, worktrees: off)) {
            XCTAssertEqual($0 as? OrcaImport.Failure, .notRunning)
        }
    }

    // MARK: Running the CLI

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("plum-orca-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
    }

    /// A stand-in for Orca's CLI running `script` (sh).
    private func fakeCLI(_ script: String) throws -> URL {
        let cli = scratch.appendingPathComponent("orca")
        try ("#!/bin/sh\n" + script).write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        return cli
    }

    /// One that prints `repos` for `repo list` and `worktrees` for `worktree list`.
    private func fakeCLI(repos: Data, worktrees: Data) throws -> URL {
        try repos.write(to: scratch.appendingPathComponent("repos.json"))
        try worktrees.write(to: scratch.appendingPathComponent("worktrees.json"))
        return try fakeCLI("""
            case "$1" in
              repo) cat '\(scratch.path)/repos.json';;
              worktree) cat '\(scratch.path)/worktrees.json';;
            esac
            """)
    }

    /// A repository with one commit and a worktree on `feat/x`.
    private func gitRepo() throws -> (repo: String, worktree: String) {
        let repo = scratch.appendingPathComponent("repo").path
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        try Git.run(["init", "-q", "-b", "main"], in: repo)
        try Git.run(["config", "user.email", "t@e"], in: repo)
        try Git.run(["config", "user.name", "T"], in: repo)
        try "hi".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
        try Git.run(["add", "."], in: repo)
        try Git.run(["commit", "-qm", "init"], in: repo)
        let worktree = scratch.appendingPathComponent("repo-x").path
        try Git.run(["worktree", "add", "-q", "-b", "feat/x", worktree], in: repo)
        return (repo, worktree)
    }

    func testPathsAreCheckedOnDisk() async throws {
        let (repo, worktree) = try gitRepo()
        let root = try XCTUnwrap(Git.repositoryRoot(of: repo))
        let cli = try fakeCLI(
            repos: repos(#"""
                {"id":"r1","path":"\#(repo)","displayName":"Repo"},
                {"id":"gone","path":"/nonexistent/repo","displayName":"Gone"}
                """#),
            worktrees: worktrees(#"""
                {"id":"w1","repoId":"r1","path":"\#(worktree)","branch":"refs/heads/feat/x","isMainWorktree":false,"displayName":"X"},
                {"id":"w2","repoId":"r1","path":"\#(repo)-deleted","branch":"refs/heads/old","isMainWorktree":false,"displayName":"Old"},
                {"id":"w3","repoId":"gone","path":"/nonexistent/repo-y","branch":"refs/heads/y","isMainWorktree":false,"displayName":"Y"}
                """#))
        let catalog = try await OrcaImport.load(cli: cli)
        XCTAssertEqual(catalog.repos.map(\.path), [root])
        XCTAssertEqual(catalog.worktrees.map(\.path), [worktree])
        XCTAssertEqual(catalog.missing, 1, "a deleted worktree of a repository still there")
    }

    func testAHungCLIGivesUp() async throws {
        let cli = try fakeCLI("sleep 5")
        let started = Date()
        do {
            _ = try await OrcaImport.load(cli: cli, timeout: 0.5)
            XCTFail("a CLI that never answers")
        } catch {
            XCTAssertEqual(error as? OrcaImport.Failure, .unreadable)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testNotRunningComesThrough() async throws {
        let cli = try fakeCLI("""
            echo '{"id":"local","ok":false,"error":{"code":"runtime_unavailable","message":"Start the Orca app first."},"_meta":{"runtimeId":null}}'
            exit 1
            """)
        do {
            _ = try await OrcaImport.load(cli: cli)
            XCTFail("Orca isn't running")
        } catch {
            XCTAssertEqual(error as? OrcaImport.Failure, .notRunning)
        }
    }

    // MARK: Into Plum

    @MainActor
    private func model() -> AppModel {
        AppModel(store: Store(directory: scratch.appendingPathComponent("state")))
    }

    private func addWorktree(_ repo: String, _ folder: String, branch: String) throws -> String {
        let path = scratch.appendingPathComponent(folder).path
        try Git.run(["worktree", "add", "-q", "-b", branch, path], in: repo)
        return path
    }

    @MainActor
    func testACatalogBecomesProjectsAndWorkspaces() async throws {
        let (repo, worktree) = try gitRepo()
        _ = try addWorktree(repo, "by-hand", branch: "feat/y")
        let root = try XCTUnwrap(Git.repositoryRoot(of: repo))
        let catalog = OrcaImport.Catalog(
            repos: [OrcaImport.Repo(id: "r1", path: root, name: "Alpha")],
            worktrees: [OrcaImport.Worktree(repoID: "r1", path: worktree, branch: "feat/x", name: "Orca name")])
        let model = model()

        let result = await model.importFromOrca(catalog)
        XCTAssertEqual(model.state.projects.map(\.name), ["Alpha"])
        XCTAssertEqual(model.state.workspaces.map(\.name), ["Orca name", "by-hand"], "the rest of git's worktrees come with it")
        XCTAssertEqual(model.state.workspaces.map(\.branch), ["feat/x", "feat/y"])
        XCTAssertEqual(result, OrcaImport.Result(projects: 1, workspaces: 2))

        let again = await model.importFromOrca(catalog)
        XCTAssertEqual(again, OrcaImport.Result())
        XCTAssertEqual(model.state.workspaces.count, 2)
    }

    @MainActor
    func testAnExistingProjectKeepsItsName() async throws {
        let (repo, _) = try gitRepo()
        let root = try XCTUnwrap(Git.repositoryRoot(of: repo))
        let model = model()
        model.addProject(at: repo)
        let deadline = Date().addingTimeInterval(5)
        while model.state.workspaces.isEmpty, Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        var project = try XCTUnwrap(model.state.projects.first)
        project.name = "mine"
        model.update(project)
        let later = try addWorktree(repo, "later", branch: "feat/z")

        let result = await model.importFromOrca(OrcaImport.Catalog(
            repos: [OrcaImport.Repo(id: "r1", path: root, name: "Alpha")],
            worktrees: [OrcaImport.Worktree(repoID: "r1", path: later, branch: "feat/z", name: "Z")]))
        XCTAssertEqual(model.state.projects.map(\.name), ["mine"])
        XCTAssertTrue(model.state.workspaces.contains { $0.name == "Z" && $0.branch == "feat/z" })
        XCTAssertEqual(result, OrcaImport.Result(projects: 0, workspaces: 1))
    }

    @MainActor
    func testNamesThatClashGetASuffix() async throws {
        let (repo, worktree) = try gitRepo()
        let other = try addWorktree(repo, "repo-y", branch: "feat/y")
        let root = try XCTUnwrap(Git.repositoryRoot(of: repo))
        let model = model()
        await model.importFromOrca(OrcaImport.Catalog(
            repos: [OrcaImport.Repo(id: "r1", path: root, name: "Alpha")],
            worktrees: [OrcaImport.Worktree(repoID: "r1", path: worktree, branch: "feat/x", name: "X"),
                        OrcaImport.Worktree(repoID: "r1", path: other, branch: "feat/y", name: "X")]))
        XCTAssertEqual(model.state.workspaces.map(\.name), ["X", "X-2"])
    }

    func testOutputPlumDoesNotKnowImportsNothing() {
        let unknown: [(Data, Data)] = [
            (Data("not json".utf8), worktrees("")),
            (Data(#"{"ok":true,"result":{}}"#.utf8), worktrees("")),
            (Data(#"{"ok":false,"error":{"code":"other"}}"#.utf8), worktrees("")),
            (repos(""), worktrees("", truncated: true)),
        ]
        for (repos, worktrees) in unknown {
            XCTAssertThrowsError(try OrcaImport.parse(repos: repos, worktrees: worktrees)) {
                XCTAssertEqual($0 as? OrcaImport.Failure, .unreadable, String(decoding: repos, as: UTF8.self))
            }
        }
    }
}
