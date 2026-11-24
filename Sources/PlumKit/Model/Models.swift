import Foundation

public struct Project: Codable, Identifiable, Equatable {
    public var id = UUID()
    public var name: String
    /// The repository's main checkout, or the folder of a folder project.
    public var path: String
    /// True for a folder that isn't a git repository, opened as in Orca:
    /// terminals only, no git. Optional so older state files still load.
    public var folder: Bool?
    public var isFolder: Bool { folder == true }
    /// Ref new branches start from. Empty = the remote's default branch.
    public var baseBranch = ""
    /// Untracked files to copy into each new worktree, as globs relative to `path`.
    public var copyPatterns: [String] = []
    public var setupCommand = ""
    /// Read only to carry a setting of older versions over to
    /// `AppSettings.claudeCommand`/`codexCommand`; the agent is now chosen
    /// for each new workspace or tab.
    public var agentCommand = ""
    /// The name shown for the main checkout, if the user gave it one.
    public var mainName: String?
    /// Where the main checkout sits among the project's workspaces in the
    /// sidebar, if the user moved it; nil for the top.
    public var mainPosition: Int?

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

/// What a new tab starts: just the shell, or an agent in it.
public enum TabProgram: String, Codable, CaseIterable, Identifiable, Sendable {
    case terminal, claude, codex
    public var id: Self { self }
}

/// How much an agent started in a tab may do without asking: Orca's
/// agent permissions, with the same flags.
public enum AgentPermission: String, Codable, CaseIterable, Sendable {
    /// Nothing is asked. Orca's default too.
    case fullAccess = "full-access"
    /// The agent approves safe actions itself and asks about the rest.
    case auto
    /// Plum adds no flag: the agent's own settings decide.
    case own

    /// The flag each agent takes for it; none for `own`.
    func flag(for program: TabProgram) -> String? {
        switch (self, program) {
        case (.fullAccess, .claude): "--dangerously-skip-permissions"
        case (.fullAccess, .codex): "--dangerously-bypass-approvals-and-sandbox"
        case (.auto, .claude): "--permission-mode auto"
        case (.auto, .codex): "--approve-for-me"
        default: nil
        }
    }

    /// Arguments that settle permissions on their own: a command that has
    /// one keeps it, and gets no flag added (as Orca keeps custom arguments).
    static let ownArguments = [
        "--permission-mode", "--dangerously-skip-permissions", "--allow-dangerously-skip-permissions",
        "--approve-for-me", "--dangerously-bypass-approvals-and-sandbox", "--ask-for-approval", "-a",
        "--sandbox", "-s", "--full-auto", "--yolo",
    ]
}

/// The color for selection, focus and the open tab's marks.
public enum AccentChoice: String, Codable, CaseIterable, Sendable { case plum, blue, green, orange, pink, graphite }

public struct AppSettings: Codable, Equatable {
    /// Empty = the system monospaced font.
    public var fontName = ""
    public var fontSize = 13.0
    public var workspaceRoot = "~/plum/workspaces"
    /// Prepended to the default branch name of a new workspace, e.g. "eric/".
    public var branchPrefix = ""
    /// Typed into a new Claude tab. The settings file adds the hooks through
    /// which Claude reports working, waiting and done.
    public var claudeCommand = AppSettings.defaultClaudeCommand
    public var codexCommand = AppSettings.defaultCodexCommand
    public var agentPermission = AgentPermission.own
    /// Tell Claude and Codex a workspace is trusted before they first open
    /// in it, so they don't stop to ask.
    public var trustWorkspaces = false
    /// ⌥ sends Esc before the key (Meta) instead of typing macOS's symbols.
    public var optionAsMeta = false
    /// zsh marks its prompts for Plum (⌘↑ and ⌘↓ between commands).
    public var shellIntegration = true
    public var cursorShape = TerminalSession.CursorShape.block
    public var cursorBlinks = false
    /// Output kept to scroll back to, per tab.
    public var scrollbackMB = 10
    public var accent = AccentChoice.plum

    public static let defaultClaudeCommand = "claude --settings \"$PLUM_CLAUDE_SETTINGS\""
    public static let defaultCodexCommand = "codex"

    public init() {}

    /// What to type into a new tab for `program`, permission flag
    /// included; nil for a plain shell.
    public func command(for program: TabProgram) -> String? {
        let base: String
        switch program {
        case .terminal: return nil
        case .claude: base = claudeCommand
        case .codex: base = codexCommand
        }
        let words = base.split(whereSeparator: \.isWhitespace)
        let settled = words.contains { word in AgentPermission.ownArguments.contains { word == $0 || word.hasPrefix($0 + "=") } }
        guard !settled, let flag = agentPermission.flag(for: program) else { return base }
        return base + " " + flag
    }

    // Tolerate files written by older builds that lack newer fields.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings()
        fontName = try container.decodeIfPresent(String.self, forKey: .fontName) ?? defaults.fontName
        fontSize = try container.decodeIfPresent(Double.self, forKey: .fontSize) ?? defaults.fontSize
        workspaceRoot = try container.decodeIfPresent(String.self, forKey: .workspaceRoot) ?? defaults.workspaceRoot
        branchPrefix = try container.decodeIfPresent(String.self, forKey: .branchPrefix) ?? defaults.branchPrefix
        claudeCommand = try container.decodeIfPresent(String.self, forKey: .claudeCommand) ?? defaults.claudeCommand
        codexCommand = try container.decodeIfPresent(String.self, forKey: .codexCommand) ?? defaults.codexCommand
        agentPermission = (try? container.decodeIfPresent(AgentPermission.self, forKey: .agentPermission)) ?? defaults.agentPermission
        trustWorkspaces = try container.decodeIfPresent(Bool.self, forKey: .trustWorkspaces) ?? defaults.trustWorkspaces
        optionAsMeta = try container.decodeIfPresent(Bool.self, forKey: .optionAsMeta) ?? defaults.optionAsMeta
        shellIntegration = try container.decodeIfPresent(Bool.self, forKey: .shellIntegration) ?? defaults.shellIntegration
        cursorShape = (try? container.decodeIfPresent(TerminalSession.CursorShape.self, forKey: .cursorShape)) ?? defaults.cursorShape
        cursorBlinks = try container.decodeIfPresent(Bool.self, forKey: .cursorBlinks) ?? defaults.cursorBlinks
        scrollbackMB = try container.decodeIfPresent(Int.self, forKey: .scrollbackMB) ?? defaults.scrollbackMB
        accent = (try? container.decodeIfPresent(AccentChoice.self, forKey: .accent)) ?? defaults.accent
    }
}

/// A tab as the app remembers it between runs; its terminal is the host's.
public struct SavedTab: Codable, Equatable {
    public var id: UUID
    public var workspace: UUID
    /// The title the user gave it, if any.
    public var title: String?
    public var active = false
}

public struct AppState: Codable, Equatable {
    public var projects: [Project] = []
    public var workspaces: [Workspace] = []
    public var settings = AppSettings()
    private var securityDefaultsVersion = 1
    /// The workspace selected when the app last ran.
    public var lastSelection: UUID?
    /// The sidebar's width as the user dragged it; nil for the default.
    public var sidebarWidth: Double?
    /// Projects folded in the sidebar to their name.
    public var collapsedProjects: Set<UUID> = []
    /// The tabs open when the app last ran, in order: the terminal host
    /// keeps their programs running, and the app attaches to them again.
    public var tabs: [SavedTab] = []
    /// Tabs split into panes, by the tab the tab bar shows for each.
    public var splits: [String: SplitNode] = [:]
    /// Workspaces shown in windows of their own.
    public var windows: [UUID] = []

    public init() {}

    // Tolerate files written by older builds that lack newer fields.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        projects = try container.decodeIfPresent([Project].self, forKey: .projects) ?? []
        workspaces = try container.decodeIfPresent([Workspace].self, forKey: .workspaces) ?? []
        settings = try container.decodeIfPresent(AppSettings.self, forKey: .settings) ?? AppSettings()
        if (try container.decodeIfPresent(Int.self, forKey: .securityDefaultsVersion) ?? 0) < 1 {
            settings.agentPermission = .own
            settings.trustWorkspaces = false
        }
        lastSelection = try container.decodeIfPresent(UUID.self, forKey: .lastSelection)
        sidebarWidth = try container.decodeIfPresent(Double.self, forKey: .sidebarWidth)
        collapsedProjects = try container.decodeIfPresent(Set<UUID>.self, forKey: .collapsedProjects) ?? []
        tabs = try container.decodeIfPresent([SavedTab].self, forKey: .tabs) ?? []
        splits = (try? container.decodeIfPresent([String: SplitNode].self, forKey: .splits)) ?? [:]
        windows = try container.decodeIfPresent([UUID].self, forKey: .windows) ?? []
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
        do { try Self.makePrivateDirectory(self.directory) }
        catch {
            fatalError("Plum state directory must be private: \(error)")
        }
    }

    static func makePrivateDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let directoryFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directoryFD >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { close(directoryFD) }
        guard fchmod(directoryFD, 0o700) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    }

    private var stateFile: URL { directory.appendingPathComponent("state.json") }

    public func load() -> AppState {
        guard let data = try? Data(contentsOf: stateFile) else { return AppState() }
        do {
            return try JSONDecoder().decode(AppState.self, from: data)
        } catch {
            // Never overwrite a file we couldn't read: keep it for recovery.
            let backup = directory.appendingPathComponent("state.corrupt-\(UUID().uuidString).json")
            do { try FileManager.default.moveItem(at: stateFile, to: backup) }
            catch { fatalError("Plum could not preserve unreadable state: \(error)") }
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
        guard WorkspaceService.canonical(path.path).hasPrefix(WorkspaceService.canonical(base.path) + "/") else { return nil }
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
        let destinationRoot = WorkspaceService.canonical(destination)
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
                guard resolved == URL(fileURLWithPath: match).standardizedFileURL.path,
                      resolved.hasPrefix(sourceRoot + "/"), match.hasPrefix(sourceRoot + "/") else { continue }
                let relative = String(match.dropFirst(sourceRoot.count + 1))
                guard relative != ".git", !relative.hasPrefix(".git/") else { continue }
                let target = URL(fileURLWithPath: destination).appendingPathComponent(relative)
                let parent = WorkspaceService.canonical(target.deletingLastPathComponent().path)
                guard parent == destinationRoot || parent.hasPrefix(destinationRoot + "/") else { continue }
                guard !fileManager.fileExists(atPath: target.path) else { continue }
                try? fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                if (try? fileManager.copyItem(atPath: match, toPath: target.path)) != nil { copied.append(relative) }
            }
        }
        return (copied, rejected)
    }
}
