import Foundation

/// `Decodable` mirrors of the operation outputs the cross-op and edits-OK suites
/// read back out of full-dispatch JSON.
///
/// The operations only *encode* their outputs, so — exactly as
/// ``DecodedMutationOutput`` mirrors the folded diagnostics — these mirror the
/// fields the integration suites assert on, letting a test drive an op through
/// ``DiagnosticsProbe/callTool(_:arguments:)`` and read the result envelope back
/// out of the dispatched JSON. Each mirror carries only the fields a test needs;
/// a `Decodable` struct silently ignores the rest.
enum OperationOutput {
    /// Decodes a mirror `type` from an operation's JSON-encoded output.
    ///
    /// - Parameters:
    ///   - type: the mirror type to decode.
    ///   - toolOutput: the operation's JSON-encoded output.
    /// - Returns: the decoded mirror, or `nil` when the output is not that shape
    ///   (for example a corrective, or a decode failure).
    static func decode<T: Decodable>(_ type: T.Type, from toolOutput: String) -> T? {
        guard let data = toolOutput.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(type, from: data)
    }
}

/// A `Decodable` mirror of a `read file` result.
struct DecodedReadResult: Decodable {
    /// The whole-file freshness token over the full on-disk bytes.
    let hash: String

    /// The selected window of lines, tagged (`hashline`) or verbatim (`plain`).
    let lines: [String]

    /// A human-readable description of the window, or `nil` for a whole-file read.
    let note: String?
}

/// A `Decodable` mirror of a `write file` result.
struct DecodedWriteResult: Decodable {
    /// The absolute path written.
    let path: String

    /// The number of bytes written.
    let bytesWritten: Int

    /// The whole-file freshness token over the written bytes.
    let hash: String

    /// The written content tagged with absolute hashline anchors, one entry per line.
    let taggedContent: [String]

    /// The compiler diagnostics for the write, or `nil` when none are folded in.
    let diagnostics: DecodedDiagnostics?
}

/// A `Decodable` mirror of one per-pair `edit file` outcome.
struct DecodedEditOutcome: Decodable {
    /// How this `find` resolved: `anchor`, `literal`, `recovered`, and so on.
    let matchedBy: String

    /// The `find` value this outcome resolved (or failed to resolve).
    let find: String

    /// The resolved 1-based line, populated for an `anchor` match; `nil` otherwise.
    let line: Int?
}

/// A `Decodable` mirror of an `edit file` result.
struct DecodedEditResult: Decodable {
    /// The absolute path edited.
    let path: String

    /// The whole-batch status: `applied`, `ambiguous`, `nearMiss`, and so on.
    let status: String

    /// The number of pairs applied; `0` unless ``status`` is `applied`.
    let applied: Int

    /// The per-pair outcomes.
    let outcomes: [DecodedEditOutcome]

    /// The detected, preserved encoding, or `nil` when nothing was committed.
    let encoding: String?

    /// The detected, preserved line-ending convention, or `nil` when nothing was committed.
    let lineEndings: String?

    /// The whole-file freshness token over the committed bytes, or `nil` when nothing was committed.
    let hash: String?

    /// The committed content tagged with absolute hashline anchors, or `nil` when nothing was committed.
    let taggedContent: [String]?

    /// The compiler diagnostics folded in after the commit, or `nil`.
    let diagnostics: DecodedDiagnostics?
}

/// A `Decodable` mirror of a `glob files` result.
struct DecodedGlobResult: Decodable {
    /// The glob pattern that produced this result.
    let pattern: String

    /// The matching paths relative to the session root, most recently modified first.
    let files: [String]

    /// The total number of matching files found, before any cap is applied.
    let total: Int

    /// Whether ``total`` exceeded the result cap, so ``files`` is a truncated prefix.
    let capped: Bool
}

/// A `Decodable` mirror of one `grep files` matched or context line.
struct DecodedGrepMatch: Decodable {
    /// The matching file's path relative to the session root.
    let file: String

    /// The 1-based physical line number of this line within its file.
    let line: Int

    /// The line's text, with its terminator excluded.
    let text: String

    /// Whether this line matched the pattern (`true`) or is surrounding context (`false`).
    let isMatch: Bool
}

/// A `Decodable` mirror of a `grep files` result.
struct DecodedGrepResult: Decodable {
    /// The matched and context lines, present only in the `content` mode.
    let matches: [DecodedGrepMatch]?

    /// The relative paths of the files with at least one match, present only in the `filesWithMatches` mode.
    let files: [String]?

    /// The total number of matched lines across all files; context lines never count.
    let matchCount: Int

    /// The number of files with at least one matched line.
    let fileCount: Int
}

/// A `Decodable` mirror of a corrective operation output (`{ "corrective": … }`).
struct DecodedCorrective: Decodable {
    /// The corrective message the operation returned in place of a result.
    let corrective: String
}
