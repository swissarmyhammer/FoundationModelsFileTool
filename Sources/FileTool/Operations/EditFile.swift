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

    /// Creates a near-miss.
    ///
    /// - Parameters:
    ///   - startLine: the 1-based first line of the span.
    ///   - endLine: the 1-based last line of the span.
    ///   - lines: the line-level diff of `find` against the span's current text.
    public init(startLine: Int, endLine: Int, lines: [EditDiffLine]) {
        self.startLine = startLine
        self.endLine = endLine
        self.lines = lines
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
    public var filePath: String

    /// The `find` values to locate: one for a scalar edit, several for a parallel-array batch.
    public var find: [String]?

    /// The `replace` values: one per `find`, or a single value broadcast across every `find`.
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

    // MARK: Status names

    /// The model-facing wire names of the resolution outcomes, as data.
    ///
    /// A `String`-raw-valued mirror of ``EditEngine/Resolution``'s cases, so the
    /// wire names live as raw-value data in a single declaration — exactly as
    /// ``AtomicWriter/LineEnding`` and ``AtomicWriter/TextEncoding`` carry theirs
    /// and are read here as `.rawValue` — rather than as string literals repeated
    /// across parallel `switch` arms.
    ///
    /// ``EditEngine/Resolution`` carries associated values (candidates,
    /// near-misses, byte ranges) and so cannot itself key a lookup dictionary;
    /// ``statusName(for:)`` maps each engine case to a member of this table and
    /// reads the wire name from the non-optional ``rawValue``.
    private enum StatusName: String {
        case anchor
        case literal
        case recovered
        case ambiguous
        case nearMiss
        case alreadyApplied
        case consumedTarget
    }

    /// The ``EditResult/status`` and ``EditOutcome/matchedBy`` name of a resolution.
    ///
    /// The single mapping from an ``EditEngine/Resolution`` to its wire name,
    /// shared by the applied per-pair outcomes (definite `anchor` / `literal` /
    /// `recovered` matches) and the whole-batch status of an unresolved batch
    /// (`ambiguous` / `nearMiss` / `alreadyApplied` / `consumedTarget`), so the
    /// two never drift. The wire name is read from ``StatusName`` data; this
    /// switch only routes each engine case to its member.
    ///
    /// - Parameter resolution: the resolution to name.
    /// - Returns: the wire name of the resolution.
    private static func statusName(for resolution: EditEngine.Resolution) -> String {
        let name: StatusName
        switch resolution {
        case .anchor: name = .anchor
        case .literal: name = .literal
        case .recovered: name = .recovered
        case .ambiguous: name = .ambiguous
        case .noMatch: name = .nearMiss
        case .alreadyApplied: name = .alreadyApplied
        case .consumedTarget: name = .consumedTarget
        }
        return name.rawValue
    }

    /// The whole-batch status of a successfully applied batch.
    private static let appliedStatus = "applied"

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
                status: appliedStatus,
                applied: edits.count,
                outcomes: edits.map { outcome(for: $0.resolution, find: $0.pair.find) },
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
            status: statusName(for: resolution),
            applied: 0,
            outcomes: [outcome(for: resolution, find: pair.find)],
            bytesWritten: nil,
            encoding: nil,
            lineEndings: nil,
            hash: nil,
            taggedContent: nil,
            diagnostics: nil
        )
    }

    // MARK: Outcome mapping

    /// The corrective note for an already-applied outcome.
    private static let alreadyAppliedNote =
        "The edit appears to have been applied already: the `find` is absent and the `replace` is already present."

    /// The corrective note for a consumed-target outcome.
    private static let consumedTargetNote =
        "An earlier edit in this batch consumed this `find`: it was present before the batch but is now gone."

    /// Map one ``EditEngine/Resolution`` to its `Encodable` ``EditOutcome``.
    ///
    /// The single translation from the engine's resolution cases to the wire
    /// outcome: a definite match carries its ``EditOutcome/matchedBy`` (and the
    /// resolved line for an anchor); an ambiguous or near-miss outcome carries
    /// the mapped candidates or near-misses; a reclassified outcome carries an
    /// explanatory note.
    ///
    /// - Parameters:
    ///   - resolution: the resolution to project.
    ///   - find: the pair's `find` value, carried through onto the outcome.
    /// - Returns: the `Encodable` outcome.
    private static func outcome(for resolution: EditEngine.Resolution, find: String) -> EditOutcome {
        let matchedBy = statusName(for: resolution)
        switch resolution {
        case .anchor(let line):
            return EditOutcome(matchedBy: matchedBy, find: find, line: line)
        case .literal, .recovered:
            return EditOutcome(matchedBy: matchedBy, find: find)
        case .ambiguous(let candidates):
            return EditOutcome(matchedBy: matchedBy, find: find, candidates: candidates.map(candidateOutput))
        case .noMatch(let nearMisses):
            return EditOutcome(matchedBy: matchedBy, find: find, nearMisses: nearMisses.map(nearMissOutput))
        case .alreadyApplied:
            return EditOutcome(matchedBy: matchedBy, find: find, note: alreadyAppliedNote)
        case .consumedTarget:
            return EditOutcome(matchedBy: matchedBy, find: find, note: consumedTargetNote)
        }
    }

    /// Project an ``EditEngine/Candidate`` to its `Encodable` ``EditCandidate``.
    ///
    /// - Parameter candidate: the engine candidate to project.
    /// - Returns: the `Encodable` candidate.
    private static func candidateOutput(_ candidate: EditEngine.Candidate) -> EditCandidate {
        EditCandidate(
            occurrence: candidate.occurrence,
            line: candidate.line,
            text: candidate.text,
            context: candidate.context.map { EditContextLine(line: $0.line, text: $0.text) }
        )
    }

    /// Project an ``EditEngine/NearMiss`` to its `Encodable` ``EditNearMiss``.
    ///
    /// - Parameter nearMiss: the engine near-miss to project.
    /// - Returns: the `Encodable` near-miss.
    private static func nearMissOutput(_ nearMiss: EditEngine.NearMiss) -> EditNearMiss {
        EditNearMiss(
            startLine: nearMiss.startLine,
            endLine: nearMiss.endLine,
            lines: nearMiss.lines.map { EditDiffLine(change: changeName(for: $0.change), text: $0.text) }
        )
    }

    /// The model-facing wire names of a diff line's change, as data.
    ///
    /// A `String`-raw-valued mirror of ``EditEngine/DiffLine/Change``'s cases, so
    /// the wire names are data declared once and read via the non-optional
    /// ``rawValue`` — matching the ``StatusName`` treatment above and the
    /// codebase's ``AtomicWriter/LineEnding`` idiom — rather than string literals
    /// across parallel `switch` arms.
    private enum ChangeName: String {
        case unchanged
        case expected
        case actual
    }

    /// The wire name of a diff line's ``EditEngine/DiffLine/Change``.
    ///
    /// The wire name is read from ``ChangeName`` data; this switch only routes
    /// each engine case to its member.
    ///
    /// - Parameter change: the diff-line change to name.
    /// - Returns: `unchanged`, `expected`, or `actual`.
    private static func changeName(for change: EditEngine.DiffLine.Change) -> String {
        let name: ChangeName
        switch change {
        case .unchanged: name = .unchanged
        case .expected: name = .expected
        case .actual: name = .actual
        }
        return name.rawValue
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
