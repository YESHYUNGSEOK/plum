import Foundation

/// What changed in a checkout, file by file, for the diff view.
public enum Diff {
    public enum Scope: String, CaseIterable, Sendable {
        /// Since the last commit: what `git status` would show.
        case uncommitted
        /// Everything on the branch since it left its base, uncommitted work included.
        case branch
    }

    public struct Line: Equatable, Sendable {
        public enum Kind: Sendable { case context, added, removed, hunk }
        public let kind: Kind
        public let text: String
        public let old: Int?
        public let new: Int?
    }

    public struct File: Identifiable, Equatable, Sendable {
        public var id: String { path }
        public var path: String
        public var added = 0
        public var removed = 0
        public var isNew = false
        public var isDeleted = false
        public var isBinary = false
        public var lines: [Line] = []
        /// Lines left out to keep the view fast.
        public var omitted = 0
    }

    /// Lines shown per file; the rest are counted, not drawn.
    static let linesPerFile = 3000

    /// The files changed in `checkout` for `scope`. `base` is the branch to
    /// compare with for `.branch` (e.g. "main"); origin's copy is used when
    /// there is one.
    public static func files(in checkout: String, scope: Scope, base: String) throws -> [File] {
        var from = "HEAD"
        if scope == .branch {
            let candidates = ["origin/\(base)", base]
            guard let ref = candidates.first(where: { (try? Git.run(["rev-parse", "--verify", "--quiet", $0], in: checkout)) != nil }),
                  let point = try? Git.run(["merge-base", "HEAD", ref], in: checkout).trimmingCharacters(in: .whitespacesAndNewlines),
                  !point.isEmpty
            else { throw Problem(text: String(localized: "비교할 기준 브랜치를 찾지 못했습니다: \(base)")) }
            from = point
        }
        let patch = try Git.run(["-c", "core.quotepath=false", "diff", "--no-color", "--no-ext-diff", "--no-textconv", "-M", from, "--"], in: checkout, timeout: 30)
        var files = parse(patch)
        let untracked = (try? Git.run(["ls-files", "--others", "--exclude-standard", "-z"], in: checkout, timeout: 15)) ?? ""
        for path in untracked.split(separator: "\0").map(String.init).prefix(500) {
            files.append(newFile(path, in: checkout))
        }
        return files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    public struct Problem: LocalizedError {
        let text: String
        public var errorDescription: String? { text }
    }

    /// Splits `git diff` output into files with numbered lines.
    static func parse(_ patch: String) -> [File] {
        var files: [File] = []
        var old = 0, new = 0
        for raw in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("diff --git ") {
                // "diff --git a/x b/x": the b side is the name now.
                let path = line.components(separatedBy: " b/").last ?? line
                files.append(File(path: path))
                continue
            }
            guard !files.isEmpty else { continue }
            let index = files.count - 1
            if line.hasPrefix("new file mode") { files[index].isNew = true; continue }
            if line.hasPrefix("deleted file mode") { files[index].isDeleted = true; continue }
            if line.hasPrefix("Binary files ") { files[index].isBinary = true; continue }
            if line.hasPrefix("rename to ") { files[index].path = String(line.dropFirst(10)); continue }
            if line.hasPrefix("@@") {
                // "@@ -12,7 +12,9 @@ func …"
                let numbers = line.split(separator: " ").dropFirst().prefix(2)
                old = numbers.first.flatMap { Int($0.dropFirst().split(separator: ",").first ?? "") } ?? 0
                new = numbers.dropFirst().first.flatMap { Int($0.dropFirst().split(separator: ",").first ?? "") } ?? 0
                append(Line(kind: .hunk, text: line, old: nil, new: nil), to: &files[index])
                continue
            }
            if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("index ") || line.hasPrefix("similarity ")
                || line.hasPrefix("rename from ") || line.hasPrefix("old mode") || line.hasPrefix("new mode") || line.hasPrefix("\\") {
                continue
            }
            switch line.first {
            case "+":
                files[index].added += 1
                append(Line(kind: .added, text: String(line.dropFirst()), old: nil, new: new), to: &files[index])
                new += 1
            case "-":
                files[index].removed += 1
                append(Line(kind: .removed, text: String(line.dropFirst()), old: old, new: nil), to: &files[index])
                old += 1
            case " ":
                append(Line(kind: .context, text: String(line.dropFirst()), old: old, new: new), to: &files[index])
                old += 1
                new += 1
            default: break
            }
        }
        return files
    }

    private static func append(_ line: Line, to file: inout File) {
        if file.lines.count < linesPerFile { file.lines.append(line) } else { file.omitted += 1 }
    }

    /// A file git doesn't know yet, shown as all added.
    private static func newFile(_ path: String, in checkout: String) -> File {
        var file = File(path: path, isNew: true)
        let url = URL(fileURLWithPath: checkout).appendingPathComponent(path)
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, let size = values.fileSize, size <= 4 << 20,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              !data.prefix(8000).contains(0), let text = String(data: data, encoding: .utf8) else {
            file.isBinary = true
            return file
        }
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        file.added = lines.count
        for (number, line) in lines.enumerated() {
            append(Line(kind: .added, text: line, old: nil, new: number + 1), to: &file)
        }
        return file
    }
}
