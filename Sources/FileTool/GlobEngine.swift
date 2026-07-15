import Darwin
import Foundation

/// The successful result of a `glob files` operation: the matching paths, newest first.
///
/// The ``files`` are paths relative to the session root, sorted by modification
/// time with the most recently modified first; ``total`` is the full count of
/// matching files found (before any cap), and ``capped`` reports whether that
/// total exceeded the engine's result cap so ``files`` is a strict prefix of the
/// matches rather than the whole set. When ``capped`` is `true`, ``files``
/// carries exactly the cap's worth of the newest matches.
public struct GlobResult: Encodable, Sendable {
    /// The glob pattern that produced this result.
    public let pattern: String

    /// The matching paths relative to the session root, most recently modified first.
    public let files: [String]

    /// The total number of matching files found, before any cap is applied.
    public let total: Int

    /// Whether ``total`` exceeded the result cap, so ``files`` is a truncated prefix.
    public let capped: Bool

    /// Creates a glob result.
    ///
    /// - Parameters:
    ///   - pattern: the glob pattern that produced this result.
    ///   - files: the matching paths relative to the session root, newest first.
    ///   - total: the total number of matching files found, before any cap.
    ///   - capped: whether the total exceeded the cap, truncating ``files``.
    public init(pattern: String, files: [String], total: Int, capped: Bool) {
        self.pattern = pattern
        self.files = files
        self.total = total
        self.capped = capped
    }
}

/// The outcome of a `glob files` operation: either the matches or a corrective message.
///
/// The operation follows the upstream *return-don't-throw* convention (the same
/// convention ``ReadOutput``, ``WriteOutput``, and ``PathViolation`` embody): an
/// over-length pattern, an invalid glob, an unscoped broad pattern, a rejected
/// search root, or a missing directory is surfaced as a ``corrective(_:)``
/// message the model reads and acts on within the turn, never thrown. Throwing
/// from an operation's `execute(in:)` is fatal to the turn, so every recoverable
/// condition returns a value instead.
public enum GlobOutput: Encodable, Sendable {
    /// A successful glob carrying the ``GlobResult``.
    case content(GlobResult)

    /// A recoverable failure carrying a corrective message for the model.
    case corrective(String)

    /// The coding keys for the ``corrective(_:)`` encoding.
    private enum CodingKeys: String, CodingKey {
        /// The corrective-message field.
        case corrective
    }

    /// Encodes the outcome.
    ///
    /// A ``content(_:)`` outcome encodes the ``GlobResult`` inline (its
    /// `pattern`, `files`, `total`, and `capped` fields); a ``corrective(_:)``
    /// outcome encodes a single `corrective` field carrying the message.
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

/// Finds files whose relative path matches a glob pattern, newest first.
///
/// The engine validates the pattern (length, syntax, and — when the walk is
/// unscoped by a `path` — the broad-pattern guard), resolves and bounds the
/// search root through the context's ``PathGuard`` (refusing the filesystem
/// root), enumerates candidate files (via `git ls-files` when a repository is
/// present and gitignore is respected, else a plain `FileManager` walk), matches
/// each candidate against the pattern, and returns the matches relative to the
/// session root sorted by modification time with the newest first.
///
/// The result cap is injected through ``init(maxResults:)`` so tests can drive
/// the capping path with a small value; when the number of matches exceeds the
/// cap, exactly the cap's worth of the newest matches is returned and
/// ``GlobResult/capped`` is set. Every recoverable failure is returned as
/// ``GlobOutput/corrective(_:)``; nothing here throws.
public struct GlobEngine: Sendable {
    // MARK: Configuration

    /// The default maximum number of matching files returned, matching the Rust `files` tool.
    public static let defaultMaximumResults = 10_000

    /// The maximum accepted pattern length in characters, matching the Rust `files` tool.
    private static let maximumPatternLength = 1000

    /// The maximum number of matching files this engine returns before capping.
    private let maximumResults: Int

    /// Creates a glob engine with a result cap.
    ///
    /// - Parameter maxResults: the maximum number of matching files to return;
    ///   defaults to the 10,000-file cap of the Rust `files` tool. This is the
    ///   injectable seam tests use with a small value to exercise capping.
    public init(maxResults: Int = defaultMaximumResults) {
        self.maximumResults = maxResults
    }

    // MARK: Execution

    /// Finds the files matching `pattern` and returns them newest first, or a corrective message.
    ///
    /// Validates the pattern length, the pattern syntax, and — when `path` is
    /// `nil` — the broad-pattern guard; resolves and bounds the search root
    /// through `context`'s ``PathGuard`` (refusing the filesystem root and a
    /// nonexistent directory); enumerates candidate files; matches each against
    /// the pattern (filename-only for a pattern with no `/` and no `**`, else the
    /// relative path); and returns the matches relative to the session root
    /// sorted by modification time, newest first, capped at ``init(maxResults:)``.
    ///
    /// - Parameters:
    ///   - pattern: the glob pattern to match.
    ///   - path: the directory to search, or `nil` to search the session root.
    ///   - caseSensitive: whether matching is case-sensitive; defaults to `false`.
    ///   - respectGitIgnore: whether a present repository's ignore rules are
    ///     honored (via `git ls-files`); defaults to `true`.
    ///   - context: the shared session context supplying the path guard and root.
    /// - Returns: the ``GlobOutput/content(_:)`` matches on success, or a
    ///   ``GlobOutput/corrective(_:)`` message the model can act on.
    public func run(
        pattern: String,
        path: String? = nil,
        caseSensitive: Bool = false,
        respectGitIgnore: Bool = true,
        in context: FileContext
    ) -> GlobOutput {
        if pattern.count > Self.maximumPatternLength { return .corrective(Self.patternTooLongMessage) }
        if path == nil, Self.isBroad(pattern) { return .corrective(Self.broadPatternMessage(pattern)) }

        let compiled: GlobPattern
        do {
            compiled = try GlobPattern(pattern)
        } catch {
            return .corrective(Self.invalidPatternMessage(pattern))
        }

        let walkRoot: URL
        switch Self.resolveSearchRoot(path: path, in: context) {
        case .success(let url):
            walkRoot = url
        case .failure(let violation):
            return .corrective(violation.message)
        }

        let sessionRoot = Self.canonicalDirectory(context.root)
        let matches = Self.collectMatches(
            compiled: compiled,
            caseSensitive: caseSensitive,
            respectGitIgnore: respectGitIgnore,
            walkRoot: walkRoot,
            sessionRoot: sessionRoot
        )

        let total = matches.count
        let capped = total > maximumResults
        let files = (capped ? Array(matches.prefix(maximumResults)) : matches).map(\.relativePath)
        return .content(GlobResult(pattern: pattern, files: files, total: total, capped: capped))
    }

    // MARK: Search-root resolution

    /// Resolves and bounds the search root, returning the canonical directory URL or a corrective message.
    ///
    /// A given `path` is validated through the context's ``PathGuard`` (which
    /// enforces the workspace boundary); an absent `path` searches the session
    /// root directly. The resolved root is then refused if it is the filesystem
    /// root and rejected if it does not name an existing directory.
    ///
    /// - Parameters:
    ///   - path: the requested search directory, or `nil` for the session root.
    ///   - context: the shared session context supplying the path guard and root.
    /// - Returns: `.success` with the canonical search-root URL, or `.failure`
    ///   with a corrective ``PathViolation``.
    private static func resolveSearchRoot(path: String?, in context: FileContext) -> Result<URL, PathViolation> {
        let resolved: URL
        if let path {
            switch context.pathGuard.validate(path, for: .directory) {
            case .success(let url):
                resolved = url
            case .failure(let violation):
                return .failure(violation)
            }
        } else {
            resolved = context.root
        }

        if case .failure(let violation) = context.pathGuard.rejectFilesystemRoot(resolved.path) {
            return .failure(violation)
        }

        let canonical = canonicalDirectory(resolved)
        guard isDirectory(canonical.path) else {
            return .failure(PathViolation(directoryMissingMessage(path ?? canonical.path)))
        }
        return .success(canonical)
    }

    // MARK: Matching

    /// A matching file: its path relative to the session root and its modification date.
    private struct Match {
        /// The matching file's path relative to the session root.
        let relativePath: String

        /// The matching file's modification date, used to order results.
        let modificationDate: Date
    }

    /// Collects and orders the files under `walkRoot` matching the compiled pattern.
    ///
    /// Enumerates candidate files, matches each against the pattern relative to
    /// `walkRoot` (filename-only or full relative path per the pattern's shape),
    /// keeps the matches as paths relative to `sessionRoot` paired with their
    /// modification dates, and sorts them by date descending with a path
    /// tie-break so the order is deterministic.
    ///
    /// - Parameters:
    ///   - compiled: the compiled glob pattern.
    ///   - caseSensitive: whether matching is case-sensitive.
    ///   - respectGitIgnore: whether a present repository's ignore rules are honored.
    ///   - walkRoot: the canonical search root.
    ///   - sessionRoot: the canonical session root the returned paths are relative to.
    /// - Returns: the matches sorted newest first.
    private static func collectMatches(
        compiled: GlobPattern,
        caseSensitive: Bool,
        respectGitIgnore: Bool,
        walkRoot: URL,
        sessionRoot: URL
    ) -> [Match] {
        var matches: [Match] = []
        for absolute in collectFiles(walkRoot: walkRoot, respectGitIgnore: respectGitIgnore) {
            guard let relativeToWalk = relativePath(ofAbsolute: absolute, under: walkRoot.path) else { continue }
            guard compiled.matches(relativePath: relativeToWalk, caseSensitive: caseSensitive) else { continue }
            guard let relativeToSession = relativePath(ofAbsolute: absolute, under: sessionRoot.path) else { continue }
            guard let date = modificationDate(ofAbsolute: absolute) else { continue }
            matches.append(Match(relativePath: relativeToSession, modificationDate: date))
        }
        matches.sort { lhs, rhs in
            lhs.modificationDate == rhs.modificationDate
                ? lhs.relativePath < rhs.relativePath
                : lhs.modificationDate > rhs.modificationDate
        }
        return matches
    }

    // MARK: Filesystem walk

    /// Enumerates the candidate files under a search root as absolute paths.
    ///
    /// When `respectGitIgnore` is set and `walkRoot` is inside a git repository,
    /// the git-aware listing (`git ls-files --cached --others --exclude-standard`)
    /// is used so ignored files are skipped without hand-rolling gitignore
    /// parsing; otherwise, and whenever git is unavailable or the directory is
    /// not a repository, a plain `FileManager` walk is used.
    ///
    /// - Parameters:
    ///   - walkRoot: the canonical search root.
    ///   - respectGitIgnore: whether to prefer the git-aware listing.
    /// - Returns: the absolute paths of the candidate regular files.
    private static func collectFiles(walkRoot: URL, respectGitIgnore: Bool) -> [String] {
        if respectGitIgnore, let relativePaths = gitListedFiles(in: walkRoot) {
            return relativePaths.map { walkRoot.path + "/" + $0 }
        }
        return enumeratedRegularFiles(under: walkRoot)
    }

    /// The git-listed files under a directory, or `nil` when it is not a repository.
    ///
    /// Runs `git ls-files --cached --others --exclude-standard -z` with the given
    /// directory as the working directory, so the output is the repository's
    /// tracked and untracked-but-not-ignored files under that directory, one
    /// NUL-separated relative path each. A nonzero exit (most commonly "not a git
    /// repository") or a launch failure yields `nil`, signaling the caller to
    /// fall back to a plain walk.
    ///
    /// - Parameter directory: the directory to list, used as git's working directory.
    /// - Returns: the NUL-separated relative paths, or `nil` when git is
    ///   unavailable or the directory is not a repository.
    private static func gitListedFiles(in directory: URL) -> [String]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"]
        process.currentDirectoryURL = directory
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.standardOutput = standardOutput
        process.standardError = standardError

        do {
            try process.run()
        } catch {
            return nil
        }
        let data = standardOutput.fileHandleForReading.readDataToEndOfFile()
        _ = try? standardError.fileHandleForReading.readToEnd()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        let text = String(decoding: data, as: UTF8.self)
        return text.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
    }

    /// The absolute paths of the regular files under a directory, walked recursively.
    ///
    /// Directories are traversed but only regular files are returned, so the
    /// result is directly comparable to the git-aware listing.
    ///
    /// - Parameter root: the canonical search root to walk.
    /// - Returns: the absolute paths of the regular files found.
    private static func enumeratedRegularFiles(under root: URL) -> [String] {
        guard
            let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [],
                errorHandler: nil
            )
        else {
            return []
        }
        var paths: [String] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            if values?.isRegularFile == true { paths.append(url.path) }
        }
        return paths
    }

    // MARK: Filesystem probes

    /// The canonical directory URL for a path, with symlinks fully resolved.
    ///
    /// Uses `realpath`, which resolves the firmlinks (`/var`, `/tmp`) that
    /// `URL.resolvingSymlinksInPath()` leaves untouched, so the returned prefix
    /// matches the paths a `FileManager` enumerator yields. Falls back to the
    /// input URL when the path cannot be resolved (for example a nonexistent
    /// directory, which the caller rejects separately).
    ///
    /// - Parameter url: the directory URL to canonicalize.
    /// - Returns: the canonical directory URL, or `url` when `realpath` fails.
    private static func canonicalDirectory(_ url: URL) -> URL {
        guard let resolved = realpath(url.path, nil) else { return url }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }

    /// Whether a path names an existing directory.
    ///
    /// - Parameter path: the path to test.
    /// - Returns: `true` when the path exists and is a directory.
    private static func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// The modification date of a file, or `nil` when it cannot be read.
    ///
    /// - Parameter path: the absolute path of the file.
    /// - Returns: the modification date, or `nil` when the file is missing or
    ///   its attributes cannot be read.
    private static func modificationDate(ofAbsolute path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    /// The path of `absolute` relative to `root`, or `nil` when it is not under `root`.
    ///
    /// Compares the two paths component-wise (not as string prefixes) so
    /// `/foobar` is not considered inside `/foo`, and rejoins the remaining
    /// components with `/`.
    ///
    /// - Parameters:
    ///   - absolute: the absolute path to relativize.
    ///   - root: the absolute root the path should be under.
    /// - Returns: the relative path, or `nil` when `absolute` is not under `root`.
    private static func relativePath(ofAbsolute absolute: String, under root: String) -> String? {
        let rootComponents = pathComponents(root)
        let absoluteComponents = pathComponents(absolute)
        guard absoluteComponents.count >= rootComponents.count else { return nil }
        guard Array(absoluteComponents.prefix(rootComponents.count)) == rootComponents else { return nil }
        return absoluteComponents.dropFirst(rootComponents.count).joined(separator: "/")
    }

    /// The non-empty path components of a path (leading, trailing, and repeated slashes dropped).
    ///
    /// - Parameter path: the path to split.
    /// - Returns: the path's non-empty components.
    private static func pathComponents(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    // MARK: Broad-pattern guard

    /// The literal prefix of the broad `**/*.ext` bare-extension pattern shape.
    private static let broadExtensionPrefix = "**/*."

    /// The glob metacharacters that, if present in a bare extension, disqualify the broad shape.
    private static let globMetacharacters: Set<Character> = ["*", "?", "[", "]", "/"]

    /// A broad-pattern rule: either an exact literal or the `**/*.ext` bare-extension shape.
    ///
    /// The broad set is expressed as data — a table of these rules interpreted by
    /// the single ``isBroad(_:)`` code path — rather than parallel branches, so a
    /// new broad shape is one table entry, not another `if`.
    private enum BroadPatternRule {
        /// A pattern equal to a fixed literal (for example `*` or `**/*`).
        case exact(String)

        /// A pattern of the `**/*.ext` shape: a bare, wildcard-free extension.
        case bareExtension

        /// Whether `pattern` is broad under this rule.
        ///
        /// - Parameter pattern: the pattern to test.
        /// - Returns: `true` when `pattern` is broad under this rule.
        func matches(_ pattern: String) -> Bool {
            switch self {
            case .exact(let literal):
                return pattern == literal
            case .bareExtension:
                return GlobEngine.isBareExtensionGlob(pattern)
            }
        }
    }

    /// The broad patterns rejected when the walk is unscoped by a `path`.
    ///
    /// The literals plus the bare-extension shape are the set refused without a
    /// scoping `path`. A bare `**` is included alongside `**/*` because it too
    /// matches every file under the walk root (``GlobPattern`` reduces a lone
    /// recursive component to "match anything"), so leaving it out would let the
    /// broadest possible pattern slip past a guard whose whole purpose is to
    /// prevent whole-session walks.
    private static let broadPatternRules: [BroadPatternRule] = [
        .exact("*"),
        .exact("**"),
        .exact("**/*"),
        .exact("*.*"),
        .bareExtension
    ]

    /// Whether a pattern is too broad to search an unscoped session root.
    ///
    /// - Parameter pattern: the raw pattern to test.
    /// - Returns: `true` when any ``broadPatternRules`` entry matches.
    private static func isBroad(_ pattern: String) -> Bool {
        broadPatternRules.contains { $0.matches(pattern) }
    }

    /// Whether a pattern is the broad `**/*.ext` shape: `**/*.` then a bare, wildcard-free extension.
    ///
    /// - Parameter pattern: the raw pattern to test.
    /// - Returns: `true` when `pattern` is `**/*.` followed by a non-empty run of
    ///   characters containing no glob metacharacter.
    private static func isBareExtensionGlob(_ pattern: String) -> Bool {
        guard pattern.hasPrefix(broadExtensionPrefix) else { return false }
        let ext = pattern.dropFirst(broadExtensionPrefix.count)
        guard !ext.isEmpty else { return false }
        return !ext.contains(where: globMetacharacters.contains)
    }

    // MARK: Corrective messages

    /// The corrective message naming the pattern-length cap.
    private static var patternTooLongMessage: String {
        "The `pattern` parameter must be at most \(maximumPatternLength) characters."
    }

    /// A corrective message telling the caller to scope a broad pattern with a `path`.
    ///
    /// - Parameter pattern: the rejected broad pattern.
    /// - Returns: the corrective message.
    private static func broadPatternMessage(_ pattern: String) -> String {
        "The pattern `\(pattern)` is too broad to search the whole session; provide a `path` to scope the search."
    }

    /// A corrective message for a pattern that is not valid glob syntax.
    ///
    /// - Parameter pattern: the rejected pattern.
    /// - Returns: the corrective message.
    private static func invalidPatternMessage(_ pattern: String) -> String {
        "The `pattern` is not a valid glob pattern: \(pattern)"
    }

    /// A corrective message for a search directory that does not exist.
    ///
    /// - Parameter path: the requested search directory.
    /// - Returns: the corrective message.
    private static func directoryMissingMessage(_ path: String) -> String {
        "The search directory does not exist: \(path)"
    }
}

/// A rejected glob pattern, thrown while compiling invalid syntax.
///
/// The only recoverable condition inside the engine that is expressed as a
/// thrown error rather than a returned value: it is caught at the single
/// ``GlobPattern`` construction site in ``GlobEngine`` and turned into a
/// corrective message there, keeping the operation's public surface faithful to
/// the *return-don't-throw* convention.
struct GlobPatternError: Error {}

/// A compiled glob pattern that matches a relative path or a filename.
///
/// A direct port of the Rust `glob` crate's semantics the `files` tool relies
/// on: `*` matches any run of characters within one path component, `?` matches
/// one such character, `[...]` matches a character class (with `!` or `^`
/// negation and `a-z` ranges), and a `**` component matches any number of path
/// components including zero. A pattern with no `/` and no `**` is
/// ``isFilenameOnly`` and matches against the candidate's filename alone; any
/// other pattern matches against the whole path relative to the search root.
struct GlobPattern {
    /// One path-separated component of a compiled pattern.
    private enum Component {
        /// A `**` component, matching any number of path components including zero.
        case recursive

        /// A single-component pattern, matching exactly one path component.
        case segment([Token])
    }

    /// One token within a single-component pattern.
    private enum Token {
        /// The `*` wildcard, matching any run of characters within the component.
        case anyRun

        /// The `?` wildcard, matching exactly one character within the component.
        case singleCharacter

        /// A literal character, matched with the requested case sensitivity.
        case literal(Character)

        /// A `[...]` character class.
        case characterClass(CharacterClass)
    }

    /// A parsed `[...]` character class: its members, ranges, and negation.
    private struct CharacterClass {
        /// Whether the class is negated (`[!...]` or `[^...]`).
        let negated: Bool

        /// The individual member characters.
        let characters: [Character]

        /// The inclusive character ranges, each a `(low, high)` pair.
        let ranges: [(Character, Character)]

        /// Whether a character is a member of this class, under the requested case sensitivity.
        ///
        /// - Parameters:
        ///   - character: the character to test.
        ///   - caseSensitive: whether membership is case-sensitive.
        /// - Returns: `true` when `character` is in the class (accounting for negation).
        func contains(_ character: Character, caseSensitive: Bool) -> Bool {
            var hit = characters.contains { GlobPattern.charactersEqual($0, character, caseSensitive: caseSensitive) }
            if !hit {
                hit = ranges.contains { GlobPattern.character(character, inRange: $0.0, through: $0.1, caseSensitive: caseSensitive) }
            }
            return negated ? !hit : hit
        }
    }

    /// The compiled path components of the pattern.
    private let components: [Component]

    /// Whether the pattern targets the filename alone (no `/` and no `**`).
    let isFilenameOnly: Bool

    /// Compiles a raw glob pattern.
    ///
    /// - Parameter pattern: the raw glob pattern.
    /// - Throws: ``GlobPatternError`` when the pattern contains invalid syntax
    ///   (currently an unterminated `[` character class).
    init(_ pattern: String) throws {
        isFilenameOnly = !pattern.contains("/") && !pattern.contains("**")
        var compiled: [Component] = []
        for part in pattern.split(separator: "/", omittingEmptySubsequences: false) {
            if part == "**" {
                compiled.append(.recursive)
            } else {
                compiled.append(.segment(try Self.compileSegment(part)))
            }
        }
        components = compiled.isEmpty ? [.segment([])] : compiled
    }

    /// Whether a relative path matches this pattern under the requested case sensitivity.
    ///
    /// A ``isFilenameOnly`` pattern matches against the path's last component; any
    /// other pattern matches against the whole path split into components.
    ///
    /// - Parameters:
    ///   - relativePath: the candidate path relative to the search root.
    ///   - caseSensitive: whether matching is case-sensitive.
    /// - Returns: `true` when the path matches.
    func matches(relativePath: String, caseSensitive: Bool) -> Bool {
        let pathComponents = relativePath.split(separator: "/", omittingEmptySubsequences: true)
        if isFilenameOnly {
            guard case .segment(let tokens) = components[0], let filename = pathComponents.last else { return false }
            return Self.segmentMatches(tokens, Array(filename), caseSensitive: caseSensitive)
        }
        return Self.componentsMatch(components[...], pathComponents[...], caseSensitive: caseSensitive)
    }

    // MARK: Component matching

    /// Whether the pattern components match the path components, handling `**` recursion.
    ///
    /// A `**` component matches zero or more path components by trying every
    /// suffix; a segment component matches exactly one path component.
    ///
    /// - Parameters:
    ///   - patternComponents: the remaining pattern components.
    ///   - pathComponents: the remaining path components.
    ///   - caseSensitive: whether matching is case-sensitive.
    /// - Returns: `true` when the components match.
    private static func componentsMatch(
        _ patternComponents: ArraySlice<Component>,
        _ pathComponents: ArraySlice<Substring>,
        caseSensitive: Bool
    ) -> Bool {
        guard let first = patternComponents.first else { return pathComponents.isEmpty }
        switch first {
        case .recursive:
            return tryRecursiveMatches(patternComponents.dropFirst(), pathComponents, caseSensitive: caseSensitive)
        case .segment(let tokens):
            guard let head = pathComponents.first,
                segmentMatches(tokens, Array(head), caseSensitive: caseSensitive)
            else {
                return false
            }
            return componentsMatch(patternComponents.dropFirst(), pathComponents.dropFirst(), caseSensitive: caseSensitive)
        }
    }

    /// Whether a `**` component followed by `rest` matches `pathComponents`.
    ///
    /// A `**` matches any number of path components including zero, so this
    /// tries `rest` against every suffix of `pathComponents` — from the whole
    /// slice down to the empty tail — and succeeds as soon as one suffix
    /// matches. Extracting this backtracking loop keeps ``componentsMatch(_:_:caseSensitive:)``
    /// shallow rather than nesting the loop inside its `switch`.
    ///
    /// - Parameters:
    ///   - rest: the pattern components following the `**`.
    ///   - pathComponents: the path components the `**` and `rest` must cover.
    ///   - caseSensitive: whether matching is case-sensitive.
    /// - Returns: `true` when `rest` matches some suffix of `pathComponents`.
    private static func tryRecursiveMatches(
        _ rest: ArraySlice<Component>,
        _ pathComponents: ArraySlice<Substring>,
        caseSensitive: Bool
    ) -> Bool {
        var suffix = pathComponents
        while true {
            if componentsMatch(rest, suffix, caseSensitive: caseSensitive) { return true }
            guard !suffix.isEmpty else { return false }
            suffix = suffix.dropFirst()
        }
    }

    /// Whether a single-component token sequence matches a component's characters.
    ///
    /// Backtracks over `*` runs; `?`, literals, and character classes each consume
    /// one character. Filenames are short, so the simple backtracking match is
    /// adequate.
    ///
    /// - Parameters:
    ///   - tokens: the compiled tokens of one pattern component.
    ///   - characters: the candidate component's characters.
    ///   - caseSensitive: whether matching is case-sensitive.
    /// - Returns: `true` when the tokens match the characters exactly.
    private static func segmentMatches(_ tokens: [Token], _ characters: [Character], caseSensitive: Bool) -> Bool {
        func match(_ tokenIndex: Int, _ characterIndex: Int) -> Bool {
            guard tokenIndex < tokens.count else { return characterIndex == characters.count }
            switch tokens[tokenIndex] {
            case .anyRun:
                var next = characterIndex
                while true {
                    if match(tokenIndex + 1, next) { return true }
                    guard next < characters.count else { return false }
                    next += 1
                }
            case .singleCharacter:
                return characterIndex < characters.count && match(tokenIndex + 1, characterIndex + 1)
            case .literal(let expected):
                return characterIndex < characters.count
                    && charactersEqual(expected, characters[characterIndex], caseSensitive: caseSensitive)
                    && match(tokenIndex + 1, characterIndex + 1)
            case .characterClass(let characterClass):
                return characterIndex < characters.count
                    && characterClass.contains(characters[characterIndex], caseSensitive: caseSensitive)
                    && match(tokenIndex + 1, characterIndex + 1)
            }
        }
        return match(0, 0)
    }

    // MARK: Compilation

    /// Compiles one path component into a token sequence.
    ///
    /// Collapses consecutive `*` into a single ``Token/anyRun`` so the backtracking
    /// matcher does not branch redundantly.
    ///
    /// - Parameter part: the raw component text.
    /// - Returns: the compiled tokens.
    /// - Throws: ``GlobPatternError`` when a `[` character class is unterminated.
    private static func compileSegment(_ part: Substring) throws -> [Token] {
        let characters = Array(part)
        var tokens: [Token] = []
        var index = 0
        while index < characters.count {
            switch characters[index] {
            case "*":
                if case .anyRun = tokens.last {} else { tokens.append(.anyRun) }
                index += 1
            case "?":
                tokens.append(.singleCharacter)
                index += 1
            case "[":
                let (characterClass, nextIndex) = try parseCharacterClass(characters, from: index)
                tokens.append(.characterClass(characterClass))
                index = nextIndex
            default:
                tokens.append(.literal(characters[index]))
                index += 1
            }
        }
        return tokens
    }

    /// Parses a `[...]` character class starting at the opening bracket.
    ///
    /// Honors a leading `!` or `^` negation, treats a `]` immediately after the
    /// opening (or negation) as a literal member, and reads `a-z` ranges.
    ///
    /// - Parameters:
    ///   - characters: the component's characters.
    ///   - start: the index of the opening `[`.
    /// - Returns: the parsed class and the index just past the closing `]`.
    /// - Throws: ``GlobPatternError`` when no closing `]` is found.
    private static func parseCharacterClass(
        _ characters: [Character],
        from start: Int
    ) throws -> (CharacterClass, Int) {
        var index = start + 1
        var negated = false
        if index < characters.count, characters[index] == "!" || characters[index] == "^" {
            negated = true
            index += 1
        }

        var members: [Character] = []
        var ranges: [(Character, Character)] = []
        if index < characters.count, characters[index] == "]" {
            members.append("]")
            index += 1
        }

        while index < characters.count, characters[index] != "]" {
            if index + 2 < characters.count, characters[index + 1] == "-", characters[index + 2] != "]" {
                ranges.append((characters[index], characters[index + 2]))
                index += 3
            } else {
                members.append(characters[index])
                index += 1
            }
        }

        guard index < characters.count, characters[index] == "]" else { throw GlobPatternError() }
        return (CharacterClass(negated: negated, characters: members, ranges: ranges), index + 1)
    }

    // MARK: Case-aware comparison

    /// Whether two characters are equal under the requested case sensitivity.
    ///
    /// - Parameters:
    ///   - lhs: the first character.
    ///   - rhs: the second character.
    ///   - caseSensitive: whether the comparison is case-sensitive.
    /// - Returns: `true` when the characters are equal (case-folded when insensitive).
    private static func charactersEqual(_ lhs: Character, _ rhs: Character, caseSensitive: Bool) -> Bool {
        caseSensitive ? lhs == rhs : lhs.lowercased() == rhs.lowercased()
    }

    /// Whether a character falls within an inclusive range under the requested case sensitivity.
    ///
    /// Compares by the first Unicode scalar; when case-insensitive, both the
    /// lowercase and uppercase forms of the character are tried against the range.
    ///
    /// - Parameters:
    ///   - character: the character to test.
    ///   - low: the inclusive low bound.
    ///   - high: the inclusive high bound.
    ///   - caseSensitive: whether the comparison is case-sensitive.
    /// - Returns: `true` when the character is within the range.
    private static func character(
        _ character: Character,
        inRange low: Character,
        through high: Character,
        caseSensitive: Bool
    ) -> Bool {
        func scalarInRange(_ candidate: Character) -> Bool {
            guard
                let value = candidate.unicodeScalars.first?.value,
                let lowValue = low.unicodeScalars.first?.value,
                let highValue = high.unicodeScalars.first?.value
            else {
                return false
            }
            return value >= lowValue && value <= highValue
        }
        if scalarInRange(character) { return true }
        guard !caseSensitive else { return false }
        return scalarInRange(Character(character.lowercased())) || scalarInRange(Character(character.uppercased()))
    }
}
