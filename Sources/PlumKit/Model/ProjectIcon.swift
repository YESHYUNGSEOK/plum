import AppKit

/// A project's own icon, found the way Orca finds it: a PNG or WebP at one of
/// the usual places in the repository, else the one a page links to as its
/// icon (`<link rel="icon">`), else the GitHub picture of whoever owns the
/// repository (`find(in:)` reads only the repository; `ownerPicture` asks GitHub).
enum ProjectIcon {
    static let maxBytes = 256 * 1024
    static let places = [
        "favicon", "public/favicon", "app/favicon", "app/icon", "src/favicon", "src/app/icon", "assets/favicon",
        "assets/icon", "static/favicon", "logo", "public/logo", "public/icon", "src-tauri/icons/icon", "app-icon", "icon",
    ].flatMap { [$0 + ".png", $0 + ".webp"] }
    static let pages = [
        "index.html", "public/index.html", "app/routes/__root.tsx", "src/routes/__root.tsx", "app/root.tsx",
        "src/root.tsx", "src/index.html",
    ]

    /// The icon's bytes (PNG or WebP), or nil if the repository has none.
    static func find(in root: String) -> Data? {
        for place in places { if let data = image(place, in: root) { return data } }
        for page in pages {
            guard let text = file(page, in: root).flatMap({ String(data: $0, encoding: .utf8) }),
                  let href = linkedIcon(in: text) else { continue }
            for place in resolve(href, from: page) { if let data = image(place, in: root) { return data } }
        }
        return nil
    }

    /// The GitHub owner of a remote (github.com/OWNER/repo), for `ownerPicture`.
    static func githubOwner(ofRemote remote: String) -> String? {
        let pattern = #"^(?:https://(?:[^@/]+@)?|ssh://git@|git@)github\.com[:/]([A-Za-z0-9](?:[A-Za-z0-9-]{0,38}))/[^/]+?(?:\.git)?/?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: remote, range: NSRange(remote.startIndex..., in: remote)),
              let owner = Range(match.range(at: 1), in: remote) else { return nil }
        return String(remote[owner])
    }

    /// The owner's GitHub picture, as Orca shows it when the repository has no icon of its own.
    static func ownerPicture(_ owner: String) async -> Data? {
        guard let url = URL(string: "https://github.com/\(owner).png?size=64"),
              let (bytes, response) = try? await URLSession.shared.bytes(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let data = try? await Updates.collect(bytes, expectedLength: response.expectedContentLength, limit: maxBytes),
              NSImage(data: data)?.isValid == true else { return nil }
        return data
    }

    /// The href of `<link rel="icon">` in HTML, or of `{ rel: "icon", href: … }` in a route file.
    static func linkedIcon(in text: String) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        if let match = htmlLink.firstMatch(in: text, range: range), let href = Range(match.range(at: 1), in: text) {
            return String(text[href])
        }
        // An object literal: rel and href between the same braces.
        for part in text.split(separator: "}") {
            let part = String(part), all = NSRange(part.startIndex..., in: part)
            guard objectRel.firstMatch(in: part, range: all) != nil, let match = objectHref.firstMatch(in: part, range: all),
                  let href = Range(match.range(at: 1), in: part) else { continue }
            return String(part[href])
        }
        return nil
    }

    /// Where an href may point in the repository: beside the page, under
    /// public/ (where web tools serve "/" from), at the root. Never outside.
    static func resolve(_ href: String, from page: String) -> [String] {
        let href = href.trimmingCharacters(in: .whitespaces)
        guard !href.isEmpty, !href.hasPrefix("//"), href.range(of: "^[A-Za-z][A-Za-z0-9+.-]*:", options: .regularExpression) == nil,
              let path = href.split(whereSeparator: { $0 == "?" || $0 == "#" }).first else { return [] }
        let parts = path.replacingOccurrences(of: "\\", with: "/").split(separator: "/").filter { $0 != "." }
        guard !parts.isEmpty, !parts.contains("..") else { return [] }
        let joined = parts.joined(separator: "/"), folder = (page as NSString).deletingLastPathComponent
        var places = href.hasPrefix("/") || folder.isEmpty ? [] : [folder + "/" + joined]
        for place in ["public/" + joined, joined] where !places.contains(place) { places.append(place) }
        return places
    }

    private static let htmlLink = try! NSRegularExpression(
        pattern: #"<link\b(?=[^>]*\brel=["'](?:icon|shortcut icon)["'])(?=[^>]*\bhref=["']([^"'?]+))[^>]*>"#, options: .caseInsensitive)
    private static let objectRel = try! NSRegularExpression(pattern: #"\brel\s*:\s*["'](?:icon|shortcut icon)["']"#, options: .caseInsensitive)
    private static let objectHref = try! NSRegularExpression(pattern: #"\bhref\s*:\s*["']([^"'?]+)"#, options: .caseInsensitive)

    /// A small regular file's bytes.
    private static func file(_ relative: String, in root: String) -> Data? {
        let url = URL(fileURLWithPath: root).appendingPathComponent(relative)
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, (values.fileSize ?? .max) <= maxBytes else { return nil }
        return try? Data(contentsOf: url)
    }

    /// The file's bytes if it really is a PNG or WebP image (by its content, not its name).
    private static func image(_ relative: String, in root: String) -> Data? {
        guard let data = file(relative, in: root) else { return nil }
        let png = data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let webp = data.count > 12 && data.prefix(4) == Data("RIFF".utf8) && data.dropFirst(8).prefix(4) == Data("WEBP".utf8)
        guard png || webp, NSImage(data: data)?.isValid == true else { return nil }
        return data
    }
}
