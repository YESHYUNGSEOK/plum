import Foundation

public struct Project: Codable, Identifiable, Equatable {
    public var id = UUID()
    public var name: String
    /// The repository's main checkout.
    public var path: String
    /// Ref new branches start from. Empty = the remote's default branch.
    public var baseBranch = ""
    /// Untracked files to copy into each new worktree, as globs relative to `path`.
    public var copyPatterns: [String] = []
    public var setupCommand = ""
    public var agentCommand = ""

    public init(name: String, path: String) {
        self.name = name
        self.path = path
    }
}

public struct Workspace: Codable, Identifiable, Equatable {
    public var id = UUID()
    public var projectID: UUID
    public var name: String
    public var branch: String
    public var path: String
    /// Archived: the worktree folder is gone but the branch is kept.
    public var isArchived = false

    public init(projectID: UUID, name: String, branch: String, path: String) {
        self.projectID = projectID
        self.name = name
        self.branch = branch
        self.path = path
    }
}

public struct AppSettings: Codable, Equatable {
    /// Empty = the system monospaced font.
    public var fontName = ""
    public var fontSize = 13.0
    public var workspaceRoot = "~/plum/workspaces"
    /// Prepended to the default branch name of a new workspace, e.g. "eric/".
    public var branchPrefix = ""

    public init() {}
}

public struct AppState: Codable, Equatable {
    public var projects: [Project] = []
    public var workspaces: [Workspace] = []
    public var settings = AppSettings()

    public init() {}

    // Tolerate files written by older builds that lack newer fields.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        projects = try container.decodeIfPresent([Project].self, forKey: .projects) ?? []
        workspaces = try container.decodeIfPresent([Workspace].self, forKey: .workspaces) ?? []
        settings = try container.decodeIfPresent(AppSettings.self, forKey: .settings) ?? AppSettings()
    }
}

/// Where Plum keeps its state, hook settings and socket.
public struct Store {
    public let directory: URL

    /// `PLUM_STATE_DIR` redirects everything, so tests never touch real state.
    public init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else if let override = ProcessInfo.processInfo.environment["PLUM_STATE_DIR"], !override.isEmpty {
            self.directory = URL(fileURLWithPath: override)
        } else {
            // Named after the bundle id, not just "Plum": that folder name is
            // common enough that another app's data may already live there.
            self.directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("dev.plum.Plum")
        }
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    private var stateFile: URL { directory.appendingPathComponent("state.json") }

    public func load() -> AppState {
        guard let data = try? Data(contentsOf: stateFile) else { return AppState() }
        do {
            return try JSONDecoder().decode(AppState.self, from: data)
        } catch {
            // Never overwrite a file we couldn't read: keep it for recovery.
            let backup = directory.appendingPathComponent("state.corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: stateFile, to: backup)
            return AppState()
        }
    }

    public func save(_ state: AppState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: stateFile, options: .atomic)
    }
}

// MARK: - Names and files

public enum WorkspaceNaming {
    /// A branch name suggested from what the user typed: spaces become
    /// hyphens and characters git refuses are dropped.
    public static func branchName(for name: String, prefix: String) -> String {
        let forbidden = CharacterSet(charactersIn: "~^:?*[\\").union(.controlCharacters)
        var cleaned = String(String.UnicodeScalarView(
            name.trimmingCharacters(in: .whitespaces).unicodeScalars.map { scalar -> UnicodeScalar in
                CharacterSet.whitespaces.contains(scalar) ? "-" : scalar
            }.filter { !forbidden.contains($0) }))
        while cleaned.contains("..") { cleaned = cleaned.replacingOccurrences(of: "..", with: ".") }
        while cleaned.contains("//") { cleaned = cleaned.replacingOccurrences(of: "//", with: "/") }
        cleaned = cleaned.replacingOccurrences(of: "@{", with: "-")
        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "/.-"))
        if cleaned.hasSuffix(".lock") { cleaned = String(cleaned.dropLast(5)) }
        return cleaned.isEmpty ? "" : prefix + cleaned
    }

    /// A single folder name for the workspace. Nil if nothing usable is left.
    public static func folderName(for name: String) -> String? {
        let forbidden = CharacterSet(charactersIn: "/:\\").union(.controlCharacters)
        let cleaned = String(String.UnicodeScalarView(
            name.trimmingCharacters(in: .whitespaces).unicodeScalars.map { scalar -> UnicodeScalar in
                forbidden.contains(scalar) || CharacterSet.whitespaces.contains(scalar) ? "-" : scalar
            }))
        guard !cleaned.isEmpty, cleaned != ".", cleaned != "..", !cleaned.hasPrefix(".") else { return nil }
        return cleaned
    }

    /// `<root>/<project>/<workspace>`, or nil if the names can't form a path
    /// that stays inside the root.
    public static func worktreePath(root: String, project: String, workspace: String) -> String? {
        guard let projectFolder = folderName(for: project), let workspaceFolder = folderName(for: workspace) else { return nil }
        let base = URL(fileURLWithPath: (root as NSString).expandingTildeInPath).standardizedFileURL
        let path = base.appendingPathComponent(projectFolder).appendingPathComponent(workspaceFolder).standardizedFileURL
        guard path.path.hasPrefix(base.path + "/") else { return nil }
        return path.path
    }
}

public enum WorkspaceFiles {
    /// Copies files matching `patterns` (globs relative to `source`) into the
    /// same relative place under `destination`. Existing files are kept.
    /// Returns the relative paths copied and the patterns that were refused.
    @discardableResult
    public static func copy(patterns: [String], from source: String, to destination: String) -> (copied: [String], rejected: [String]) {
        let fileManager = FileManager.default
        let sourceRoot = URL(fileURLWithPath: source).resolvingSymlinksInPath().path
        var copied: [String] = []
        var rejected: [String] = []

        for pattern in patterns.map({ $0.trimmingCharacters(in: .whitespaces) }) where !pattern.isEmpty {
            // Patterns come from settings the user typed, but a pattern that
            // climbs out of the repository is always a mistake.
            guard !pattern.hasPrefix("/"), !pattern.hasPrefix("~"), !pattern.split(separator: "/").contains("..") else {
                rejected.append(pattern)
                continue
            }
            var matches = glob_t()
            defer { globfree(&matches) }
            guard glob(sourceRoot + "/" + pattern, GLOB_BRACE, nil, &matches) == 0 else { continue }

            for index in 0..<Int(matches.gl_pathc) {
                guard let cString = matches.gl_pathv[index] else { continue }
                let match = String(cString: cString)
                // A symlink inside the repository may point anywhere; only
                // copy what really lives under it.
                let resolved = URL(fileURLWithPath: match).resolvingSymlinksInPath().path
                guard resolved.hasPrefix(sourceRoot + "/"), match.hasPrefix(sourceRoot + "/") else { continue }
                let relative = String(match.dropFirst(sourceRoot.count + 1))
                guard relative != ".git", !relative.hasPrefix(".git/") else { continue }
                let target = URL(fileURLWithPath: destination).appendingPathComponent(relative)
                guard !fileManager.fileExists(atPath: target.path) else { continue }
                try? fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                if (try? fileManager.copyItem(atPath: match, toPath: target.path)) != nil { copied.append(relative) }
            }
        }
        return (copied, rejected)
    }
}
