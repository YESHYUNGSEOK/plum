import Foundation

/// Marks folders trusted in Claude Code's own config, so Claude doesn't open
/// a new worktree on "Do you trust the files in this folder?". The same
/// edit Orca makes: under Claude's lock, read the file again, set one key,
/// and swap the whole file in. Nothing is written if the file is missing,
/// can't be read, or stays locked.
public enum ClaudeTrust {
    public enum Result: Equatable { case granted, unchanged, missingConfig, locked, unreadable }

    /// Where Claude Code keeps it: `CLAUDE_CONFIG_DIR` if set, else home;
    /// a `.config.json` there wins over `.claude.json`.
    public static func configFile(environment: [String: String] = ProcessInfo.processInfo.environment,
                                  home: String = NSHomeDirectory()) -> String {
        let directory = environment["CLAUDE_CONFIG_DIR"]
        let config = ((directory ?? (home as NSString).appendingPathComponent(".claude")) as NSString)
            .appendingPathComponent(".config.json")
        if FileManager.default.fileExists(atPath: config) { return config }
        return ((directory ?? home) as NSString).appendingPathComponent(".claude.json")
    }

    @discardableResult
    public static func grant(_ folder: String, config: String = configFile()) -> Result {
        // Claude looks a folder up by the path it was given and by its real one.
        let keys = Set([folder, realPath(folder)])
        // A link to the real file is followed: replacing the link would cut it.
        let file = realPath(config)
        guard FileManager.default.fileExists(atPath: file) else { return .missingConfig }
        if let json = read(file), trusted(json, keys) { return .unchanged }

        // Claude Code's own lock (proper-lockfile: a directory beside the file).
        let lock = config + ".lock"
        var locked = false
        for wait in [0, 50, 100, 200, 250] {
            usleep(useconds_t(wait * 1000))
            if mkdir(lock, 0o755) == 0 { locked = true; break }
            if errno != EEXIST { break }
        }
        guard locked else { return .locked }
        defer { rmdir(lock) }

        guard let original = FileManager.default.contents(atPath: file),
              var json = try? JSONSerialization.jsonObject(with: original) as? [String: Any] else { return .unreadable }
        if trusted(json, keys) { return .unchanged }
        guard json["projects"] == nil || json["projects"] is [String: Any] else { return .unreadable }
        var projects = json["projects"] as? [String: Any] ?? [:]
        for key in keys {
            guard projects[key] == nil || projects[key] is [String: Any] else { return .unreadable }
            var entry = projects[key] as? [String: Any] ?? [:]
            entry["hasTrustDialogAccepted"] = true
            projects[key] = entry
        }
        json["projects"] = projects
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .withoutEscapingSlashes]) else {
            return .unreadable
        }
        // Written beside it with its permissions, then swapped in whole:
        // nobody ever reads half a file.
        let temporary = file + ".plum-trust-\(UUID().uuidString).tmp"
        let mode = (try? FileManager.default.attributesOfItem(atPath: file)[.posixPermissions] as? Int) ?? 0o600
        guard FileManager.default.createFile(atPath: temporary, contents: data, attributes: [.posixPermissions: mode]) else {
            return .unreadable
        }
        guard FileManager.default.contents(atPath: file) == original else { unlink(temporary); return .locked }
        guard rename(temporary, file) == 0 else {
            unlink(temporary)
            return .unreadable
        }
        return .granted
    }

    /// The kernel's real path: Foundation's own drops `/private`, which
    /// the agents keep.
    static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func read(_ file: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: file) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func trusted(_ json: [String: Any], _ keys: Set<String>) -> Bool {
        let projects = json["projects"] as? [String: Any] ?? [:]
        return keys.contains { (projects[$0] as? [String: Any])?["hasTrustDialogAccepted"] as? Bool == true }
    }
}

/// Marks a folder trusted in Codex's config.toml, as Codex does itself when
/// asked "Do you trust this folder?": a `[projects."<path>"]` table with
/// `trust_level = "trusted"`, appended. A folder that has a table already
/// keeps it, whatever it says.
public enum CodexTrust {
    public static func configFile(environment: [String: String] = ProcessInfo.processInfo.environment,
                                  home: String = NSHomeDirectory()) -> String {
        ((environment["CODEX_HOME"] ?? (home as NSString).appendingPathComponent(".codex")) as NSString)
            .appendingPathComponent("config.toml")
    }

    @discardableResult
    public static func grant(_ folder: String, config: String = configFile()) -> ClaudeTrust.Result {
        // Codex keys a folder by its real path.
        let real = ClaudeTrust.realPath(folder)
        let file = ClaudeTrust.realPath(config)
        guard let data = FileManager.default.contents(atPath: file) else {
            return FileManager.default.fileExists(atPath: file) ? .unreadable : .missingConfig
        }
        guard var text = String(data: data, encoding: .utf8),
              // A JSON string is a TOML basic string once slashes stay bare.
              let quoted = try? String(decoding: encoder.encode(real), as: UTF8.self) else { return .unreadable }
        let header = "[projects.\(quoted)]"
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        let keys = [quoted, "'\(real)'"].map(NSRegularExpression.escapedPattern).joined(separator: "|")
        let existing = "^\\s*\\[\\s*projects\\s*\\.\\s*(?:\(keys))\\s*\\]\\s*(?:#.*)?$"
        if lines.contains(where: { $0.range(of: existing, options: .regularExpression) != nil }) { return .unchanged }
        // `projects = {…}` written inline can't take another table after it.
        if lines.contains(where: { $0.hasPrefix("projects") && $0.dropFirst(8).trimmingCharacters(in: .whitespaces).hasPrefix("=") }) {
            return .unreadable
        }
        if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
        text += "\n\(header)\ntrust_level = \"trusted\"\n"
        let temporary = file + ".plum-trust-\(UUID().uuidString).tmp"
        let mode = (try? FileManager.default.attributesOfItem(atPath: file)[.posixPermissions] as? Int) ?? 0o600
        guard FileManager.default.createFile(atPath: temporary, contents: Data(text.utf8), attributes: [.posixPermissions: mode]) else {
            return .unreadable
        }
        guard FileManager.default.contents(atPath: file) == data else { unlink(temporary); return .locked }
        guard rename(temporary, file) == 0 else {
            unlink(temporary)
            return .unreadable
        }
        return .granted
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        return encoder
    }()
}
