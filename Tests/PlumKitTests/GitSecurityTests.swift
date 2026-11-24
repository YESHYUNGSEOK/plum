import XCTest
@testable import PlumKit

final class GitSecurityTests: XCTestCase {
    func testLargeCommandOutputIsRejected() {
        let shell = URL(fileURLWithPath: "/bin/sh")

        XCTAssertThrowsError(try Git.run(["-c", "/usr/bin/head -c 67108865 /dev/zero"],
                                        in: NSTemporaryDirectory(), timeout: 10, using: shell))
    }

    func testLargeErrorOutputIsBounded() {
        let shell = URL(fileURLWithPath: "/bin/sh")

        XCTAssertThrowsError(try Git.run(["-c", "/usr/bin/head -c 1048577 /dev/zero >&2; exit 1"],
                                        in: NSTemporaryDirectory(), timeout: 10, using: shell)) { error in
            XCTAssertLessThan(String(describing: error).utf8.count, 1000)
        }
    }

    func testUntrackedSymlinkToPipeIsNotRead() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("plum-git-security-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Git.run(["init", "-q"], in: directory.path)
        try "ready".write(to: directory.appendingPathComponent("README"), atomically: true, encoding: .utf8)
        try Git.run(["add", "README"], in: directory.path)
        try Git.run(["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-qm", "initial"], in: directory.path)
        let pipe = directory.appendingPathComponent("pipe")
        XCTAssertEqual(mkfifo(pipe.path, 0o600), 0)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("link"), withDestinationURL: pipe)

        XCTAssertEqual(Git.changes(in: directory.path)?.added, 0)
        XCTAssertEqual(try Diff.files(in: directory.path, scope: .uncommitted, base: "main").first(where: { $0.path == "link" })?.isBinary, true)
    }

    func testRepositoryConfigCannotRunFsmonitorDuringStatus() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("plum-git-security-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Git.run(["init", "-q"], in: directory.path)
        let marker = directory.appendingPathComponent("fsmonitor-ran")
        try Git.run(["config", "core.fsmonitor", "touch \(marker.path)"], in: directory.path)

        _ = try Git.run(["status", "--porcelain"], in: directory.path)

        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testRepositoryConfigCannotRunAnExternalDiffProgram() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("plum-git-security-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Git.run(["init", "-q"], in: directory.path)
        let file = directory.appendingPathComponent("README")
        try "before".write(to: file, atomically: true, encoding: .utf8)
        try Git.run(["add", "README"], in: directory.path)
        try Git.run(["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-qm", "initial"], in: directory.path)
        try "after".write(to: file, atomically: true, encoding: .utf8)
        let marker = directory.appendingPathComponent("diff-ran")
        try Git.run(["config", "diff.external", "touch \(marker.path)"], in: directory.path)

        XCTAssertEqual(Git.changes(in: directory.path)?.added, 1)

        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testRepositoryHookCannotRunDuringWorktreeCreation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("plum-git-security-\(UUID().uuidString)")
        let repository = directory.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Git.run(["init", "-q", "-b", "main"], in: repository.path)
        try "ready".write(to: repository.appendingPathComponent("README"), atomically: true, encoding: .utf8)
        try Git.run(["add", "README"], in: repository.path)
        try Git.run(["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-qm", "initial"], in: repository.path)
        let marker = directory.appendingPathComponent("hook-ran")
        let hook = repository.appendingPathComponent(".git/hooks/post-checkout")
        try "#!/bin/sh\ntouch '\(marker.path)'\n".write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook.path)

        try Git.run(["worktree", "add", "-q", "-b", "feature", directory.appendingPathComponent("worktree").path], in: repository.path)

        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testRepositoryFilterCannotRunDuringWorktreeCreation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("plum-git-security-\(UUID().uuidString)")
        let repository = directory.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Git.run(["init", "-q", "-b", "main"], in: repository.path)
        try "file filter=evil\n".write(to: repository.appendingPathComponent(".gitattributes"), atomically: true, encoding: .utf8)
        try "safe\n".write(to: repository.appendingPathComponent("file"), atomically: true, encoding: .utf8)
        try Git.run(["add", "."], in: repository.path)
        try Git.run(["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-qm", "initial"], in: repository.path)
        let marker = directory.appendingPathComponent("filter-ran")
        try Git.run(["config", "filter.evil.smudge", "touch \(marker.path); cat"], in: repository.path)

        try Git.addWorktree(repository: repository.path, path: directory.appendingPathComponent("worktree").path,
                            branch: "feature", newBranchFrom: "HEAD")

        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testRepositoryCleanFilterCannotRunWhileReadingChanges() throws {
        let repository = FileManager.default.temporaryDirectory.appendingPathComponent("plum-git-security-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repository) }
        try Git.run(["init", "-q", "-b", "main"], in: repository.path)
        try "data filter=evil\n".write(to: repository.appendingPathComponent(".gitattributes"), atomically: true, encoding: .utf8)
        try "before".write(to: repository.appendingPathComponent("data"), atomically: true, encoding: .utf8)
        try Git.run(["add", "."], in: repository.path)
        try Git.run(["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-qm", "base"], in: repository.path)
        let marker = repository.appendingPathComponent("clean-ran")
        try Git.run(["config", "filter.evil.clean", "touch \(marker.path); cat"], in: repository.path)
        try "after".write(to: repository.appendingPathComponent("data"), atomically: true, encoding: .utf8)

        _ = Git.changes(in: repository.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        _ = try Diff.files(in: repository.path, scope: .uncommitted, base: "main")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testGlobalSmudgeFilterCannotRunDuringWorktreeCreation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("plum-git-security-\(UUID().uuidString)")
        let repository = directory.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Git.run(["init", "-q", "-b", "main"], in: repository.path)
        try "data filter=evil\n".write(to: repository.appendingPathComponent(".gitattributes"), atomically: true, encoding: .utf8)
        try "safe".write(to: repository.appendingPathComponent("data"), atomically: true, encoding: .utf8)
        try Git.run(["add", "."], in: repository.path)
        try Git.run(["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-qm", "base"], in: repository.path)
        let marker = directory.appendingPathComponent("global-smudge-ran")
        let global = directory.appendingPathComponent("global.gitconfig")
        try "[filter \"evil\"]\n\tsmudge = touch \(marker.path); cat\n".write(to: global, atomically: true, encoding: .utf8)
        let previous = getenv("GIT_CONFIG_GLOBAL").map { String(cString: $0) }
        setenv("GIT_CONFIG_GLOBAL", global.path, 1)
        defer { if let previous { setenv("GIT_CONFIG_GLOBAL", previous, 1) } else { unsetenv("GIT_CONFIG_GLOBAL") } }

        try Git.addWorktree(repository: repository.path, path: directory.appendingPathComponent("worktree").path,
                            branch: "feature", newBranchFrom: "HEAD")

        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testRepositoryMergeDriverCannotRunDuringBranchSafetyCheck() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("plum-git-security-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Git.run(["init", "-q", "-b", "main"], in: directory.path)
        try "file merge=evil\n".write(to: directory.appendingPathComponent(".gitattributes"), atomically: true, encoding: .utf8)
        let file = directory.appendingPathComponent("file")
        try "base\n".write(to: file, atomically: true, encoding: .utf8)
        try Git.run(["add", "."], in: directory.path)
        try Git.run(["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-qm", "base"], in: directory.path)
        try Git.run(["branch", "feature"], in: directory.path)
        try "main\n".write(to: file, atomically: true, encoding: .utf8)
        try Git.run(["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-qam", "main"], in: directory.path)
        try Git.run(["checkout", "-q", "feature"], in: directory.path)
        try "feature\n".write(to: file, atomically: true, encoding: .utf8)
        try Git.run(["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-qam", "feature"], in: directory.path)
        let marker = directory.appendingPathComponent("merge-ran")
        try Git.run(["config", "merge.evil.driver", "touch \(marker.path); false"], in: directory.path)

        XCTAssertFalse(Git.isMerged("main", in: directory.path))

        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testRepositoryConfigCannotChooseAnSshExecutable() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("plum-git-security-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Git.run(["init", "-q"], in: directory.path)
        let marker = directory.appendingPathComponent("ssh-ran")
        try Git.run(["config", "core.sshCommand", "touch \(marker.path); false"], in: directory.path)
        try Git.run(["remote", "add", "origin", "ssh://127.0.0.1:1/repo"], in: directory.path)

        XCTAssertThrowsError(try Git.run(["fetch", "origin"], in: directory.path, timeout: 3))

        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testRepositoryConfigCannotRunACredentialHelper() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("plum-git-security-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Git.run(["init", "-q"], in: directory.path)
        let marker = directory.appendingPathComponent("helper-ran")
        try Git.run(["config", "credential.helper", "!touch \(marker.path)"], in: directory.path)

        XCTAssertThrowsError(try Git.run(["credential", "fill"], in: directory.path,
                                         input: "protocol=https\nhost=example.com\n\n"))

        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testRepositoryConfigCannotChooseAnUploadPackExecutable() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("plum-git-security-\(UUID().uuidString)")
        let repository = directory.appendingPathComponent("repo")
        let remote = directory.appendingPathComponent("remote.git")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Git.run(["init", "-q", "--bare", remote.path], in: directory.path)
        try Git.run(["init", "-q"], in: repository.path)
        try Git.run(["remote", "add", "origin", remote.absoluteString], in: repository.path)
        let marker = directory.appendingPathComponent("uploadpack-ran")
        try Git.run(["config", "remote.origin.uploadpack", "touch \(marker.path); false"], in: repository.path)

        Git.fetch(in: repository.path)

        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testBranchSafetyFetchCannotChooseAnUploadPackExecutable() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("plum-git-security-\(UUID().uuidString)")
        let repository = directory.appendingPathComponent("repo")
        let remote = directory.appendingPathComponent("remote.git")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Git.run(["init", "-q", "--bare", remote.path], in: directory.path)
        try Git.run(["init", "-q", "-b", "main"], in: repository.path)
        try "base".write(to: repository.appendingPathComponent("file"), atomically: true, encoding: .utf8)
        try Git.run(["add", "file"], in: repository.path)
        try Git.run(["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-qm", "base"], in: repository.path)
        try Git.run(["branch", "feature"], in: repository.path)
        try Git.run(["checkout", "-q", "feature"], in: repository.path)
        try "unmerged".write(to: repository.appendingPathComponent("file"), atomically: true, encoding: .utf8)
        try Git.run(["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-qam", "feature"], in: repository.path)
        try Git.run(["checkout", "-q", "main"], in: repository.path)
        try Git.run(["remote", "add", "origin", remote.absoluteString], in: repository.path)
        try Git.run(["config", "branch.feature.base", "refs/remotes/origin/main"], in: repository.path)
        let marker = directory.appendingPathComponent("branch-uploadpack-ran")
        try Git.run(["config", "remote.origin.uploadpack", "touch \(marker.path); false"], in: repository.path)

        _ = Git.isMerged("feature", in: repository.path)

        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testBranchCannotCountItselfAsMergedAndDeleteUnpushedCommits() throws {
        let repository = FileManager.default.temporaryDirectory.appendingPathComponent("plum-git-security-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repository) }
        try Git.run(["init", "-q", "-b", "main"], in: repository.path)
        try "base".write(to: repository.appendingPathComponent("file"), atomically: true, encoding: .utf8)
        try Git.run(["add", "file"], in: repository.path)
        try Git.run(["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-qm", "base"], in: repository.path)
        try Git.run(["checkout", "-q", "-b", "feature"], in: repository.path)
        try "unmerged".write(to: repository.appendingPathComponent("file"), atomically: true, encoding: .utf8)
        try Git.run(["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-qam", "feature"], in: repository.path)
        try Git.run(["checkout", "-q", "main"], in: repository.path)
        try Git.run(["config", "branch.feature.base", "refs/heads/feature"], in: repository.path)

        XCTAssertNotNil(Git.deleteBranchIfMerged("feature", in: repository.path))
        XCTAssertTrue(Git.branchExists("feature", in: repository.path))

        try Git.run(["config", "branch.feature.base", "refs/heads/feature~0"], in: repository.path)
        XCTAssertNotNil(Git.deleteBranchIfMerged("feature", in: repository.path))
        XCTAssertTrue(Git.branchExists("feature", in: repository.path))
    }

    func testRepositoryConfigCannotEnableExecutableTransport() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("plum-git-security-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Git.run(["init", "-q"], in: directory.path)
        let marker = directory.appendingPathComponent("transport-ran")
        try Git.run(["config", "protocol.ext.allow", "always"], in: directory.path)
        try Git.run(["remote", "add", "origin", "ext::touch \(marker.path)"], in: directory.path)

        XCTAssertThrowsError(try Git.run(["fetch", "origin"], in: directory.path, timeout: 3))

        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }
}
