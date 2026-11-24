import AppKit
import XCTest
@testable import PlumKit

/// Projects show their repository's own icon, found as Orca finds it.
final class ProjectIconTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("plum-icon-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    func testAUsualPlaceComesFirst() throws {
        XCTAssertNil(ProjectIcon.find(in: root.path), "nothing there")
        try write("logo.png", png())
        try write("public/favicon.png", png())
        try write("icon.png", Data("not an image".utf8))
        let found = try XCTUnwrap(ProjectIcon.find(in: root.path))
        XCTAssertEqual(found, try Data(contentsOf: root.appendingPathComponent("public/favicon.png")), "public/favicon before logo")
    }

    func testThePageLinksTheIcon() throws {
        try write("index.html", Data(#"<head><link href="/img/brand.png?v=2" rel="icon" type="image/png"></head>"#.utf8))
        try write("public/img/brand.png", png())
        XCTAssertNotNil(ProjectIcon.find(in: root.path), "/img/… is served from public/")

        XCTAssertEqual(ProjectIcon.linkedIcon(in: #"links: () => [{ rel: "icon", href: "/favicon-32.png" }]"#), "/favicon-32.png")
        XCTAssertEqual(ProjectIcon.resolve("icons/a.png", from: "src/index.html"), ["src/icons/a.png", "public/icons/a.png", "icons/a.png"])
        for outside in ["../secret.png", "https://example.com/a.png", "//cdn.example.com/a.png", "/a/../../b.png"] {
            XCTAssertEqual(ProjectIcon.resolve(outside, from: "index.html"), [], outside)
        }
    }

    func testTheGitHubOwnerComesFromTheRemote() {
        for remote in ["https://github.com/pnpm/pnpm.git", "git@github.com:Buzz-1/web", "ssh://git@github.com/acme/site.git",
                       "https://user@github.com/acme/site"] {
            XCTAssertNotNil(ProjectIcon.githubOwner(ofRemote: remote), remote)
        }
        XCTAssertEqual(ProjectIcon.githubOwner(ofRemote: "git@github.com:pnpm/pnpm.git"), "pnpm")
        for other in ["https://gitlab.com/acme/site.git", "https://github.com/acme", "https://github.com/a/b/c", "git@github.com:../x/y",
                      "https://github.com.evil.com/acme/site"] {
            XCTAssertNil(ProjectIcon.githubOwner(ofRemote: other), other)
        }
    }

    func testABigFileIsLeftAlone() throws {
        var big = png()
        big.append(Data(count: ProjectIcon.maxBytes))
        try write("favicon.png", big)
        XCTAssertNil(ProjectIcon.find(in: root.path))
    }

    func testOversizedImageDimensionsAreSkipped() throws {
        let wide = png(width: 2048, height: 1)
        XCTAssertLessThan(wide.count, ProjectIcon.maxBytes)
        try write("favicon.png", wide)

        XCTAssertNil(ProjectIcon.find(in: root.path))
    }

    func testSymlinkedIconOutsideRepositoryIsSkipped() throws {
        let outside = root.deletingLastPathComponent().appendingPathComponent("plum-private-icon-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: outside) }
        try png().write(to: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("favicon.png"), withDestinationURL: outside)

        XCTAssertNil(ProjectIcon.find(in: root.path))
    }

    func testSymlinkedIconDirectoryOutsideRepositoryIsSkipped() throws {
        let outside = root.deletingLastPathComponent().appendingPathComponent("plum-private-icons-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try png().write(to: outside.appendingPathComponent("favicon.png"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("public"), withDestinationURL: outside)

        XCTAssertNil(ProjectIcon.find(in: root.path))
    }

    private func write(_ path: String, _ data: Data) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    private func png(width: Int = 4, height: Int = 4) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: .png, properties: [:])!
    }
}
