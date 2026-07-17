import Foundation
import FoundationModels
import Operations

/// The per-file result of a committed patch: what happened to one touched file.
///
/// The `Encodable` projection of a single ``PatchEngine/FileOutcome``. The
/// commit-only fields (``bytesWritten``, ``hash``) are `nil` for a `deleted`
/// file, which commits no bytes; ``movedTo`` is the absolute destination path
/// for a `moved` file and `nil` otherwise. There is deliberately **no
/// `taggedContent`** here (unlike ``WriteResult`` / ``EditResult``): echoing
/// every touched file's hashline-tagged content back into a small on-device
/// context is too expensive for a multi-file patch, so a chained edit
/// re-anchors with `read file` instead.
public struct PatchFileResult: Encodable, Sendable {
    /// The absolute path acted on (the source path for a move).
    public let path: String

    /// The action the file underwent: `added`, `modified`, `deleted`, or `moved`.
    public let action: String

    /// The absolute destination path for a `moved` file; `nil` otherwise.
    public let movedTo: String?

    /// The number of find/replace pairs applied (`0` for an Add, Delete, or pure rename).
    public let applied: Int

    /// The number of bytes committed, or `nil` for a `deleted` file.
    public let bytesWritten: Int?

    /// The whole-file freshness token over the committed bytes, or `nil` for a `deleted` file.
    public let hash: String?

    /// Creates a per-file patch result.
    ///
    /// - Parameters:
    ///   - path: the absolute path acted on (the source path for a move).
    ///   - action: the action the file underwent.
    ///   - movedTo: the destination path for a moved file, or `nil`.
    ///   - applied: the number of find/replace pairs applied.
    ///   - bytesWritten: the number of bytes committed, or `nil`.
    ///   - hash: the whole-file freshness token over the committed bytes, or `nil`.
    public init(
        path: String,
        action: String,
        movedTo: String?,
        applied: Int,
        bytesWritten: Int?,
        hash: String?
    ) {
        self.path = path
        self.action = action
        self.movedTo = movedTo
        self.applied = applied
        self.bytesWritten = bytesWritten
        self.hash = hash
    }
}

/// The result of a `patch files` operation: the whole-patch status and, when applied, the per-file outcomes.
///
/// The ``status`` names the whole-patch result: `applied` when every hunk
/// resolved and the all-or-nothing multi-file commit landed, or one of the
/// structured retryable outcomes (`ambiguous`, `nearMiss`, `alreadyApplied`,
/// `consumedTarget`) that leave **every** file byte-identical and commit
/// nothing. On an `applied` result ``files`` lists one ``PatchFileResult`` per
/// touched file and the unresolved fields (``path``, ``outcome``) are `nil`. On
/// an unresolved result ``files`` is empty and ``path`` / ``outcome`` carry the
/// single failing file's path and the same ``EditOutcome`` — with the identical
/// candidates and near-miss diffs — `edit file` produces, so the model can
/// disambiguate and retry exactly as it would for a single-file edit.
public struct PatchResult: Encodable, Sendable {
    /// The whole-patch status: `applied`, `ambiguous`, `nearMiss`, `alreadyApplied`, or `consumedTarget`.
    public let status: String

    /// The per-file outcomes for an `applied` patch; empty for an unresolved outcome.
    public let files: [PatchFileResult]

    /// The failing file's absolute path for an unresolved outcome; `nil` when applied.
    public let path: String?

    /// The single failing pair's outcome for an unresolved outcome; `nil` when applied.
    public let outcome: EditOutcome?

    /// Creates a patch result.
    ///
    /// - Parameters:
    ///   - status: the whole-patch status.
    ///   - files: the per-file outcomes; empty for an unresolved outcome.
    ///   - path: the failing file's path for an unresolved outcome, or `nil`.
    ///   - outcome: the single failing outcome for an unresolved outcome, or `nil`.
    public init(status: String, files: [PatchFileResult], path: String?, outcome: EditOutcome?) {
        self.status = status
        self.files = files
        self.path = path
        self.outcome = outcome
    }
}

/// The outcome of a `patch files` operation: either the patch result or a corrective message.
///
/// Follows the upstream *return-don't-throw* convention (the same convention
/// ``EditOutput``, ``WriteOutput``, and ``ReadOutput`` embody) via
/// ``CorrectiveEncodable``: a malformed envelope (surfaced with the offending
/// line number), a path violation, an add onto an existing file, a delete of a
/// missing file, a binary update target, a cross-file conflict, or a
/// stage/commit/unlink failure is surfaced as a ``corrective(_:)`` message the
/// model reads and acts on within the turn, never thrown. The structured
/// retryable outcomes (`ambiguous`, `nearMiss`, `alreadyApplied`,
/// `consumedTarget`) are *not* correctives: they ride in a ``content(_:)``
/// ``PatchResult`` with the matching status and leave every file byte-identical.
public enum PatchOutput: CorrectiveEncodable, Sendable {
    /// A resolved patch carrying the ``PatchResult`` (applied or a structured retryable outcome).
    case content(PatchResult)

    /// A recoverable hard failure carrying a corrective message for the model.
    case corrective(String)

    /// The ``PatchResult`` (encoded inline), or `nil` for a corrective outcome.
    public var successResult: PatchResult? {
        if case .content(let result) = self { return result }
        return nil
    }

    /// The corrective message, or `nil` for a successful outcome.
    public var correctiveMessage: String? {
        if case .corrective(let message) = self { return message }
        return nil
    }
}

/// The whole `patch files` contract, taught in prose for the model to fill the `patch` scalar.
///
/// Referenced as ``PatchFiles``'s `@Operation` description so it becomes both
/// the op's model-facing abstract and its CLI help. FoundationModels have zero
/// `apply_patch` training exposure, so — like grok's `apply_patch` `DESCRIPTION`
/// constant — this string carries the entire envelope syntax: the
/// `*** Begin Patch` / `*** End Patch` markers, `+`-prefixed Add bodies,
/// `*** Find:` / `*** Replace:` update bodies (verbatim or hashline-tagged),
/// `*** Move to:` renames, `*** Delete File:`, and one worked multi-file
/// example.
///
/// It lives at file scope, not as a `PatchFiles` member: the `@Operation` macro
/// reads the description argument's source text, and a `PatchFiles.<member>`
/// reference there is a circular reference (resolving the member re-enters the
/// macro expansion), whereas a top-level constant resolves independently.
private let patchFilesFormatTeaching = """
    Apply a multi-file patch in ONE call. The whole patch is a single text envelope passed as `patch`.

    Envelope shape (every marker starts with `*** ` at the start of the line):

    *** Begin Patch
    <one or more file sections>
    *** End Patch

    File sections:

    1. Add a new file (fails if it already exists):
    *** Add File: /abs/path/new.txt
    +every content line is prefixed with a single `+`
    +the `+` is stripped and the joined lines become the file

    2. Update an existing file with one or more find/replace pairs:
    *** Update File: /abs/path/existing.txt
    *** Find:
    <the exact lines to locate — either verbatim text, or lines copied from a `read file` result WITH their `N:HH|` hashline tags left on>
    *** Replace:
    <the replacement lines (may be empty to delete the found lines)>
    You may repeat `*** Find:` / `*** Replace:` to send several edits for the same file.

    3. Delete a file:
    *** Delete File: /abs/path/gone.txt

    4. Rename (optionally while editing): put `*** Move to:` immediately after the Update header:
    *** Update File: /abs/path/old.txt
    *** Move to: /abs/path/new.txt
    *** Find:
    old text
    *** Replace:
    new text

    Worked example creating one file and editing another:

    *** Begin Patch
    *** Add File: /repo/notes.txt
    +first note
    +second note
    *** Update File: /repo/main.swift
    *** Find:
    let version = 1
    *** Replace:
    let version = 2
    *** End Patch

    Use absolute paths. All sections apply together atomically: if any section fails (bad path, a Find that does not match, an Add onto an existing file), NOTHING is written and a corrective explains what to fix.
    """

/// Applies a multi-file patch envelope — Add / Update / Delete / Move sections with hashline Find/Replace bodies — as one all-or-nothing mutation.
///
/// The wire layer over ``PatchParser`` and ``PatchEngine``: it parses the single
/// `patch` scalar into hunks (a ``ParseFailure`` becomes a corrective carrying
/// the offending line number), then runs the two-phase engine against the
/// context's ``PathGuard`` (a path violation, add-onto-existing, missing-delete,
/// binary target, cross-file conflict, or stage/commit/unlink failure becomes a
/// corrective; an unresolved Update pair becomes a structured ``PatchResult``
/// with the failing file's path and the same candidates/near-misses `edit file`
/// produces, reusing ``EditOutcomeProjection`` so the two never drift). A fully
/// resolved patch commits every hunk atomically and reports one
/// ``PatchFileResult`` per touched file.
///
/// - Note: The whole envelope rides in one scalar `patch` parameter. That is the
///   shape that sidesteps the `@Operation` macro's primitives-only parameter
///   limit — the envelope's nested Add/Update/Delete/Move structure is expressed
///   inside the string, not as nested operation parameters — and it lets the
///   format-teaching description carry the entire contract, which is essential
///   because FoundationModels have no `apply_patch` training exposure.
@Generable
@Operation(verb: "patch", noun: "files", description: patchFilesFormatTeaching)
public struct PatchFiles: Sendable {
    /// The complete patch envelope: `*** Begin Patch` … `*** End Patch` with Add/Update/Delete/Move sections.
    ///
    /// Aliased to `input` so a payload emitted in the codex/grok `apply_patch`
    /// dialect (whose single argument is named `input`) resolves onto this
    /// parameter, the same dialect-parity aliasing the other file operations
    /// carry.
    @OperationParam(aliases: ["input"])
    public var patch: String
}

extension PatchFiles {
    // MARK: Execution

    /// Parses and applies the patch envelope, returning the patch result or a corrective message.
    ///
    /// Parses the `patch` scalar via ``PatchParser`` (a parse failure becomes a
    /// corrective naming the offending line), then applies the parsed hunks via
    /// ``PatchEngine/apply(_:using:)`` against the context's path guard. A fully
    /// resolved patch returns the applied ``PatchResult``; an unresolved Update
    /// pair returns a structured, byte-identical result; every recoverable
    /// failure is returned as ``PatchOutput/corrective(_:)``. Nothing here
    /// throws.
    ///
    /// - Parameter context: the shared session context supplying the path guard.
    /// - Returns: the ``PatchOutput/content(_:)`` result on success or a
    ///   structured outcome, or a ``PatchOutput/corrective(_:)`` message the
    ///   model can act on.
    /// - Throws: Nothing; the signature carries `throws` to satisfy the `OperationDefinition` protocol requirement.
    public func execute(in context: FileContext) async throws -> PatchOutput {
        let hunks: [PatchParser.Hunk]
        switch PatchParser.parse(patch) {
        case .success(let parsed):
            hunks = parsed
        case .failure(let failure):
            return .corrective(failure.description)
        }

        switch PatchEngine.apply(hunks, using: context.pathGuard) {
        case .success(let outcomes):
            return .content(Self.appliedResult(from: outcomes))
        case .failure(let failure):
            return Self.output(for: failure)
        }
    }

    // MARK: Result projection

    /// Build the applied ``PatchResult`` projecting every committed file outcome.
    ///
    /// - Parameter outcomes: the engine's per-file outcomes for the committed patch.
    /// - Returns: the applied result, with the unresolved fields left `nil`.
    private static func appliedResult(from outcomes: [PatchEngine.FileOutcome]) -> PatchResult {
        PatchResult(
            status: EditOutcomeProjection.appliedStatus,
            files: outcomes.map(fileResult),
            path: nil,
            outcome: nil
        )
    }

    /// Project one ``PatchEngine/FileOutcome`` to its `Encodable` ``PatchFileResult``.
    ///
    /// The ``PatchEngine/Action`` wire name is read straight from the engine
    /// enum's ``PatchEngine/Action/rawValue``, so the action vocabulary
    /// (`added` / `modified` / `deleted` / `moved`) is single-sourced there
    /// rather than restated as a mapping table here.
    ///
    /// - Parameter outcome: the engine file outcome to project.
    /// - Returns: the `Encodable` per-file result.
    private static func fileResult(_ outcome: PatchEngine.FileOutcome) -> PatchFileResult {
        PatchFileResult(
            path: outcome.path,
            action: outcome.action.rawValue,
            movedTo: outcome.movedTo,
            applied: outcome.appliedPairs,
            bytesWritten: outcome.bytesWritten,
            hash: outcome.hash
        )
    }

    /// Map an engine ``PatchEngine/Failure`` to its ``PatchOutput``.
    ///
    /// A ``PatchEngine/Failure/corrective(_:)`` rides straight through as a
    /// corrective; a ``PatchEngine/Failure/unresolved(path:pair:resolution:)``
    /// becomes a structured, byte-identical ``PatchResult`` carrying the failing
    /// file's path and the same ``EditOutcome`` `edit file` produces.
    ///
    /// - Parameter failure: the engine failure to project.
    /// - Returns: the corresponding output.
    private static func output(for failure: PatchEngine.Failure) -> PatchOutput {
        switch failure {
        case .corrective(let message):
            return .corrective(message)
        case .unresolved(let path, let pair, let resolution):
            return .content(unresolvedResult(path: path, pair: pair, resolution: resolution))
        }
    }

    /// Build the byte-identical (uncommitted) result for a patch that short-circuited on an unresolved Update pair.
    ///
    /// The ``PatchResult/status`` and ``PatchResult/outcome`` come from
    /// ``EditOutcomeProjection`` — the same mapping `edit file` uses — so the
    /// wire status and candidates/near-misses are identical to a single-file
    /// edit's. ``PatchResult/files`` is empty: nothing was committed and every
    /// file is byte-identical (asserted by the engine).
    ///
    /// - Parameters:
    ///   - path: the failing file's absolute path.
    ///   - pair: the pair that failed to resolve.
    ///   - resolution: the non-definite resolution that short-circuited the patch.
    /// - Returns: the structured, retryable result.
    private static func unresolvedResult(
        path: String,
        pair: EditEngine.Pair,
        resolution: EditEngine.Resolution
    ) -> PatchResult {
        PatchResult(
            status: EditOutcomeProjection.statusName(for: resolution),
            files: [],
            path: path,
            outcome: EditOutcomeProjection.outcome(for: resolution, find: pair.find)
        )
    }
}
