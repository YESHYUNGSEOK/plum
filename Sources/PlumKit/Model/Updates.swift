import Foundation

/// Looks at the project's GitHub releases for a newer version. It only
/// tells: installing stays the user's own download, since replacing the app
/// by itself needs a signed build to be safe.
public enum Updates {
    public struct Release: Decodable, Equatable {
        public let tag: String
        public let page: URL
        enum CodingKeys: String, CodingKey {
            case tag = "tag_name"
            case page = "html_url"
        }
    }

    /// GitHub has no public release to compare with.
    public struct NoRelease: LocalizedError {
        public var errorDescription: String? {
            String(localized: "공개된 릴리스가 없습니다. 저장소가 비공개이거나 아직 릴리스를 올리지 않았습니다.")
        }
    }

    static let latest = URL(string: "https://api.github.com/repos/YESHYUNGSEOK/plum/releases/latest")!

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
}
