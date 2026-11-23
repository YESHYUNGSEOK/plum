import CryptoKit
import XCTest
@testable import PlumKit

/// Updates install only what the releaser signed, only if it is Plum at the
/// version the release names, and swap the app in one step.
final class UpdateInstallTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("plum-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    func testOnlyTheReleasersSignatureIsAccepted() throws {
        let key = Curve25519.Signing.PrivateKey()
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        let archive = Data("the zip".utf8)
        let signature = Data(try key.signature(for: archive).base64EncodedString().utf8 + [0x0A]) // as the .sig file holds it
        XCTAssertTrue(Updates.verify(archive, signature: signature, publicKey: publicKey))
        XCTAssertFalse(Updates.verify(Data("the zip, changed".utf8), signature: signature, publicKey: publicKey))
        let other = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        XCTAssertFalse(Updates.verify(archive, signature: signature, publicKey: other))
        XCTAssertFalse(Updates.verify(archive, signature: Data("not base64".utf8), publicKey: publicKey))
    }

    func testTheReleaseNamesThisMacsZipAndItsSignature() throws {
        let json = """
        {"tag_name": "v0.2.0", "html_url": "https://github.com/YESHYUNGSEOK/plum/releases/tag/v0.2.0", "assets": [
          {"name": "Plum-0.2.0-\(Updates.architecture).zip", "browser_download_url": "https://github.com/x/Plum.zip"},
          {"name": "Plum-0.2.0-\(Updates.architecture).zip.sig", "browser_download_url": "https://github.com/x/Plum.zip.sig"},
          {"name": "Plum-0.2.0-other.zip", "browser_download_url": "https://github.com/x/other.zip"}]}
        """
        let release = try JSONDecoder().decode(Updates.Release.self, from: Data(json.utf8))
        XCTAssertEqual(release.version, "0.2.0")
        XCTAssertEqual(release.archive?.zip.absoluteString, "https://github.com/x/Plum.zip")
        XCTAssertEqual(release.archive?.signature.absoluteString, "https://github.com/x/Plum.zip.sig")

        let unsigned = try JSONDecoder().decode(Updates.Release.self, from: Data(
            #"{"tag_name": "v0.2.0", "html_url": "https://github.com/x", "assets": [{"name": "Plum-0.2.0-arm64.zip", "browser_download_url": "https://github.com/x/z"}]}"#.utf8))
        XCTAssertNil(unsigned.archive, "no signature, nothing to install")
        XCTAssertNotNil(Updates.cannotInstall(unsigned, app: folder.appendingPathComponent("Plum.app")))
    }

    func testOnlyPlumAtTheNamedVersionIsSwappedIn() throws {
        let installed = try makeApp(at: folder.appendingPathComponent("Applications"), id: "dev.plum.Plum", version: "0.1.0")
        let zip = try zipApp(id: "dev.plum.Plum", version: "0.2.0", name: "good")

        XCTAssertThrowsError(try Updates.unpack(zip, into: folder.appendingPathComponent("w1"), version: "0.3.0", bundleID: "dev.plum.Plum")) {
            XCTAssertEqual($0 as? Updates.InstallError, .notPlum, "a different version than the release says")
        }
        let impostor = try zipApp(id: "com.example.other", version: "0.2.0", name: "bad")
        XCTAssertThrowsError(try Updates.unpack(impostor, into: folder.appendingPathComponent("w2"), version: "0.2.0", bundleID: "dev.plum.Plum")) {
            XCTAssertEqual($0 as? Updates.InstallError, .notPlum, "another app")
        }

        let fresh = try Updates.unpack(zip, into: folder.appendingPathComponent("w3"), version: "0.2.0", bundleID: "dev.plum.Plum")
        let result = try Updates.replace(installed, with: fresh)
        XCTAssertEqual(result.standardizedFileURL.path, installed.standardizedFileURL.path, "in the same place")
        let info = try XCTUnwrap(NSDictionary(contentsOf: installed.appendingPathComponent("Contents/Info.plist")))
        XCTAssertEqual(info["CFBundleShortVersionString"] as? String, "0.2.0")
        XCTAssertNil(Updates.cannotInstall(try XCTUnwrap(try? JSONDecoder().decode(Updates.Release.self, from: Data("""
            {"tag_name": "v0.2.0", "html_url": "https://github.com/x", "assets": [
              {"name": "Plum-0.2.0-\(Updates.architecture).zip", "browser_download_url": "https://github.com/x/z"},
              {"name": "Plum-0.2.0-\(Updates.architecture).zip.sig", "browser_download_url": "https://github.com/x/z.sig"}]}
            """.utf8))), app: installed), "a writable folder, not translocated")
        let signed = try JSONDecoder().decode(Updates.Release.self, from: Data("""
            {"tag_name": "v0.2.0", "html_url": "https://github.com/x", "assets": [
              {"name": "Plum-0.2.0-\(Updates.architecture).zip", "browser_download_url": "https://github.com/x/z"},
              {"name": "Plum-0.2.0-\(Updates.architecture).zip.sig", "browser_download_url": "https://github.com/x/z.sig"}]}
            """.utf8))
        XCTAssertNotNil(Updates.cannotInstall(signed, app: folder), "not an app bundle (swift run): never replaced")
    }

    private func makeApp(at parent: URL, id: String, version: String) throws -> URL {
        let app = parent.appendingPathComponent("Plum.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        let info: NSDictionary = ["CFBundleIdentifier": id, "CFBundleShortVersionString": version, "CFBundleExecutable": "Plum"]
        info.write(to: app.appendingPathComponent("Contents/Info.plist"), atomically: true)
        try Data("#!/bin/sh\n".utf8).write(to: app.appendingPathComponent("Contents/MacOS/Plum"))
        return app
    }

    /// A release zip as release.sh makes it: ditto with the bundle at the top.
    private func zipApp(id: String, version: String, name: String) throws -> URL {
        let app = try makeApp(at: folder.appendingPathComponent("build-\(name)"), id: id, version: version)
        let zip = folder.appendingPathComponent("\(name).zip")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--keepParent", app.path, zip.path]
        try ditto.run()
        ditto.waitUntilExit()
        XCTAssertEqual(ditto.terminationStatus, 0)
        return zip
    }
}
