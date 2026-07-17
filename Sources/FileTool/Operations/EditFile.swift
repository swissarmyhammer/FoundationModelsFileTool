import Foundation
import FoundationModels
import Operations

/// One surrounding context line of an edit candidate: its 1-based line number and text.
///
/// The `Encodable` projection of ``EditEngine/ContextLine``, carried inside an
/// ``EditCandidate`` so the model can tell competing edit sites apart.
public struct EditContextLine: Encodable, Sendable {
    /// The 1-based physical line number in the file.
    public let line: Int

    /// The line's text, excluding its terminator.
    public let text: String

    /// Creates a context line.
    ///
    /// - Parameters:
    ///   - line: the 1-based physical line number.
    ///   - text: the line's text, excluding its terminator.
    public init(line: Int, text: String) {
        self.line = line
        self.text = text
    }
}

/// One competing edit site the engine will not choose between: where it is, and its surroundings.
///
/// The `Encodable` projection of ``EditEngine/Candidate``. The ``occurrence`` is
/// the value the caller passes back as `occurrence` to select this site on a
/// retry; ``line`` and ``text`` locate it and ``context`` carries the
/// surrounding lines so the model can disambiguate.
public struct EditCandidate: Encodable, Sendable {
    /// The candidate's 1-based position in the candidate list, for `occurrence` selection.
    public let occurrence: Int

    /// The 1-based physical line number of the candidate.
    public let line: Int

    /// The current text of the candidate's line, excluding its terminator.
    public let text: String

    /// The surrounding context lines, excluding the focal ``line``, nearest first.
    public let context: [EditContextLine]

    /// Creates a candidate.
    ///
    /// - Parameters:
    ///   - occurrence: the candidate's 1-based position in the candidate list.
    ///   - line: the 1-based physical line number of the candidate.
    ///   - text: the current text of the candidate's line, excluding its terminator.
    ///   - context: the surrounding context lines, excluding the focal line.
    public init(occurrence: Int, line: Int, text: String, context: [EditContextLine]) {
        self.occurrence = occurrence
        self.line = line
        self.text = text
        self.context = context
    }
}

/// One line of a near-miss diff: which side of the `find`-versus-current comparison it came from, and its text.
///
/// The `Encodable` projection of ``EditEngine/DiffLine``. The ``change`` reads as
/// `unchanged` (present identically in both), `expected` (present in the `find`
/// but absent from the current text), or `actual` (present in the current text
/// but absent from the `find`).
public struct EditDiffLine: Encodable, Sendable {
    /// Which side of the comparison this line came from: `unchanged`, `expected`, or `actual`.
    public let change: String

    /// The line's text, excluding its terminator.
    public let text: String

    /// Creates a diff line.
    ///
    /// - Parameters:
    ///   - change: which side of the comparison this line came from.
    ///   - text: the line's text, excluding its terminator.
    public init(change: String, text: String) {
        self.change = change
        self.text = text
    }
}

/// A near-miss: a span the recovery ladder scored highly but could not confidently accept, with a line diff.
///
/// The `Encodable` projection of ``EditEngine/NearMiss``. The ``lines`` are a
/// line-level diff of the pair's `find` against the span's current text, so the
/// model can see exactly how what it asked for differs from what is present.
public struct EditNearMiss: Encodable, Sendable {
    /// The 1-based first line of the near-miss span.
    public let startLine: Int

    /// The 1-based last line of the near-miss span.
    public let endLine: Int

    /// The line-level diff of the pair's `find` against the span's current text.
    public let lines: [EditDiffLine]

    /// A diagnostic naming the first confusable-punctuation difference in the diff, or `nil` when there is none.
    ///
    /// Surfaced when a diff line pair differs only by Unicode confusable
    /// punctuation (smart quotes, typographic dashes, exotic spaces), so the
    /// model reading the diff sees the punctuation is the cause. Nil-omitted from
    /// the encoding when absent.
    public let note: String?

    /// Creates a near-miss.
    ///
    /// - Parameters:
    ///   - startLine: the 1-based first line of the span.
    ///   - endLine: the 1-based last line of the span.
    ///   - lines: the line-level diff of `find` against the span's current text.
    ///   - note: a confusable-punctuation diagnostic, or `nil`; defaults to `nil`.
    public init(startLine: Int, endLine: Int, lines: [EditDiffLine], note: String? = nil) {
        self.startLine = startLine
        self.endLine = endLine
        self.lines = lines
        self.note = note
    }
}

/// The per-pair outcome of an `edit file` batch: how (or whether) one `find` resolved.
///
/// The `Encodable` projection of a single ``EditEngine/Resolution``. Exactly one
/// of the detail fields is populated, selected by ``matchedBy``:
///
/// - `anchor` / `literal` / `recovered` — a definite, applied match; ``line``
///   carries the resolved 1-based line for an `anchor` match.
/// - `ambiguous` — several plausible sites tied; ``candidates`` lists them.
/// - `nearMiss` — nothing matched confidently; ``nearMisses`` carries the line
///   diffs of the best near-misses.
/// - `alreadyApplied` / `consumedTarget` — an idempotency or batch-order
///   reclassification; ``note`` explains it.
public struct EditOutcome: Encodable, Sendable {
    /// How this `find` resolved: `anchor`, `literal`, `recovered`, `ambiguous`, `nearMiss`, `alreadyApplied`, or `consumedTarget`.
    public let matchedBy: String

    /// The `find` value this outcome resolved (or failed to resolve).
    public let find: String

    /// The resolved 1-based line, populated for an `anchor` match; `nil` otherwise.
    public let line: Int?

    /// The competing candidates for an `ambiguous` outcome; `nil` otherwise.
    public let candidates: [EditCandidate]?

    /// The best near-misses for a `nearMiss` outcome; `nil` otherwise.
    public let nearMisses: [EditNearMiss]?

    /// A human-readable note for an `alreadyApplied` or `consumedTarget` outcome; `nil` otherwise.
    public let note: String?

    /// Creates a per-pair outcome.
    ///
    /// - Parameters:
    ///   - matchedBy: how this `find` resolved.
    ///   - find: the `find` value this outcome resolved.
    ///   - line: the resolved 1-based line, or `nil`.
    ///   - candidates: the competing candidates, or `nil`.
    ///   - nearMisses: the best near-misses, or `nil`.
    ///   - note: a human-readable note, or `nil`.
    public init(
        matchedBy: String,
        find: String,
        line: Int? = nil,
        candidates: [EditCandidate]? = nil,
        nearMisses: [EditNearMiss]? = nil,
        note: String? = nil
    ) {
        self.matchedBy = matchedBy
        self.find = find
        self.line = line
        self.candidates = candidates
        self.nearMisses = nearMisses
        self.note = note
    }
}

/// The result of an `edit file` operation: the batch status, the per-pair outcomes, and — when applied — the commit envelope.
///
/// The ``status`` names the whole-batch result: `applied` when every pair
/// resolved and the single atomic commit landed, or one of the structured
/// retryable outcomes (`ambiguous`, `nearMiss`, `alreadyApplied`,
/// `consumedTarget`) that leave the file byte-identical and commit nothing. The
/// commit-only fields (``bytesWritten``, ``encoding``, ``lineEndings``,
/// ``hash``, ``taggedContent``) are populated only for an `applied` result; the
/// detected ``encoding`` and ``lineEndings`` are recorded from the original
/// file and preserved across the rewrite, never rewritten. The ``hash`` and
/// ``taggedContent`` are computed exactly as a subsequent `read file` computes
/// them, so a chained edit can lift an anchor without an intervening read. The
/// ``diagnostics`` are the compiler diagnostics ``DiagnosticsBridge`` folds in
/// after an `applied` commit, or `nil` for an unapplied outcome or a disabled
/// bridge.
public struct EditResult: Encodable, Sendable {
    /// The absolute path edited.
    public let path: String

    /// The whole-batch status: `applied`, `ambiguous`, `nearMiss`, `alreadyApplied`, or `consumedTarget`.
    public let status: String

    /// The number of pairs applied; `0` unless ``status`` is `applied`.
    public let applied: Int

    /// The per-pair outcomes: one per applied pair for an `applied` result, or the single unresolved pair otherwise.
    public let outcomes: [EditOutcome]

    /// The number of bytes committed, or `nil` when nothing was committed.
    public let bytesWritten: Int?

    /// The detected, preserved encoding (for example `utf-8`, `utf-8 bom`), or `nil` when nothing was committed.
    public let encoding: String?

    /// The detected, preserved line-ending convention (`lf`, `crlf`, `cr`, `mixed`), or `nil` when nothing was committed or the file has no line breaks.
    public let lineEndings: String?

    /// The whole-file freshness token over the committed bytes, or `nil` when nothing was committed.
    public let hash: String?

    /// The committed content tagged with absolute hashline anchors, or `nil` when nothing was committed.
    public let taggedContent: [String]?

    /// The compiler diagnostics folded in after the commit, or `nil` when none are folded in.
    public let diagnostics: FileDiagnostics?

    /// Creates an edit result.
    ///
    /// - Parameters:
    ///   - path: the absolute path edited.
    ///   - status: the whole-batch status.
    ///   - applied: the number of pairs applied.
    ///   - outcomes: the per-pair outcomes.
    ///   - bytesWritten: the number of bytes committed, or `nil`.
    ///   - encoding: the detected, preserved encoding, or `nil`.
    ///   - lineEndings: the detected, preserved line-ending convention, or `nil`.
    ///   - hash: the whole-file freshness token over the committed bytes, or `nil`.
    ///   - taggedContent: the committed content tagged with hashline anchors, or `nil`.
    ///   - diagnostics: the compiler diagnostics, or `nil`.
    public init(
        path: String,
        status: String,
        applied: Int,
        outcomes: [EditOutcome],
        bytesWritten: Int?,
        encoding: String?,
        lineEndings: String?,
        hash: String?,
        taggedContent: [String]?,
        diagnostics: FileDiagnostics?
    ) {
        self.path = path
        self.status = status
        self.applied = applied
        self.outcomes = outcomes
        self.bytesWritten = bytesWritten
        self.encoding = encoding
        self.lineEndings = lineEndings
        self.hash = hash
        self.taggedContent = taggedContent
        self.diagnostics = diagnostics
    }
}

/// The outcome of an `edit file` operation: either the edit result or a corrective message.
///
/// Follows the upstream *return-don't-throw* convention (the same convention
/// ``ReadOutput``, ``WriteOutput``, and ``PathViolation`` embody) via
/// ``CorrectiveEncodable``: a bad path, a non-existent or read-only file, a
/// binary (undecodable) file, a `find == replace` no-op, a find/replace count
/// mismatch, an empty find set, or a failed commit is surfaced as a
/// ``corrective(_:)`` message the model reads and acts on within the turn, never
/// thrown. The structured retryable outcomes (`ambiguous`, `nearMiss`,
/// `alreadyApplied`, `consumedTarget`) are *not* correctives: they ride in a
/// ``content(_:)`` ``EditResult`` with the matching ``EditResult/status`` and
/// leave the file byte-identical.
public enum EditOutput: CorrectiveEncodable, Sendable {
    /// A resolved batch carrying the ``EditResult`` (applied or a structured retryable outcome).
    case content(EditResult)

    /// A recoverable hard failure carrying a corrective message for the model.
    case corrective(String)

    /// The ``EditResult`` (encoded inline), or `nil` for a corrective outcome.
    public var successResult: EditResult? {
        if case .content(let result) = self { return result }
        return nil
    }

    /// The corrective message, or `nil` for a successful outcome.
    public var correctiveMessage: String? {
        if case .corrective(let message) = self { return message }
        return nil
    }
}

/// Edits a file's contents by a batch of find/replace pairs, committed atomically with encoding and line-ending preservation.
///
/// The pipeline wires the pure ``EditEngine`` cascade to a real file through
/// ``AtomicWriter``: it validates the path for an edit via the context's
/// ``PathGuard``, reads the on-disk bytes and decodes them with byte-order-mark
/// detection (``AtomicWriter/decode(_:)``; an undecodable, binary file is
/// corrective), records the detected line-ending convention
/// (``AtomicWriter/detectLineEnding(in:)``), normalizes the ``find`` / ``replace``
/// arguments into pairs, and resolves the whole batch **in memory**
/// (``EditEngine/apply(_:to:)``). Any unresolved pair short-circuits before any
/// mutation, so the file is left byte-identical and the structured outcome
/// (ambiguous / near-miss / already-applied / consumed-target) is returned. Only
/// a fully resolved batch is committed, in a single atomic write that re-encodes
/// with the detected encoding and preserves the file's permission bits; its
/// modification time is deliberately fresh so build tooling sees the change
/// (plan §6.12).
///
/// - Note: The `find` / `replace` arguments are `[String]` (a one-element array
///   is a scalar find; parallel arrays are a multi-pair batch), plus the scalar
    ///   ``replacesAll`` and ``occurrence`` disambiguators. The richer per-entry
///   `edits` object-array form ``EditEngine`` supports is not a model-facing
///   parameter here: the `@Operation` macro maps only primitive and
///   primitive-array parameter types, so a nested `{find, replace, replacesAll}`
///   array is not expressible as an operation parameter.
@Generable
@Operation(verb: "edit", noun: "file", description: "Edit a file's contents by a batch of find/replace pairs, committed atomically with encoding and line-ending preservation")
public struct EditFile: Sendable {
    /// The path of the file to edit.
    ///
    /// Aliased to accept the sah/native-Edit dialects' `path` and
    /// `absolute_path` spellings; the camelCase/snake_case `file_path` form
    /// resolves to `filePath` by the resolver's separator normalization.
    @OperationParam(aliases: ["path", "absolute_path"])
    public var filePath: String

    /// The `find` values to locate: one for a scalar edit, several for a parallel-array batch.
    ///
    /// Aliased to the native-Edit and sah find-dialect spellings so a payload
    /// keyed `old_string` (et al.) resolves to this parameter.
    @OperationParam(aliases: ["old_string", "old", "search", "from", "target", "match"])
    public var find: [String]?

    /// The `replace` values: one per `find`, or a single value broadcast across every `find`.
    ///
    /// Aliased to the native-Edit and sah replace-dialect spellings so a
    /// payload keyed `new_string` (et al.) resolves to this parameter.
    @OperationParam(aliases: ["new_string", "new", "to", "with", "replacement"])
    public var replace: [String]?

    /// Whether every occurrence of each `find` is rewritten rather than a single one; absent means the default (`false`).
    public var replacesAll: Bool?

    /// The 1-based occurrence selector that disambiguates among literal candidates, or `nil` for none.
    public var occurrence: Int?
}

extension EditFile {
    // MARK: Parameter defaults

    /// The `replacesAll` behavior used when ``replacesAll`` is absent.
    private static let defaultReplacesAll = false

    // MARK: Execution

    /// Edits the file and returns the edit result or a corrective message.
    ///
    /// Validates the path for an edit, reads and decodes the on-disk bytes
    /// (rejecting a binary file), records the line ending, normalizes the
    /// arguments, and resolves the whole batch in memory. A fully resolved batch
    /// is committed atomically with the detected encoding and preserved
    /// permission bits; an unresolved batch returns a structured outcome and
    /// leaves the file byte-identical. Every recoverable failure is returned as
    /// ``EditOutput/corrective(_:)``; nothing here throws for a bad path, an
    /// unreadable or binary file, an argument-shape error, or a failed commit.
    ///
    /// - Parameter context: the shared session context supplying the path guard.
    /// - Returns: the ``EditOutput/content(_:)`` result on success or a structured
    ///   outcome, or an ``EditOutput/corrective(_:)`` message the model can act on.
    /// - Throws: Nothing; the signature carries `throws` to satisfy the `OperationDefinition` protocol requirement.
    public func execute(in context: FileContext) async throws -> EditOutput {
        let url: URL
        switch context.pathGuard.validate(filePath, for: .edit) {
        case .success(let resolved):
            url = resolved
        case .failure(let violation):
            return .corrective(violation.message)
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return .corrective(Self.pathErrorMessage(description: Self.unreadableDescription, path: filePath))
        }

        guard let decoded = AtomicWriter.decode(data) else {
            return .corrective(Self.pathErrorMessage(description: Self.binaryDescription, path: filePath))
        }
        let lineEnding = AtomicWriter.detectLineEnding(in: decoded.text)

        let pairs: [EditEngine.Pair]
        switch EditEngine.normalize(Self.arguments(find: find, replace: replace, replacesAll: replacesAll, occurrence: occurrence)) {
        case .pairs(let shaped):
            pairs = shaped
        case .corrective(let message):
            return .corrective(message)
        }

        switch EditEngine.apply(pairs, to: decoded.text) {
        case .applied(let content, let edits):
            return await Self.commit(content: content, edits: edits, to: url, decoded: decoded, lineEnding: lineEnding, path: filePath, context: context)
        case .failed(_, let pair, let resolution):
            return .content(Self.unresolvedResult(path: url.path, pair: pair, resolution: resolution))
        }
    }

    /// Build the ``EditEngine/EditArguments`` for the operation's parameters.
    ///
    /// - Parameters:
    ///   - find: the `find` values, or `nil`.
    ///   - replace: the `replace` values, or `nil`.
    ///   - replacesAll: the `replacesAll` flag, or `nil`.
    ///   - occurrence: the `occurrence` selector, or `nil`.
    /// - Returns: the normalized arguments, with absent arrays treated as empty.
    private static func arguments(
        find: [String]?,
        replace: [String]?,
        replacesAll: Bool?,
        occurrence: Int?
    ) -> EditEngine.EditArguments {
        EditEngine.EditArguments(
            finds: find ?? [],
            replaces: replace ?? [],
            replaceAll: replacesAll ?? defaultReplacesAll,
            occurrence: occurrence
        )
    }

    // MARK: Commit

    /// Commit a fully resolved batch in a single atomic write, or return a corrective on failure.
    ///
    /// Re-encodes the committed content with the file's detected encoding
    /// (``AtomicWriter/encode(_:as:)``, the inverse of the decode that read it)
    /// and writes it through ``AtomicWriter/write(_:to:)``, which preserves the
    /// existing permission bits and removes its temporary file on any failure.
    ///
    /// - Parameters:
    ///   - content: the fully rewritten content to commit.
    ///   - edits: the per-pair applied-edit records.
    ///   - url: the resolved target URL.
    ///   - decoded: the decoded original, supplying the encoding to re-apply.
    ///   - lineEnding: the detected line-ending convention to record, or `nil`.
    ///   - path: the requested path, for a corrective message.
    ///   - context: the shared session context supplying the diagnostics bridge.
    /// - Returns: the applied ``EditOutput/content(_:)``, or an
    ///   ``EditOutput/corrective(_:)`` when the atomic write fails.
    private static func commit(
        content: String,
        edits: [EditEngine.AppliedEdit],
        to url: URL,
        decoded: AtomicWriter.DecodedText,
        lineEnding: AtomicWriter.LineEnding?,
        path: String,
        context: FileContext
    ) async -> EditOutput {
        let data = AtomicWriter.encode(content, as: decoded.encoding)
        do {
            try AtomicWriter.write(data, to: url)
        } catch {
            return .corrective(Self.pathErrorMessage(description: Self.commitFailureDescription, path: path))
        }
        let diagnostics = await context.diagnostics.diagnose(fileAt: url)
        return .content(
            EditResult(
                path: url.path,
                status: EditOutcomeProjection.appliedStatus,
                applied: edits.count,
                outcomes: edits.map { EditOutcomeProjection.outcome(for: $0.resolution, find: $0.pair.find) },
                bytesWritten: data.count,
                encoding: decoded.encoding.rawValue,
                lineEndings: lineEnding?.rawValue,
                hash: Hashline.wholeFileHash(bytes: data),
                taggedContent: Hashline.taggedLines(of: content),
                diagnostics: diagnostics
            )
        )
    }

    /// Build the byte-identical (uncommitted) result for a batch that short-circuited on an unresolved pair.
    ///
    /// The commit-only fields (`bytesWritten`, `encoding`, `lineEndings`, `hash`,
    /// `taggedContent`) are all `nil`: nothing was written and the file is
    /// byte-identical.
    ///
    /// - Parameters:
    ///   - path: the resolved absolute path.
    ///   - pair: the pair that failed to resolve.
    ///   - resolution: the non-definite resolution that short-circuited the batch.
    /// - Returns: the structured, retryable ``EditResult``.
    private static func unresolvedResult(
        path: String,
        pair: EditEngine.Pair,
        resolution: EditEngine.Resolution
    ) -> EditResult {
        EditResult(
            path: path,
            status: EditOutcomeProjection.statusName(for: resolution),
            applied: 0,
            outcomes: [EditOutcomeProjection.outcome(for: resolution, find: pair.find)],
            bytesWritten: nil,
            encoding: nil,
            lineEndings: nil,
            hash: nil,
            taggedContent: nil,
            diagnostics: nil
        )
    }

    // MARK: Corrective messages

    /// The description of a path that validated but whose bytes could not be read, before the `: path` suffix.
    private static let unreadableDescription = "The file could not be read"

    /// The description of a non-UTF-8 (binary) file, which is never decoded, before the `: path` suffix.
    private static let binaryDescription =
        "The file is not valid UTF-8 text and appears to be binary, so it cannot be edited as text"

    /// The description of a resolved batch whose atomic commit failed, before the `: path` suffix.
    private static let commitFailureDescription = "The edit resolved but could not be committed"

    /// A corrective message for a failed path, formatted as `<description>: <path>`.
    ///
    /// The single template behind the unreadable, binary, and commit-failure
    /// messages, which differ only by their leading description, so the shared
    /// `<description>: <path>` shape lives in one place.
    ///
    /// - Parameters:
    ///   - description: the leading description of what went wrong.
    ///   - path: the requested path.
    /// - Returns: the corrective message.
    private static func pathErrorMessage(description: String, path: String) -> String {
        "\(description): \(path)"
    }
}
