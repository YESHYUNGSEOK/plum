import CryptoKit
import Foundation

/// Updates from the project's GitHub releases. A newer release's zip for this
/// Mac is downloaded, checked against the Ed25519 signature published with it
/// (made with the key only the releaser has; scripts/update-signing.swift),
/// unpacked, checked to be Plum at that version, and swapped in for the app.
/// The app then starts again; terminals live in the terminal host and carry on.
///
/// Without an Apple Developer ID this signature is what makes replacing the
/// app safe: a download changed on the way, or a release asset swapped by
/// someone else, doesn't match it and isn't installed. Files the app downloads
/// itself aren't quarantined, so the new copy opens without Gatekeeper asking.
public enum Updates {
    public struct Release: Decodable, Equatable {
        public let tag: String
        public let page: URL
        public let assets: [Asset]

        public struct Asset: Decodable, Equatable {
            public let name: String
            public let url: URL
            enum CodingKeys: String, CodingKey {
                case name
                case url = "browser_download_url"
            }
        }

        enum CodingKeys: String, CodingKey {
            case tag = "tag_name"
            case page = "html_url"
            case assets
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            tag = try container.decode(String.self, forKey: .tag)
            page = try container.decode(URL.self, forKey: .page)
            assets = try container.decodeIfPresent([Asset].self, forKey: .assets) ?? []
        }

        /// "v0.2.0" → "0.2.0": what the app's Info.plist says for that release.
        var version: String { String(tag.drop { !$0.isNumber }) }

        /// This Mac's zip and its signature, when the release has both.
        var archive: (zip: URL, signature: URL)? {
            let name = "Plum-\(version)-\(Updates.architecture).zip"
            guard let zip = assets.first(where: { $0.name == name })?.url,
                  let signature = assets.first(where: { $0.name == name + ".sig" })?.url,
                  zip.scheme == "https", signature.scheme == "https" else { return nil }
            return (zip, signature)
        }
    }

    /// GitHub has no public release to compare with.
    public struct NoRelease: LocalizedError {
        public var errorDescription: String? {
            String(localized: "공개된 릴리스가 없습니다. 저장소가 비공개이거나 아직 릴리스를 올리지 않았습니다.")
        }
    }

    public enum InstallError: LocalizedError, Equatable {
        case noArchive, download, badSignature, notPlum, cannotUnpack, cannotReplace(String)

        public var errorDescription: String? {
            switch self {
            case .noArchive: String(localized: "이 릴리스에는 이 Mac용 서명된 파일이 없습니다.")
            case .download: String(localized: "업데이트 파일을 내려받지 못했습니다.")
            case .badSignature: String(localized: "내려받은 파일의 서명이 맞지 않아 설치하지 않았습니다.")
            case .notPlum: String(localized: "내려받은 파일이 이 버전의 Plum이 아닙니다.")
            case .cannotUnpack: String(localized: "내려받은 파일을 풀지 못했습니다.")
            case let .cannotReplace(reason): String(localized: "앱을 바꾸지 못했습니다: \(reason)")
            }
        }
    }

    static let latest = URL(string: "https://api.github.com/repos/YESHYUNGSEOK/plum/releases/latest")!
    /// The releaser's Ed25519 public key (scripts/update-signing.swift new-key).
    static let publicKey = "0l67RqAGdxBIeTKCHIkzAKId6sfDyeStos++dhIA4Ts="

    static var architecture: String {
        #if arch(arm64)
        "arm64"
        #else
        "x86_64"
        #endif
    }

    public static var current: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// The latest release if it is newer than this build; nil if not, or if
    /// there is none. Throws when GitHub can't be asked.
    public static func newer(than version: String = current) async throws -> Release? {
        var request = URLRequest(url: latest, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        // A private repository looks the same as one with no release.
        if (response as? HTTPURLResponse)?.statusCode == 404 { throw NoRelease() }
        let release = try JSONDecoder().decode(Release.self, from: data)
        // Only GitHub's own pages are opened, whatever the answer says.
        guard release.page.scheme == "https", release.page.host == "github.com" else { return nil }
        return isNewer(release.tag, than: version) ? release : nil
    }

    /// "v0.2.0" against "0.1.9": compared number by number.
    public static func isNewer(_ tag: String, than version: String) -> Bool {
        func numbers(_ text: String) -> [Int] {
            text.drop { !$0.isNumber }.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let (a, b) = (numbers(tag), numbers(version))
        for index in 0..<max(a.count, b.count) {
            let (x, y) = (index < a.count ? a[index] : 0, index < b.count ? b[index] : 0)
            if x != y { return x > y }
        }
        return false
    }

    // MARK: Installing

    /// Why this copy can't replace itself, if it can't; the release page is
    /// offered instead.
    public static func cannotInstall(_ release: Release, app: URL = Bundle.main.bundleURL) -> String? {
        if release.archive == nil { return InstallError.noArchive.errorDescription }
        // `swift run` and the like: the "app" is the folder the binary is in.
        if app.pathExtension != "app" || Bundle.main.bundleIdentifier == nil {
            return String(localized: "Plum.app으로 실행할 때만 스스로 업데이트합니다.")
        }
        // Opened straight from a download, macOS runs a read-only copy elsewhere.
        if app.path.contains("/AppTranslocation/") {
            return String(localized: "Plum이 macOS가 정한 임시 위치에서 실행 중입니다. 응용 프로그램 폴더로 옮긴 뒤 다시 여세요.")
        }
        if !FileManager.default.isWritableFile(atPath: app.deletingLastPathComponent().path) {
            return String(localized: "\(app.deletingLastPathComponent().path) 폴더를 바꿀 권한이 없습니다.")
        }
        return nil
    }

    /// Downloads, checks and swaps in `release`; returns where the new app is.
    public static func install(_ release: Release, app: URL = Bundle.main.bundleURL) async throws -> URL {
        guard let archive = release.archive else { throw InstallError.noArchive }
        let zip = try await download(archive.zip)
        let signature = try await download(archive.signature)
        return try install(zip, signature: signature, version: release.version, app: app)
    }

    /// A failed download (rate limit, outage) is not a bad signature.
    private static func download(_ url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw InstallError.download }
        return data
    }

    /// The same, for a zip and signature at hand.
    public static func install(_ zip: Data, signature: Data, version: String, app: URL = Bundle.main.bundleURL) throws -> URL {
        guard verify(zip, signature: signature, publicKey: publicKey) else { throw InstallError.badSignature }
        guard let bundleID = Bundle.main.bundleIdentifier else { throw InstallError.notPlum }
        // On the app's own volume, so the swap is a rename.
        let work = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: app, create: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let file = work.appendingPathComponent("update.zip")
        try zip.write(to: file)
        let fresh = try unpack(file, into: work, version: version, bundleID: bundleID)
        return try replace(app, with: fresh)
    }

    /// Whether `signature` (the .sig file: base64) is `publicKey`'s for `data`.
    static func verify(_ data: Data, signature: Data, publicKey: String) -> Bool {
        guard let raw = Data(base64Encoded: publicKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw),
              let signature = Data(base64Encoded: String(decoding: signature, as: UTF8.self)
                  .trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return key.isValidSignature(signature, for: data)
    }

    /// Unpacks a release zip in `folder`; the app in it, once it is Plum at `version`.
    static func unpack(_ zip: URL, into folder: URL, version: String, bundleID: String) throws -> URL {
        let target = folder.appendingPathComponent("unpacked")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path, target.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else { throw InstallError.cannotUnpack }
        let app = target.appendingPathComponent("Plum.app")
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == bundleID,
              info["CFBundleShortVersionString"] as? String == version else { throw InstallError.notPlum }
        return app
    }

    /// Puts `fresh` where `app` is, in one step; the old copy goes.
    static func replace(_ app: URL, with fresh: URL) throws -> URL {
        do {
            return try FileManager.default.replaceItemAt(app, withItemAt: fresh) ?? app
        } catch {
            throw InstallError.cannotReplace(error.localizedDescription)
        }
    }
}
