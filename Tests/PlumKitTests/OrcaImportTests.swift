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
