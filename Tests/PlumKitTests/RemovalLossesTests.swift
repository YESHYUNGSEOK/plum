import XCTest
@testable import PlumKit

/// What the archive and delete questions list: work apart from ignored files,
/// and ignored files an install or build makes again apart from the rest.
@MainActor
final class RemovalLossesTests: XCTestCase {
    private var repo: URL!

    override func setUp() async throws {
        repo = FileManager.default.temporaryDirectory.appendingPathComponent("plum-losses-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try Git.run(["init", "-q", "-b", "main"], in: repo.path)
        try write("node_modules/\n.next/\n*.tsbuildinfo\n.env*\n", to: ".gitignore")
        try write("export const a = 1\n", to: "src/a.ts")
        try Git.run(["add", "."], in: repo.path)
        try Git.run(["-c", "user.email=t@e", "-c", "user.name=T", "commit", "-qm", "init"], in: repo.path)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: repo)
    }

    private func write(_ text: String, to path: String) throws {
        let file = repo.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
    }

    private func check() throws -> WorkspaceService.RemovalCheck {
        var check = WorkspaceService.RemovalCheck()
        check.uncommitted = try Git.uncommittedChanges(in: repo.path)
        return check
    }

    private let workspace = Workspace(projectID: UUID(), name: "qa", branch: "qa", path: "/nonexistent")

    func testOnlyFilesAnInstallAndABuildMake() throws {
        try write("{}", to: "node_modules/left-pad/package.json")
        try write("x", to: "apps/web/.next/cache/a")
        try write("x", to: "apps/web/node_modules/b/index.js")
        try write("x", to: "apps/web/tsconfig.tsbuildinfo")
        let check = try check()
        XCTAssertEqual(check.changes, [])
        XCTAssertEqual(check.ignored.kept, [])
        // However git lists them (a folder as one line, or file by file), all four places are there and none is kept apart.
        for place in ["node_modules/", "apps/web/.next/", "apps/web/node_modules/", "apps/web/tsconfig.tsbuildinfo"] {
            XCTAssertTrue(check.ignored.rebuildable.contains { $0.hasPrefix(place) }, place)
        }
        XCTAssertFalse(check.hasLosses)
        let question = AppActions.archiveQuestion(workspace, check)
        XCTAssertEqual(question.action, String(localized: "아카이브"))
        XCTAssertFalse(question.destructive)
        XCTAssertEqual(question.sections.map(\.title), [String(localized: "함께 삭제되는 무시 파일")], "no \"uncommitted changes\" section at all")
        XCTAssertEqual(question.sections[0].lines, [], "folded: a count, not a list")
        XCTAssertEqual(question.sections[0].folded, check.ignored.rebuildable)
    }

    func testAChangedFileAndANewOne() throws {
        try write("export const a = 2\n", to: "src/a.ts")
        try write("new\n", to: "src/b.ts")
        let check = try check()
        XCTAssertEqual(check.changes.map { String($0.split(separator: " ").last ?? "") }, ["src/a.ts", "src/b.ts"])
        XCTAssertTrue(check.hasLosses)
        let question = AppActions.archiveQuestion(workspace, check)
        XCTAssertEqual(question.action, String(localized: "변경을 버리고 아카이브"))
        XCTAssertTrue(question.destructive)
        XCTAssertEqual(question.sections.map(\.title), [String(localized: "커밋하지 않은 변경")])
        XCTAssertEqual(question.sections[0].lines.count, 2)
    }

    func testAnIgnoredFileNothingMakesAgain() throws {
        try write("SECRET=1\n", to: ".env.local")
        try write("{}", to: "node_modules/left-pad/package.json")
        let check = try check()
        XCTAssertEqual(check.changes, [])
        XCTAssertEqual(check.ignored.kept, [".env.local"])
        XCTAssertFalse(check.ignored.rebuildable.isEmpty)
        XCTAssertTrue(check.ignored.rebuildable.allSatisfy { $0.hasPrefix("node_modules/") })
        XCTAssertTrue(check.hasLosses)
        let question = AppActions.archiveQuestion(workspace, check)
        XCTAssertEqual(question.sections.map(\.title), [String(localized: "함께 삭제되는 무시 파일")])
        XCTAssertEqual(question.sections[0].lines, [".env.local"], "shown, not folded")
        XCTAssertEqual(question.action, String(localized: "무시 파일을 지우고 아카이브"))
        XCTAssertTrue(question.destructive, "Return doesn't take it")
    }

    func testAStateThatCouldNotBeReadIsNotClean() {
        var check = WorkspaceService.RemovalCheck()
        check.uncommitted = ["상태를 확인하지 못했습니다: boom"]
        XCTAssertEqual(check.changes.count, 1)
        XCTAssertTrue(check.hasLosses)
    }

    func testNamesThatFoldAway() {
        for path in ["node_modules/", "packages/ui/node_modules/", "apps/dash-next/.next/", "apps/dash-next/next-env.d.ts",
                     "apps/dash-next/tsconfig.tsbuildinfo", "apps/dash-next/src/generated/prisma/", "dist/", "build/", "\"sp ace/node_modules/\""] {
            XCTAssertTrue(WorkspaceService.RemovalCheck.isRebuildable(path), path)
        }
        for path in [".env.local", "apps/web/.env", "notes.txt", "secrets/key.pem", "builds.md"] {
            XCTAssertFalse(WorkspaceService.RemovalCheck.isRebuildable(path), path)
        }
    }
}
