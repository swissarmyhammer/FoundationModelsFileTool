import Darwin
import Foundation

/// A rejected path validation, carrying the corrective message the model reads.
///
/// The validation stack follows the upstream *return-don't-throw* pattern: a
/// violation is returned as a `Result` failure, never raised, so a language
/// model can read the message and correct the path within the same turn. The
/// type conforms to `Error` only so it can be a `Result` failure — it is never
/// thrown.
public struct PathViolation: Error, Equatable, Sendable, CustomStringConvertible {
    /// The corrective message describing why the path was rejected.
    public let message: String

    /// Creates a violation carrying a corrective message.
    ///
    /// - Parameter message: the human-readable corrective message.
    public init(_ message: String) {
        self.message = message
    }

    /// The violation's textual representation, which is its corrective ``message``.
    public var description: String { message }
}

/// The kind of file access a path is being validated for.
///
/// Selects which permission rule ``PathGuard/checkPermission(_:for:)`` applies,
/// mirroring the Rust `FileOperation` enum.
public enum FileOperation: Sendable {
    /// Reading a file's contents.
    case read
    /// Writing or creating a file.
    case write
    /// Modifying an existing file.
    case edit
    /// Creating or traversing a directory.
    case directory
}

/// Validates and permission-checks filesystem paths for the file operations.
///
/// This is a Swift port of the Rust `swissarmyhammer-tools` `shared_utils`
/// validation stack (`FilePathValidator`, `validate_file_path`,
/// `reject_filesystem_root`, `check_file_permissions`). It is security-sensitive
/// code: it defends the file tools against directory traversal, symlink escapes,
/// workspace-boundary violations, and pathological search roots.
///
/// Every validation entry point returns a `Result`: `.success` with the
/// resolved absolute ``Foundation/URL`` to operate on, or `.failure` with a
/// ``PathViolation`` carrying a corrective message. Nothing here throws.
///
/// Relative paths resolve against ``root`` — the session working directory —
/// never the process current directory, because the host may run with an
/// unrelated current directory while serving multiple sessions.
public struct PathGuard: Sendable {
    /// The session working directory relative paths resolve against.
    ///
    /// Never the process current directory: the host process can run with an
    /// unrelated current directory (for example `/`) while a single process
    /// serves multiple session roots.
    public let root: URL

    /// The optional workspace boundary all validated paths must stay within.
    ///
    /// When non-`nil`, a validated path (or, for a not-yet-created target, its
    /// deepest existing parent) must be within this directory after
    /// canonicalization. When `nil`, no boundary is enforced.
    public let workspaceRoot: URL?

    /// Whether symlinks are resolved (`true`) or rejected (`false`, the secure default).
    ///
    /// When `false`, a path that is itself a symlink is rejected before
    /// canonicalization, so a link to a nonexistent or out-of-bounds target
    /// cannot slip through. When `true`, the symlink is resolved to its real
    /// target and re-checked against the workspace boundary.
    public let allowSymlinks: Bool

    /// The maximum accepted path length in UTF-8 bytes.
    ///
    /// Matches the Rust `MAX_PATH_LENGTH` (the Unix `PATH_MAX` standard) and is
    /// measured in bytes, as the Rust `str::len` is, so the limit is identical
    /// across both ports.
    private static let maximumPathLength = 4096

    /// Literal substrings that, if present anywhere in the path, reject it.
    ///
    /// Ported from the Rust default blocked-pattern set: Unix (`../`) and
    /// Windows (`\..\`, `..\`) parent-directory traversal, plus the null byte in
    /// both raw (`\0`) and escaped (`\\0`) forms. A bare `..` is deliberately
    /// not blocked (it can be a legitimate filename), and `./` is allowed (it
    /// references the current directory, which is safe).
    private static let blockedPatterns = ["../", "\\..\\", "..\\", "\0", "\\0"]

    /// The corrective-message prefix reported when a parent directory is missing.
    ///
    /// Referenced by ``parentDirectoryMissing(_:)`` so the exact wording lives in
    /// a single place; the offending parent path is appended after one space.
    private static let parentDirectoryMissingMessage = "Parent directory does not exist:"

    /// The corrective-message suffix telling the model how to supply a valid search root.
    ///
    /// Referenced by both branches of ``rejectFilesystemRoot(_:)`` so the exact
    /// wording lives in a single place, appended after each branch-specific prefix.
    private static let provideSessionDirectoryMessage =
        "Provide a `path`, or run with a session working directory set."

    /// Creates a guard rooted at a session working directory.
    ///
    /// - Parameters:
    ///   - root: the session working directory relative paths resolve against.
    ///   - workspaceRoot: the optional boundary all validated paths must stay
    ///     within; `nil` (the default) enforces no boundary.
    ///   - allowSymlinks: whether to resolve symlinks (`true`) or reject them
    ///     (`false`, the default).
    public init(root: URL, workspaceRoot: URL? = nil, allowSymlinks: Bool = false) {
        self.root = root
        self.workspaceRoot = workspaceRoot
        self.allowSymlinks = allowSymlinks
    }

    // MARK: Path validation

    /// Validate a path and, on success, check permissions for an operation.
    ///
    /// Runs ``validatePath(_:)`` then ``checkPermission(_:for:)``, returning the
    /// first violation encountered or the resolved absolute URL.
    ///
    /// - Parameters:
    ///   - path: the raw path string (absolute or relative to ``root``).
    ///   - operation: the operation whose permission rule to apply.
    /// - Returns: `.success` with the resolved absolute URL, or `.failure` with
    ///   a corrective ``PathViolation``.
    public func validate(_ path: String, for operation: FileOperation) -> Result<URL, PathViolation> {
        validatePath(path).flatMap { url in
            checkPermission(url, for: operation).map { url }
        }
    }

    /// Validate a path string, returning the resolved absolute URL to operate on.
    ///
    /// Performs, in order: empty check, length check, blocked-pattern check,
    /// relative resolution against ``root``, symlink rejection (before
    /// canonicalization unless ``allowSymlinks`` is set), canonicalization with
    /// parent-existence messaging for not-yet-created targets, control-character
    /// rejection, and workspace-boundary enforcement.
    ///
    /// For an existing path the resolved canonical URL is returned; for a
    /// not-yet-created target whose parent exists the resolved (uncanonicalized)
    /// absolute URL is returned, so `write` can create it.
    ///
    /// - Parameter path: the raw path string (absolute or relative to ``root``).
    /// - Returns: `.success` with the resolved absolute URL, or `.failure` with
    ///   a corrective ``PathViolation``.
    public func validatePath(_ path: String) -> Result<URL, PathViolation> {
        if path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .failure(PathViolation("File path cannot be empty"))
        }
        if let violation = Self.lengthViolation(path) {
            return .failure(violation)
        }
        for pattern in Self.blockedPatterns where path.contains(pattern) {
            return .failure(PathViolation("Path contains blocked pattern '\(pattern)': \(path)"))
        }

        let resolvedPath = path.hasPrefix("/") ? path : Self.join(root.path, path)

        // Re-check the length of the resolved path: a short relative input can
        // exceed the limit once joined to the session root. Mirrors the Rust
        // nested length check in `validate_file_path`.
        if let violation = Self.lengthViolation(resolvedPath) {
            return .failure(violation)
        }

        if isSymlink(resolvedPath) && !allowSymlinks {
            return .failure(PathViolation("Symlinks are not allowed: \(resolvedPath)"))
        }

        let validatedPath: String
        switch Self.canonicalize(resolvedPath) {
        case .resolved(let canonical):
            validatedPath = canonical
        case .failed(let errorNumber):
            switch errorNumber {
            case ENOENT:
                // The path does not exist. This is acceptable for a write
                // target as long as the parent directory exists.
                if case .failure(let violation) = parentDirectoryMissing(resolvedPath) {
                    return .failure(violation)
                }
                validatedPath = resolvedPath
            case EACCES:
                return .failure(PathViolation("Permission denied accessing path: \(resolvedPath)"))
            case EINVAL:
                return .failure(PathViolation("Invalid path format: \(resolvedPath)"))
            default:
                return .failure(
                    PathViolation("Failed to resolve path '\(resolvedPath)': \(String(cString: strerror(errorNumber)))")
                )
            }
        }

        if Self.containsInvalidControlCharacter(validatedPath) {
            return .failure(PathViolation("Path contains invalid control characters"))
        }

        // Enforce the workspace boundary once here (after control-character
        // validation) and, when symlinks are opted in, again on the symlink's
        // real target inside `resolveSymlinkIfAllowed`, so both the requested
        // path and its resolved target must stay within the boundary. Both
        // stages route through `enforceWorkspaceBoundary`.
        return enforceWorkspaceBoundary(validatedPath)
            .flatMap { resolveSymlinkIfAllowed(originalPath: resolvedPath, validatedPath: validatedPath) }
            .map { URL(fileURLWithPath: $0) }
    }

    /// Enforce the workspace boundary on a path when a boundary is configured.
    ///
    /// A no-op returning `.success` when ``workspaceRoot`` is `nil`; otherwise
    /// delegates to ``ensureWorkspaceBoundary(_:workspaceRoot:)``. Extracted so
    /// the boundary check applied both after control-character validation and
    /// after symlink re-resolution stays a single expression at each stage.
    ///
    /// - Parameter path: the resolved path to bound-check.
    /// - Returns: `.success` when within the boundary (or unbounded), or
    ///   `.failure` with a corrective ``PathViolation``.
    private func enforceWorkspaceBoundary(_ path: String) -> Result<Void, PathViolation> {
        guard let workspaceRoot else { return .success(()) }
        return ensureWorkspaceBoundary(path, workspaceRoot: workspaceRoot)
    }

    /// Re-resolve an opted-in symlink to its real target and re-check the boundary.
    ///
    /// When ``allowSymlinks`` is set and `originalPath` is itself a symlink, the
    /// already validated path is re-canonicalized to its real target and the
    /// workspace boundary is re-checked against that target, so an opted-in
    /// symlink can never point outside the workspace — a dangling link fails to
    /// canonicalize and is rejected. Otherwise `validatedPath` is returned
    /// unchanged. Mirrors the Rust `resolve_symlink_securely`.
    ///
    /// - Parameters:
    ///   - originalPath: the pre-canonicalization resolved path, tested for being
    ///     a symlink.
    ///   - validatedPath: the validated path to re-resolve and bound-check.
    /// - Returns: `.success` with the path to operate on, or `.failure` with a
    ///   corrective ``PathViolation``.
    private func resolveSymlinkIfAllowed(
        originalPath: String,
        validatedPath: String
    ) -> Result<String, PathViolation> {
        guard allowSymlinks && isSymlink(originalPath) else {
            return .success(validatedPath)
        }
        return Self.canonicalizeOrFail(validatedPath, failureMessage: "Failed to resolve symlink: \(originalPath)")
            .flatMap { resolvedTarget in
                enforceWorkspaceBoundary(resolvedTarget).map { resolvedTarget }
            }
    }

    /// A `.failure` when `path`'s parent directory does not exist, else `.success`.
    ///
    /// Shared by ``validatePath(_:)`` (for a not-yet-created canonicalization
    /// target) and ``checkPermission(_:for:)`` (for a `write` to a nonexistent
    /// target), so the parent-existence rule and its corrective message live in
    /// one place.
    ///
    /// - Parameter path: the path whose parent directory to check.
    /// - Returns: `.success` when the parent exists (or there is no parent), or
    ///   `.failure` with a corrective ``PathViolation``.
    private func parentDirectoryMissing(_ path: String) -> Result<Void, PathViolation> {
        if let parent = Self.parentPath(path), !fileExists(parent) {
            return .failure(PathViolation("\(Self.parentDirectoryMissingMessage) \(parent)"))
        }
        return .success(())
    }

    /// Refuse a search root that would walk the whole filesystem or the process directory.
    ///
    /// A relative search directory (a bare `.`, the empty string, or anything
    /// not anchored at an absolute root) means the session working directory
    /// could not be resolved; walking it would root the search at the process
    /// current directory. An absolute root with no path components is the
    /// filesystem root (`/`); walking it visits every file on the machine.
    /// Either case is refused. Mirrors the Rust `reject_filesystem_root`.
    ///
    /// - Parameter searchDirectory: the resolved search root to check.
    /// - Returns: `.success` when the root is a normal absolute directory, or
    ///   `.failure` with a corrective ``PathViolation``.
    public func rejectFilesystemRoot(_ searchDirectory: String) -> Result<Void, PathViolation> {
        if !searchDirectory.hasPrefix("/") {
            return .failure(
                PathViolation(
                    "Refusing to search '\(searchDirectory)': the session working directory could not be "
                        + "resolved to an absolute path. " + Self.provideSessionDirectoryMessage
                )
            )
        }
        if searchDirectory.split(separator: "/", omittingEmptySubsequences: true).isEmpty {
            return .failure(
                PathViolation(
                    "Refusing to search the filesystem root: \(searchDirectory). "
                        + Self.provideSessionDirectoryMessage
                )
            )
        }
        return .success(())
    }

    // MARK: Permission checks

    /// Check that an operation is permitted on a resolved path.
    ///
    /// Ported from the Rust `check_file_permissions`, using pure mode-bit checks
    /// (readable = any of `0o444`; not read-only = any of `0o222`) so the result
    /// is independent of the running user:
    ///
    /// - `read`: an existing path must be a regular file and readable.
    /// - `write`: an existing file must not be read-only; a nonexistent target's
    ///   parent directory must exist.
    /// - `edit`: the file must exist and must not be read-only.
    /// - `directory`: an existing path must be a directory.
    ///
    /// - Parameters:
    ///   - url: the resolved absolute URL (from ``validatePath(_:)``).
    ///   - operation: the operation whose permission rule to apply.
    /// - Returns: `.success` when permitted, or `.failure` with a corrective
    ///   ``PathViolation``.
    public func checkPermission(_ url: URL, for operation: FileOperation) -> Result<Void, PathViolation> {
        let path = url.path
        switch operation {
        case .read:
            guard fileExists(path) else { return .success(()) }
            guard let mode = Self.fileMode(path) else {
                return .failure(PathViolation("Failed to get file metadata: \(path)"))
            }
            if (mode & S_IFMT) != S_IFREG {
                return .failure(PathViolation("Path is not a regular file: \(path)"))
            }
            if (mode & 0o444) == 0 {
                return .failure(PathViolation("File is not readable (no read permissions): \(path)"))
            }

        case .write:
            guard fileExists(path) else {
                return parentDirectoryMissing(path)
            }
            if Self.isReadOnly(path) {
                return .failure(PathViolation("File is read-only: \(path)"))
            }

        case .edit:
            if !fileExists(path) {
                return .failure(PathViolation("Cannot edit non-existent file: \(path)"))
            }
            if Self.isReadOnly(path) {
                return .failure(PathViolation("File is read-only and cannot be edited: \(path)"))
            }

        case .directory:
            if fileExists(path), (Self.fileMode(path).map { ($0 & S_IFMT) != S_IFDIR }) ?? true {
                return .failure(PathViolation("Path exists but is not a directory: \(path)"))
            }
        }
        return .success(())
    }

    // MARK: Workspace boundary

    /// Ensure a path stays within the workspace boundary after canonicalization.
    ///
    /// Both the workspace root and the path are canonicalized before a
    /// component-wise prefix comparison, so `/foo/bar` is inside `/foo` but
    /// `/foobar` is not. A not-yet-created target is reconstructed from its
    /// deepest existing parent's canonical path, so nonexistent write targets
    /// are still bounded. Mirrors the Rust `ensure_workspace_boundary`.
    private func ensureWorkspaceBoundary(
        _ path: String,
        workspaceRoot: URL
    ) -> Result<Void, PathViolation> {
        Self.canonicalizeOrFail(workspaceRoot.path, failureMessage: "Invalid workspace root: \(workspaceRoot.path)")
            .flatMap { canonicalWorkspace in
                resolvedPathToCheck(path).flatMap { pathToCheck in
                    Self.pathStartsWith(pathToCheck, prefix: canonicalWorkspace)
                        ? .success(())
                        : .failure(
                            PathViolation(
                                "Path is outside workspace boundaries: \(pathToCheck) (workspace: \(canonicalWorkspace))"
                            )
                        )
                }
            }
    }

    /// The real absolute path to bound-check for a path that may not yet exist.
    ///
    /// Canonicalizes an existing path directly; for a not-yet-created target,
    /// defers to ``reconstructViaExistingParent(_:)`` so the boundary check
    /// still operates on a real absolute path.
    ///
    /// - Parameter path: the path to resolve for bounding.
    /// - Returns: `.success` with the resolved absolute path, or `.failure` with
    ///   a corrective ``PathViolation``.
    private func resolvedPathToCheck(_ path: String) -> Result<String, PathViolation> {
        fileExists(path)
            ? Self.canonicalizeOrFail(path, failureMessage: "Failed to canonicalize path: \(path)")
            : reconstructViaExistingParent(path)
    }

    /// Reconstruct a nonexistent path against its deepest existing parent's canonical path.
    ///
    /// Walks up the ancestors of `path` to the first that exists, canonicalizes
    /// it, and rejoins the remaining components, so the boundary check operates
    /// on a real absolute path even for a target that does not exist yet.
    private func reconstructViaExistingParent(_ path: String) -> Result<String, PathViolation> {
        var current = path
        while let parent = Self.parentPath(current) {
            if fileExists(parent) {
                return Self.canonicalizeOrFail(parent, failureMessage: "Failed to canonicalize parent directory: \(parent)")
                    .map { canonicalParent in
                        let remainder = Self.components(path).dropFirst(Self.components(parent).count)
                        return remainder.isEmpty
                            ? canonicalParent
                            : canonicalParent + "/" + remainder.joined(separator: "/")
                    }
            }
            current = parent
        }
        return .failure(PathViolation("Path has no existing parent directory: \(path)"))
    }

    // MARK: Filesystem probes

    /// Whether a path exists, following symlinks (matching the Rust `Path::exists`).
    private func fileExists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    /// Whether a path is itself a symlink, without following it (via `lstat`).
    private func isSymlink(_ path: String) -> Bool {
        var status = stat()
        return lstat(path, &status) == 0 && (status.st_mode & S_IFMT) == S_IFLNK
    }

    // MARK: Static helpers

    /// The `st_mode` of a path, following symlinks, or `nil` if it cannot be stat-ed.
    private static func fileMode(_ path: String) -> mode_t? {
        var status = stat()
        guard stat(path, &status) == 0 else { return nil }
        return status.st_mode
    }

    /// Whether a path has no write bits set (`mode & 0o222 == 0`), matching Rust's `readonly()`.
    private static func isReadOnly(_ path: String) -> Bool {
        guard let mode = fileMode(path) else { return false }
        return (mode & 0o222) == 0
    }

    /// The outcome of canonicalizing a path via `realpath`.
    ///
    /// Distinct from `Result` because the failure payload is a POSIX `errno`
    /// (an `Int32`), which does not conform to `Error`.
    private enum CanonicalizeOutcome {
        /// The real absolute path, with symlinks resolved.
        case resolved(String)
        /// The POSIX `errno` from the failed `realpath` (for example `ENOENT`).
        case failed(Int32)
    }

    /// Canonicalize a path via `realpath`, resolving symlinks and requiring existence.
    ///
    /// Mirrors the Rust `Path::canonicalize`: ``CanonicalizeOutcome/resolved(_:)``
    /// with the real absolute path, or ``CanonicalizeOutcome/failed(_:)`` with the
    /// POSIX `errno` (for example `ENOENT` when the path does not exist).
    private static func canonicalize(_ path: String) -> CanonicalizeOutcome {
        guard let resolved = realpath(path, nil) else {
            return .failed(errno)
        }
        defer { free(resolved) }
        return .resolved(String(cString: resolved))
    }

    /// Canonicalize a path, mapping a `realpath` failure to a corrective violation.
    ///
    /// Wraps the ``CanonicalizeOutcome`` guard repeated at every workspace-boundary
    /// and symlink-resolution site: on ``CanonicalizeOutcome/resolved(_:)`` it
    /// yields the real absolute path; on ``CanonicalizeOutcome/failed(_:)`` it
    /// discards the `errno` — as every call site already did — and returns a
    /// `.failure` carrying `failureMessage`.
    ///
    /// - Parameters:
    ///   - path: the path to canonicalize via `realpath`.
    ///   - failureMessage: the corrective message when canonicalization fails.
    /// - Returns: `.success` with the real absolute path, or `.failure` with a
    ///   ``PathViolation`` carrying `failureMessage`.
    private static func canonicalizeOrFail(
        _ path: String,
        failureMessage: @autoclosure () -> String
    ) -> Result<String, PathViolation> {
        switch canonicalize(path) {
        case .resolved(let canonical):
            return .success(canonical)
        case .failed:
            return .failure(PathViolation(failureMessage()))
        }
    }

    /// A "path too long" violation when a path exceeds ``maximumPathLength``, else `nil`.
    ///
    /// Length is measured in UTF-8 bytes, matching the Rust `str::len`.
    private static func lengthViolation(_ path: String) -> PathViolation? {
        guard path.utf8.count > maximumPathLength else { return nil }
        return PathViolation(
            "Path too long (\(path.utf8.count) characters, maximum \(maximumPathLength)): \(path)"
        )
    }

    /// Join a relative path onto an absolute base directory.
    private static func join(_ base: String, _ relative: String) -> String {
        base.hasSuffix("/") ? base + relative : base + "/" + relative
    }

    /// The parent of an absolute path, or `nil` for the filesystem root.
    ///
    /// Trailing slashes are trimmed first (keeping the root). Mirrors the Rust
    /// `Path::parent` for the absolute paths this stack operates on.
    private static func parentPath(_ path: String) -> String? {
        var trimmed = path
        while trimmed.count > 1 && trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard trimmed != "/" else { return nil }
        guard let lastSlash = trimmed.lastIndex(of: "/") else { return nil }
        if lastSlash == trimmed.startIndex { return "/" }
        return String(trimmed[trimmed.startIndex..<lastSlash])
    }

    /// The non-empty path components of a path (leading/trailing slashes dropped).
    private static func components(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    /// Whether `path` is at or below `prefix`, compared component-wise.
    ///
    /// Component-wise comparison (not string prefix) so `/foobar` is not
    /// considered inside `/foo`.
    private static func pathStartsWith(_ path: String, prefix: String) -> Bool {
        let pathComponents = components(path)
        let prefixComponents = components(prefix)
        guard prefixComponents.count <= pathComponents.count else { return false }
        return Array(pathComponents.prefix(prefixComponents.count)) == prefixComponents
    }

    /// Whether a path contains a disallowed control character.
    ///
    /// Rejects Unicode control characters (C0 `U+0000`–`U+001F`, `DEL`, and C1
    /// `U+0080`–`U+009F`) except tab, newline, and carriage return, matching the
    /// Rust normalization check. The null byte is caught earlier as a blocked
    /// pattern but is also covered here.
    private static func containsInvalidControlCharacter(_ path: String) -> Bool {
        path.unicodeScalars.contains { scalar in
            let value = scalar.value
            let isControl = value <= 0x1F || (value >= 0x7F && value <= 0x9F)
            return isControl && scalar != "\n" && scalar != "\r" && scalar != "\t"
        }
    }
}
