import Foundation
import FoundationModels
import Operations

/// Finds files matching a glob pattern, newest first, guarding against overly broad walks.
///
/// The pipeline delegates to ``GlobEngine``: it validates the pattern, refuses
/// an overly broad pattern when no ``path`` scopes the walk, resolves and bounds
/// the search root through the context's ``PathGuard`` (never walking the
/// filesystem root), enumerates candidate files (git-aware when a repository is
/// present and ``respectGitIgnore`` is set, else a plain walk), and returns the
/// matches relative to the session root sorted by modification time with the
/// newest first, capped at the engine's default. Every recoverable failure is
/// returned as a ``GlobOutput/corrective(_:)`` message; nothing here throws for a
/// bad pattern, a broad pattern, a bad path, or a missing directory.
@Generable
@Operation(verb: "glob", noun: "files", description: "Find files matching a glob pattern, newest first, guarding against overly broad walks")
public struct GlobFiles: Sendable {
    /// The glob pattern to match.
    public var pattern: String

    /// The directory to search, or `nil` to search the session root.
    public var path: String?

    /// Whether matching is case-sensitive; absent means the default (`false`).
    public var caseSensitive: Bool?

    /// Whether a present repository's ignore rules are honored; absent means the default (`true`).
    public var respectGitIgnore: Bool?
}

extension GlobFiles {
    // MARK: Parameter defaults

    /// The case-sensitivity used when ``caseSensitive`` is absent.
    private static let defaultCaseSensitive = false

    /// The gitignore-respecting behavior used when ``respectGitIgnore`` is absent.
    private static let defaultRespectGitIgnore = true

    // MARK: Execution

    /// Finds the matching files and returns them newest first, or a corrective message.
    ///
    /// Applies the parameter defaults and delegates to ``GlobEngine/run(pattern:path:caseSensitive:respectGitIgnore:in:)``,
    /// which performs the validation, broad-pattern guard, path bounding, walk,
    /// matching, ordering, and capping. Every recoverable failure is returned as
    /// ``GlobOutput/corrective(_:)``.
    ///
    /// - Parameter context: the shared session context supplying the path guard and root.
    /// - Returns: the ``GlobOutput/content(_:)`` matches on success, or a
    ///   ``GlobOutput/corrective(_:)`` message the model can act on.
    public func execute(in context: FileContext) async throws -> GlobOutput {
        GlobEngine().run(
            pattern: pattern,
            path: path,
            caseSensitive: caseSensitive ?? Self.defaultCaseSensitive,
            respectGitIgnore: respectGitIgnore ?? Self.defaultRespectGitIgnore,
            in: context
        )
    }
}
