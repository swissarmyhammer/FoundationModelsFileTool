import Foundation

/// One line of a `grep files` result: the file it came from, its line number, its text, and whether it matched.
///
/// A ``GrepMatch`` is emitted for every line rendered in the `content` output
/// mode — both the lines that the pattern actually matched (``isMatch`` `true`)
/// and the surrounding context lines carried along for readability
/// (``isMatch`` `false`). The ``line`` is the 1-based physical line number,
/// numbered against the same line model `read file` uses, so a match's address
/// can be fed straight back to `read file` / `edit file`.
public struct GrepMatch: Encodable, Sendable {
    /// The matching file's path relative to the session root.
    public let file: String

    /// The 1-based physical line number of this line within its file.
    public let line: Int

    /// The line's text, with its terminator excluded.
    public let text: String

    /// Whether this line matched the pattern (`true`) or is surrounding context (`false`).
    public let isMatch: Bool

    /// Creates a grep match line.
    ///
    /// - Parameters:
    ///   - file: the matching file's path relative to the session root.
    ///   - line: the 1-based physical line number.
    ///   - text: the line's text, excluding its terminator.
    ///   - isMatch: whether this line matched the pattern rather than being context.
    public init(file: String, line: Int, text: String, isMatch: Bool) {
        self.file = file
        self.line = line
        self.text = text
        self.isMatch = isMatch
    }
}

/// The successful result of a `grep files` operation, shaped by the requested output mode.
///
/// The three output modes carry different fields, expressed here as optionals
/// that the encoder omits when absent (Swift's synthesized encoding skips a
/// `nil` optional): the `content` mode carries ``matches`` (with ``files``
/// absent); the `filesWithMatches` mode carries ``files`` (with ``matches``
/// absent); and the `count` mode carries neither. All three always carry the
/// ``matchCount`` (the number of matched lines — only match lines count, never
/// context lines), the ``fileCount`` (the number of files with at least one
/// match), and the ``elapsedMilliseconds`` wall-clock timing (encoded as
/// `elapsedMs`).
public struct GrepResult: Encodable, Sendable {
    /// The matched and context lines, present only in the `content` mode.
    public let matches: [GrepMatch]?

    /// The relative paths of the files with at least one match, present only in the `filesWithMatches` mode.
    public let files: [String]?

    /// The total number of matched lines across all files; context lines never count.
    public let matchCount: Int

    /// The number of files with at least one matched line.
    public let fileCount: Int

    /// The wall-clock duration of the search, in milliseconds.
    public let elapsedMilliseconds: Double

    /// The coding keys, mapping ``elapsedMilliseconds`` to the `elapsedMs` wire field.
    private enum CodingKeys: String, CodingKey {
        /// The `content`-mode matched and context lines.
        case matches
        /// The `filesWithMatches`-mode file list.
        case files
        /// The matched-line total.
        case matchCount
        /// The matched-file total.
        case fileCount
        /// The wall-clock duration, rendered as the compact `elapsedMs` field.
        case elapsedMilliseconds = "elapsedMs"
    }

    /// Creates a grep result.
    ///
    /// - Parameters:
    ///   - matches: the matched and context lines, or `nil` outside the `content` mode.
    ///   - files: the matched-file relative paths, or `nil` outside the `filesWithMatches` mode.
    ///   - matchCount: the total number of matched lines.
    ///   - fileCount: the number of files with at least one match.
    ///   - elapsedMilliseconds: the wall-clock duration of the search, in milliseconds.
    public init(
        matches: [GrepMatch]?,
        files: [String]?,
        matchCount: Int,
        fileCount: Int,
        elapsedMilliseconds: Double
    ) {
        self.matches = matches
        self.files = files
        self.matchCount = matchCount
        self.fileCount = fileCount
        self.elapsedMilliseconds = elapsedMilliseconds
    }
}

/// The outcome of a `grep files` operation: either the mode-shaped result or a corrective message.
///
/// The operation follows the upstream *return-don't-throw* convention (the same
/// convention ``GlobOutput``, ``ReadOutput``, and ``PathViolation`` embody): an
/// invalid regular expression, an unknown file type, an unknown output mode, an
/// invalid `glob` filter, a rejected search root, or a missing path is surfaced
/// as a ``corrective(_:)`` message the model reads and acts on within the turn,
/// never thrown. Throwing from an operation's `execute(in:)` is fatal to the
/// turn, so every recoverable condition returns a value instead.
public enum GrepOutput: Encodable, Sendable {
    /// A successful grep carrying the ``GrepResult``.
    case content(GrepResult)

    /// A recoverable failure carrying a corrective message for the model.
    case corrective(String)

    /// The coding keys for the ``corrective(_:)`` encoding.
    private enum CodingKeys: String, CodingKey {
        /// The corrective-message field.
        case corrective
    }

    /// Encodes the outcome.
    ///
    /// A ``content(_:)`` outcome encodes the ``GrepResult`` inline (its
    /// mode-shaped fields); a ``corrective(_:)`` outcome encodes a single
    /// `corrective` field carrying the message.
    ///
    /// - Parameter encoder: the encoder to write the outcome into.
    /// - Throws: An error if the encoder fails to encode a value.
    public func encode(to encoder: Encoder) throws {
        switch self {
        case .content(let result):
            try result.encode(to: encoder)
        case .corrective(let message):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(message, forKey: .corrective)
        }
    }
}

/// Searches file contents for a regular expression, git-aware and binary-skipping, shaped by output mode.
///
/// The engine resolves the output mode, the optional file-type filter, the
/// optional `glob` filename filter, and the regular expression (all invalid
/// inputs returned as correctives); resolves the search target through the
/// context's ``PathGuard`` (a single file short-circuits the walk, a directory
/// is enumerated); enumerates candidate files through the shared, git-aware
/// ``FileWalker`` so a gitignored directory such as `build/` is never descended
/// into — the fix for the "unscoped grep hung forever" pathology; skips a file
/// whose first bytes contain a NUL (a binary file); matches each line with
/// Swift `Regex`; assembles the matched lines with their surrounding context
/// into hunks; and returns the mode-shaped ``GrepResult``. Every recoverable
/// failure is returned as ``GrepOutput/corrective(_:)``; nothing here throws.
public struct GrepEngine: Sendable {
    // MARK: Configuration

    /// The number of context lines rendered on each side of a match when `contextLines` is absent.
    private static let defaultContextLines = 2

    /// The smallest permitted context-line count: a floor that degrades any requested negative value to match-lines-only.
    private static let minimumContextLines = 0

    /// The number of leading bytes inspected for a NUL byte when classifying a file as binary.
    ///
    /// A file whose first 8 kibibytes contain a NUL byte is treated as binary
    /// and skipped, matching the Rust `files` tool's binary-detection window.
    private static let binarySniffWindowByteCount = 8 * 1024

    /// The byte value whose presence in the sniff window marks a file as binary.
    private static let nullByte: UInt8 = 0

    /// The inline flag prepended to the pattern to make matching case-insensitive.
    private static let caseInsensitivePrefix = "(?i)"

    /// The number of milliseconds in one second, used to report the elapsed duration.
    private static let millisecondsPerSecond = 1000.0

    // MARK: Output modes

    /// The `content` output-mode name: matched lines with their surrounding context.
    private static let contentModeName = "content"

    /// The `filesWithMatches` output-mode name: only the list of matching files.
    private static let filesWithMatchesModeName = "filesWithMatches"

    /// The `count` output-mode name: only the match and file totals.
    private static let countModeName = "count"

    /// The output mode used when the `outputMode` parameter is absent.
    private static let defaultOutputModeName = contentModeName

    /// A resolved output mode selecting which fields the result carries.
    private enum OutputMode {
        /// Matched lines and their surrounding context.
        case content
        /// Only the relative paths of the matching files.
        case filesWithMatches
        /// Only the match and file totals.
        case count
    }

    /// The mapping from an accepted `outputMode` name to its resolved ``OutputMode``.
    ///
    /// Output-mode resolution is data, not control flow: this table is the
    /// single place that enumerates the accepted names, so ``resolveOutputMode(_:)``
    /// is one lookup and the valid names in ``unknownOutputModeMessage`` cannot
    /// drift out of step with what the engine actually accepts.
    private static let outputModeMap: [String: OutputMode] = [
        contentModeName: .content,
        filesWithMatchesModeName: .filesWithMatches,
        countModeName: .count
    ]

    // MARK: File-type filter

    /// The mapping from a `type` filter name to the file extensions it selects.
    ///
    /// The file-type filter is data, not control flow: this table is the single
    /// place that enumerates the known types, so the filter is one lookup and
    /// the known-type list in ``unknownTypeMessage(_:)`` cannot drift out of
    /// step with what the engine actually accepts. Extensions are compared
    /// lowercased, so the values here are lowercase.
    private static let typeExtensionMap: [String: Set<String>] = [
        "rust": ["rs"],
        "py": ["py", "pyi"],
        "js": ["js", "jsx", "mjs", "cjs"],
        "ts": ["ts", "tsx"],
        "swift": ["swift"],
        "json": ["json"],
        "yaml": ["yaml", "yml"],
        "toml": ["toml"],
        "md": ["md", "markdown"],
        "c": ["c", "h"],
        "cpp": ["cpp", "cc", "cxx", "hpp", "hh"],
        "go": ["go"],
        "java": ["java"],
        "sh": ["sh", "bash"],
        "html": ["html", "htm"],
        "css": ["css"],
        "xml": ["xml"],
        "txt": ["txt"]
    ]

    /// Creates a grep engine.
    public init() {}

    // MARK: Execution

    /// Searches file contents for `pattern` and returns the mode-shaped result, or a corrective message.
    ///
    /// Resolves the output mode, the file-type filter, the `glob` filter, and
    /// the regular expression (returning a corrective for any invalid input);
    /// resolves the search target through `context`'s ``PathGuard`` (a single
    /// file short-circuits the walk, a directory is enumerated git-aware);
    /// skips binary files; matches each line; assembles context into hunks; and
    /// returns the mode-shaped ``GrepResult``. Every recoverable failure is
    /// returned as ``GrepOutput/corrective(_:)``; nothing here throws.
    ///
    /// - Parameters:
    ///   - pattern: the regular-expression pattern to search for.
    ///   - path: the file or directory to search, or `nil` to search the session root.
    ///   - glob: an optional filename filter applied to a directory walk.
    ///   - type: an optional file-type filter naming a known type (for example `swift`).
    ///   - caseInsensitive: whether matching ignores case; defaults to `false`.
    ///   - contextLines: the number of context lines on each side of a match, or
    ///     `nil` for the default of two; `0` returns match lines only.
    ///   - outputMode: the output mode name, or `nil` for the default `content` mode.
    ///   - context: the shared session context supplying the path guard and root.
    /// - Returns: the ``GrepOutput/content(_:)`` result on success, or a
    ///   ``GrepOutput/corrective(_:)`` message the model can act on.
    public func run(
        pattern: String,
        path: String? = nil,
        glob: String? = nil,
        type: String? = nil,
        caseInsensitive: Bool = false,
        contextLines: Int? = nil,
        outputMode: String? = nil,
        in context: FileContext
    ) -> GrepOutput {
        guard let mode = Self.resolveOutputMode(outputMode) else {
            return .corrective(Self.unknownOutputModeMessage)
        }

        let typeExtensions: Set<String>?
        if let type {
            guard let extensions = Self.typeExtensionMap[type.lowercased()] else {
                return .corrective(Self.unknownTypeMessage(type))
            }
            typeExtensions = extensions
        } else {
            typeExtensions = nil
        }

        let compiledGlob: GlobPattern?
        if let glob {
            do {
                compiledGlob = try GlobPattern(glob)
            } catch {
                return .corrective(Self.invalidGlobMessage(glob))
            }
        } else {
            compiledGlob = nil
        }

        let regex: Regex<AnyRegexOutput>
        do {
            regex = try Regex(caseInsensitive ? Self.caseInsensitivePrefix + pattern : pattern)
        } catch {
            return .corrective(Self.invalidPatternMessage(pattern))
        }

        let target: SearchTarget
        switch Self.resolveTarget(path: path, in: context) {
        case .success(let resolved):
            target = resolved
        case .failure(let violation):
            return .corrective(violation.message)
        }

        let sessionRoot = FileWalker.canonicalDirectory(context.root)
        let candidates = Self.candidateFiles(
            target: target,
            sessionRoot: sessionRoot,
            glob: compiledGlob,
            typeExtensions: typeExtensions
        )
        // Clamp to the match-lines-only floor so a negative `contextLines` cannot
        // silently drop matched lines from the content while `matchCount` still
        // counts them.
        let effectiveContextLines = max(Self.minimumContextLines, contextLines ?? Self.defaultContextLines)
        return .content(Self.search(candidates: candidates, regex: regex, contextLines: effectiveContextLines, mode: mode))
    }

    // MARK: Search

    /// Scans the candidate files and assembles the mode-shaped result.
    ///
    /// Reads and matches each candidate (skipping binary and unreadable files),
    /// records the matched lines and files, assembles the context hunks for the
    /// `content` mode, and stamps the wall-clock duration. Only matched lines
    /// count toward ``GrepResult/matchCount``; context lines never do.
    ///
    /// - Parameters:
    ///   - candidates: the files to scan, each with its session-relative path.
    ///   - regex: the compiled pattern.
    ///   - contextLines: the number of context lines on each side of a match.
    ///   - mode: the resolved output mode selecting the result shape.
    /// - Returns: the mode-shaped ``GrepResult``.
    private static func search(
        candidates: [Candidate],
        regex: Regex<AnyRegexOutput>,
        contextLines: Int,
        mode: OutputMode
    ) -> GrepResult {
        let start = Date()
        var allMatches: [GrepMatch] = []
        var matchedFiles: [String] = []
        var matchCount = 0

        for candidate in candidates {
            guard let scan = scanFile(path: candidate.absolutePath, regex: regex), !scan.matchLines.isEmpty else {
                continue
            }
            matchedFiles.append(candidate.relativePath)
            matchCount += scan.matchLines.count
            if mode == .content {
                allMatches.append(
                    contentsOf: buildMatches(
                        file: candidate.relativePath,
                        lines: scan.lines,
                        matchLines: scan.matchLines,
                        contextLines: contextLines
                    )
                )
            }
        }

        let elapsed = Date().timeIntervalSince(start) * millisecondsPerSecond
        return makeResult(mode: mode, matches: allMatches, files: matchedFiles, matchCount: matchCount, elapsedMilliseconds: elapsed)
    }

    /// Assembles the mode-shaped result from the gathered data.
    ///
    /// Selects which fields the result carries per the output mode: `content`
    /// carries the matches, `filesWithMatches` carries the files, and `count`
    /// carries neither. All modes carry the counts and elapsed duration.
    ///
    /// - Parameters:
    ///   - mode: the resolved output mode.
    ///   - matches: the assembled matched and context lines.
    ///   - files: the relative paths of the matching files.
    ///   - matchCount: the total number of matched lines.
    ///   - elapsedMilliseconds: the wall-clock duration of the search.
    /// - Returns: the mode-shaped ``GrepResult``.
    private static func makeResult(
        mode: OutputMode,
        matches: [GrepMatch],
        files: [String],
        matchCount: Int,
        elapsedMilliseconds: Double
    ) -> GrepResult {
        switch mode {
        case .content:
            return GrepResult(matches: matches, files: nil, matchCount: matchCount, fileCount: files.count, elapsedMilliseconds: elapsedMilliseconds)
        case .filesWithMatches:
            return GrepResult(matches: nil, files: files, matchCount: matchCount, fileCount: files.count, elapsedMilliseconds: elapsedMilliseconds)
        case .count:
            return GrepResult(matches: nil, files: nil, matchCount: matchCount, fileCount: files.count, elapsedMilliseconds: elapsedMilliseconds)
        }
    }

    // MARK: File scanning

    /// The per-file scan result: the matched line numbers and the file's line texts.
    private struct FileScan {
        /// The 1-based line numbers that matched the pattern, ascending.
        let matchLines: [Int]

        /// The file's line texts, terminators excluded, 1-based by array index plus one.
        let lines: [String]
    }

    /// Scans one file for matching lines, or `nil` when it is unreadable or binary.
    ///
    /// Reads the file's bytes, skips it when it is unreadable, binary (a NUL
    /// byte in the sniff window), or not valid UTF-8, then splits it into
    /// physical lines and records the 1-based numbers of the lines the pattern
    /// matches.
    ///
    /// - Parameters:
    ///   - path: the absolute path of the file to scan.
    ///   - regex: the compiled pattern.
    /// - Returns: the ``FileScan`` on success, or `nil` when the file is
    ///   unreadable or binary.
    private static func scanFile(path: String, regex: Regex<AnyRegexOutput>) -> FileScan? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        guard !isBinary(data) else { return nil }
        guard let content = String(data: data, encoding: .utf8) else { return nil }
        let lines = Hashline.splitLines(content).map(\.text)
        var matchLines: [Int] = []
        for (index, line) in lines.enumerated() where line.contains(regex) {
            matchLines.append(index + 1)
        }
        return FileScan(matchLines: matchLines, lines: lines)
    }

    /// Whether a file's leading bytes contain a NUL byte, marking it as binary.
    ///
    /// - Parameter data: the file's bytes.
    /// - Returns: `true` when the first ``binarySniffWindowByteCount`` bytes
    ///   contain a NUL byte.
    private static func isBinary(_ data: Data) -> Bool {
        data.prefix(binarySniffWindowByteCount).contains(nullByte)
    }

    // MARK: Context assembly

    /// Builds the matched and context lines for one file, grouped into hunks.
    ///
    /// Each match contributes a window of `contextLines` lines on each side;
    /// overlapping or contiguous windows merge into one hunk, and a gap between
    /// windows becomes a hunk boundary (the intervening lines are omitted). Each
    /// emitted line is flagged ``GrepMatch/isMatch`` according to whether it is
    /// one of the matched lines.
    ///
    /// - Parameters:
    ///   - file: the file's session-relative path.
    ///   - lines: the file's line texts.
    ///   - matchLines: the 1-based numbers of the matched lines, ascending.
    ///   - contextLines: the number of context lines on each side of a match.
    /// - Returns: the matched and context lines in ascending line order.
    private static func buildMatches(
        file: String,
        lines: [String],
        matchLines: [Int],
        contextLines: Int
    ) -> [GrepMatch] {
        let matchSet = Set(matchLines)
        var result: [GrepMatch] = []
        for hunk in hunkRanges(matchLines: matchLines, totalLines: lines.count, contextLines: contextLines) {
            for lineNumber in hunk {
                result.append(
                    GrepMatch(file: file, line: lineNumber, text: lines[lineNumber - 1], isMatch: matchSet.contains(lineNumber))
                )
            }
        }
        return result
    }

    /// Merges the per-match context windows into hunk ranges.
    ///
    /// A match at line `m` contributes the window `[m - contextLines, m + contextLines]`
    /// clamped to the file's bounds. A window that overlaps or directly abuts
    /// the previous hunk (its start is at most one past the hunk's end) extends
    /// that hunk; otherwise it opens a new hunk, and the gap between the two is
    /// the hunk boundary.
    ///
    /// - Parameters:
    ///   - matchLines: the 1-based matched line numbers, ascending.
    ///   - totalLines: the number of lines in the file.
    ///   - contextLines: the number of context lines on each side of a match.
    /// - Returns: the merged hunk ranges, ascending and non-overlapping.
    private static func hunkRanges(matchLines: [Int], totalLines: Int, contextLines: Int) -> [ClosedRange<Int>] {
        var ranges: [ClosedRange<Int>] = []
        for match in matchLines {
            let start = max(1, match - contextLines)
            let end = min(totalLines, match + contextLines)
            guard start <= end else { continue }
            if let last = ranges.last, start <= last.upperBound + 1 {
                ranges[ranges.count - 1] = last.lowerBound...max(last.upperBound, end)
            } else {
                ranges.append(start...end)
            }
        }
        return ranges
    }

    // MARK: Target resolution

    /// A resolved search target: a single file to grep directly, or a directory to walk.
    private enum SearchTarget {
        /// A single file, short-circuiting the directory walk.
        case singleFile(URL)

        /// A directory to enumerate git-aware.
        case directory(URL)
    }

    /// Resolves the search target from the requested path, or a corrective violation.
    ///
    /// A given `path` is validated through the context's ``PathGuard`` (which
    /// enforces the workspace boundary); an absent `path` targets the session
    /// root. A path that does not exist is refused; an existing directory is
    /// refused when it is the filesystem root and otherwise walked; an existing
    /// file short-circuits the walk. All paths are canonicalized so the walk and
    /// the session-relative paths share one prefix model.
    ///
    /// - Parameters:
    ///   - path: the requested file or directory, or `nil` for the session root.
    ///   - context: the shared session context supplying the path guard and root.
    /// - Returns: `.success` with the resolved ``SearchTarget``, or `.failure`
    ///   with a corrective ``PathViolation``.
    private static func resolveTarget(path: String?, in context: FileContext) -> Result<SearchTarget, PathViolation> {
        let resolved: URL
        if let path {
            switch context.pathGuard.validatePath(path) {
            case .success(let url):
                resolved = url
            case .failure(let violation):
                return .failure(violation)
            }
        } else {
            resolved = context.root
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory) else {
            return .failure(PathViolation(pathMissingMessage(path ?? resolved.path)))
        }
        guard isDirectory.boolValue else {
            return .success(.singleFile(FileWalker.canonicalDirectory(resolved)))
        }
        if case .failure(let violation) = context.pathGuard.rejectFilesystemRoot(resolved.path) {
            return .failure(violation)
        }
        return .success(.directory(FileWalker.canonicalDirectory(resolved)))
    }

    // MARK: Candidate gathering

    /// A candidate file to scan: its absolute path and its session-relative path.
    private struct Candidate {
        /// The candidate's absolute path on disk.
        let absolutePath: String

        /// The candidate's path relative to the session root, used in the result.
        let relativePath: String
    }

    /// Gathers the candidate files for a target, applying the filename and type filters.
    ///
    /// A single-file target short-circuits to that one file (no filtering — the
    /// caller named it explicitly). A directory target is enumerated through the
    /// shared git-aware ``FileWalker`` and then filtered by the `glob` filename
    /// filter and the file-type filter, sorted by session-relative path so the
    /// result is deterministic.
    ///
    /// - Parameters:
    ///   - target: the resolved search target.
    ///   - sessionRoot: the canonical session root the relative paths are formed against.
    ///   - glob: the optional compiled filename filter.
    ///   - typeExtensions: the optional set of extensions the file-type filter selects.
    /// - Returns: the candidate files to scan.
    private static func candidateFiles(
        target: SearchTarget,
        sessionRoot: URL,
        glob: GlobPattern?,
        typeExtensions: Set<String>?
    ) -> [Candidate] {
        switch target {
        case .singleFile(let file):
            let relativePath = FileWalker.relativePath(ofAbsolute: file.path, under: sessionRoot.path)
                ?? URL(fileURLWithPath: file.path).lastPathComponent
            return [Candidate(absolutePath: file.path, relativePath: relativePath)]
        case .directory(let walkRoot):
            return directoryCandidates(walkRoot: walkRoot, sessionRoot: sessionRoot, glob: glob, typeExtensions: typeExtensions)
        }
    }

    /// Gathers and filters the candidate files under a directory walk root.
    ///
    /// - Parameters:
    ///   - walkRoot: the canonical directory to enumerate.
    ///   - sessionRoot: the canonical session root the relative paths are formed against.
    ///   - glob: the optional compiled filename filter, matched against the walk-relative path.
    ///   - typeExtensions: the optional set of extensions the file-type filter selects.
    /// - Returns: the filtered candidate files, sorted by session-relative path.
    private static func directoryCandidates(
        walkRoot: URL,
        sessionRoot: URL,
        glob: GlobPattern?,
        typeExtensions: Set<String>?
    ) -> [Candidate] {
        var candidates: [Candidate] = []
        for absolute in FileWalker.collectFiles(walkRoot: walkRoot, respectGitIgnore: true) {
            guard let relativeToWalk = FileWalker.relativePath(ofAbsolute: absolute, under: walkRoot.path) else { continue }
            if let glob, !glob.matches(relativePath: relativeToWalk, caseSensitive: false) { continue }
            if let typeExtensions, !typeExtensions.contains(fileExtension(absolute)) { continue }
            guard let relativeToSession = FileWalker.relativePath(ofAbsolute: absolute, under: sessionRoot.path) else { continue }
            candidates.append(Candidate(absolutePath: absolute, relativePath: relativeToSession))
        }
        return candidates.sorted { $0.relativePath < $1.relativePath }
    }

    /// The lowercased filename extension of a path, or the empty string when there is none.
    ///
    /// - Parameter path: the absolute path whose extension to read.
    /// - Returns: the lowercased extension, without the leading dot.
    private static func fileExtension(_ path: String) -> String {
        URL(fileURLWithPath: path).pathExtension.lowercased()
    }

    // MARK: Filter resolution

    /// Resolves the requested output-mode name to an ``OutputMode``, or `nil` when unknown.
    ///
    /// An absent name resolves to the default (`content`); any other name is
    /// looked up in ``outputModeMap``, so the accepted set lives in one place.
    ///
    /// - Parameter name: the requested output-mode name, or `nil`.
    /// - Returns: the resolved output mode, or `nil` when the name is unrecognized.
    private static func resolveOutputMode(_ name: String?) -> OutputMode? {
        outputModeMap[name ?? defaultOutputModeName]
    }

    // MARK: Corrective messages

    /// A corrective message for a pattern that is not a valid regular expression.
    ///
    /// - Parameter pattern: the rejected pattern.
    /// - Returns: the corrective message.
    private static func invalidPatternMessage(_ pattern: String) -> String {
        "The `pattern` is not a valid regular expression: \(pattern)"
    }

    /// A corrective message for a `glob` filter that is not a valid glob pattern.
    ///
    /// - Parameter glob: the rejected glob filter.
    /// - Returns: the corrective message.
    private static func invalidGlobMessage(_ glob: String) -> String {
        "The `glob` filter is not a valid glob pattern: \(glob)"
    }

    /// A corrective message for a search path that does not exist.
    ///
    /// - Parameter path: the requested search path.
    /// - Returns: the corrective message.
    private static func pathMissingMessage(_ path: String) -> String {
        "The search path does not exist: \(path)"
    }

    /// A corrective message naming the valid `outputMode` values.
    ///
    /// The valid names are derived from the authoritative ``outputModeMap`` keys,
    /// so the message cannot drift out of step with the modes the engine accepts.
    private static var unknownOutputModeMessage: String {
        let names = outputModeMap.keys.sorted().joined(separator: ", ")
        return "The `outputMode` parameter must be one of: \(names)."
    }

    /// A corrective message for an unknown file type, naming the known types.
    ///
    /// The known types are derived from the authoritative ``typeExtensionMap``
    /// keys, so the message cannot drift out of step with the types the engine
    /// accepts.
    ///
    /// - Parameter type: the rejected file type.
    /// - Returns: the corrective message.
    private static func unknownTypeMessage(_ type: String) -> String {
        let names = typeExtensionMap.keys.sorted().joined(separator: ", ")
        return "The `type` parameter is not a known file type: \(type). Known types are: \(names)."
    }
}
