import Foundation
import FoundationModels
import Operations

/// Searches file contents for a regular expression, git-aware and shaped by output mode.
///
/// The pipeline delegates to ``GrepEngine``: it validates the pattern, the
/// optional file-type and `glob` filters, and the output mode; resolves the
/// search target through the context's ``PathGuard`` (a single file
/// short-circuits the walk, a directory is enumerated git-aware so a gitignored
/// directory such as `build/` is never descended into); skips binary files;
/// matches each line with Swift `Regex`; assembles the matched lines with their
/// surrounding context into hunks; and returns the mode-shaped result. Every
/// recoverable failure is returned as a ``GrepOutput/corrective(_:)`` message;
/// nothing here throws for an invalid pattern, filter, mode, or path.
@Generable
@Operation(verb: "grep", noun: "files", description: "Search file contents for a regular expression, git-aware and shaped by output mode")
public struct GrepFiles: Sendable {
    /// The regular-expression pattern to search for.
    public var pattern: String

    /// The file or directory to search, or `nil` to search the session root.
    ///
    /// Aliased to accept the sah/native dialects' `file_path` and
    /// `absolute_path` spellings in place of the canonical `path`.
    @OperationParam(aliases: ["file_path", "absolute_path"])
    public var path: String?

    /// A filename filter applied to a directory walk, or `nil` for no filter.
    public var glob: String?

    /// A file-type filter naming a known type (for example `swift`), or `nil` for no filter.
    public var type: String?

    /// Whether matching ignores case; absent means the default (`false`).
    public var caseInsensitive: Bool?

    /// The number of context lines on each side of a match; absent means the default (two).
    public var contextLines: Int?

    /// The output mode (`content`, `filesWithMatches`, or `count`); absent means the default (`content`).
    public var outputMode: String?
}

extension GrepFiles {
    // MARK: Parameter defaults

    /// The case-insensitivity used when ``caseInsensitive`` is absent.
    private static let defaultCaseInsensitive = false

    // MARK: Execution

    /// Searches file contents and returns the mode-shaped result, or a corrective message.
    ///
    /// Applies the case-insensitivity default and delegates to
    /// ``GrepEngine/run(pattern:path:glob:type:caseInsensitive:contextLines:outputMode:in:)``,
    /// which performs the validation, target resolution, git-aware walk, binary
    /// skip, line matching, context assembly, and output-mode shaping. The
    /// engine owns the ``contextLines`` and ``outputMode`` defaults, so both are
    /// passed through unchanged. Every recoverable failure is returned as
    /// ``GrepOutput/corrective(_:)``; nothing here throws for an invalid
    /// pattern, filter, mode, or path.
    ///
    /// - Parameter context: the shared session context supplying the path guard and root.
    /// - Returns: the ``GrepOutput/content(_:)`` result on success, or a
    ///   ``GrepOutput/corrective(_:)`` message the model can act on.
    /// - Throws: Nothing; the signature carries `throws` to satisfy the `OperationDefinition` protocol requirement.
    public func execute(in context: FileContext) async throws -> GrepOutput {
        GrepEngine().run(
            pattern: pattern,
            path: path,
            glob: glob,
            type: type,
            caseInsensitive: caseInsensitive ?? Self.defaultCaseInsensitive,
            contextLines: contextLines,
            outputMode: outputMode,
            in: context
        )
    }
}
