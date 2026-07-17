import Foundation

/// Two-phase, all-or-nothing applier that turns parsed ``PatchParser/Hunk`` values into multi-file mutations.
///
/// The engine is the orchestration layer above the pure primitives: it composes
/// ``PathGuard`` (path validation), ``AtomicWriter`` (decode / encode / staged
/// write), and ``EditEngine`` (the find/replace resolution cascade) into a single
/// patch application, modeled on grok's `compute_all_changes` but stronger on
/// write atomicity. It performs file IO but stays free of the `@Operation` /
/// `Encodable` wire layer, returning engine-level ``FileOutcome`` values the way
/// ``EditEngine`` stays pure of ``EditFile``'s projection; the `patch files`
/// operation projects them.
///
/// **Phase 1 — compute (``computeChanges(_:using:)``).** Every hunk's path is
/// validated (`.write` for an Add, `.delete` for a Delete, `.edit` for an Update
/// with the move destination validated `.write`), and each file's resulting bytes
/// are computed *in memory* — Updates run the ``EditEngine`` cascade against the
/// decoded original — without touching the filesystem. The first hunk that fails
/// aborts the whole patch. Cross-file conflicts are then detected: two hunks that
/// produce the same final path, or a produced path that is also a delete target,
/// abort the patch (the ``PatchParser`` deliberately leaves move-destination
/// collisions to apply-order semantics here, so a legal filename swap or rotation
/// — distinct final paths — is preserved while a genuine collision is rejected).
///
/// **Phase 2 — write (``writeChanges(_:)``).** Every add/update/move-destination
/// write is staged via ``AtomicWriter/stage(_:to:)`` first; a stage failure
/// discards every staged temporary and aborts with destinations untouched. Only
/// once all stages succeed are they committed, then move sources and delete
/// targets are unlinked — deletes last, and never a path that is also a write
/// destination, so a swap or rotation keeps the content another hunk wrote.
public enum PatchEngine {
    // MARK: Public result types

    /// The action a patched file underwent, as data.
    ///
    /// A `String`-raw-valued enum so the model-facing names live as data read via
    /// the non-optional `rawValue`, matching the ``AtomicWriter/LineEnding`` and
    /// ``AtomicWriter/TextEncoding`` idiom, rather than string literals repeated
    /// across the projection layer.
    public enum Action: String, Equatable, Sendable {
        /// A new file was created (an Add).
        case added
        /// An existing file's contents were rewritten in place (an Update).
        case modified
        /// A file was removed (a Delete).
        case deleted
        /// A file was renamed to ``FileOutcome/movedTo`` (an Update with a Move).
        case moved
    }

    /// The per-file result of a committed patch: what happened to one file.
    ///
    /// The engine-level outcome the `patch files` operation projects into its wire
    /// output. The commit-only fields (``bytesWritten``, ``hash``) are `nil` for a
    /// ``Action/deleted`` file, which commits no bytes; ``movedTo`` is the
    /// destination path for a ``Action/moved`` file and `nil` otherwise.
    public struct FileOutcome: Equatable, Sendable {
        /// The absolute path acted on (the source path for a move).
        public let path: String

        /// The action the file underwent.
        public let action: Action

        /// The absolute destination path for a ``Action/moved`` file; `nil` otherwise.
        public let movedTo: String?

        /// The number of find/replace pairs applied (`0` for an Add, Delete, or pure rename).
        public let appliedPairs: Int

        /// The number of bytes committed, or `nil` for a deleted file.
        public let bytesWritten: Int?

        /// The whole-file freshness token over the committed bytes, or `nil` for a deleted file.
        public let hash: String?

        /// Creates a per-file outcome.
        ///
        /// - Parameters:
        ///   - path: the absolute path acted on (the source path for a move).
        ///   - action: the action the file underwent.
        ///   - movedTo: the destination path for a moved file, or `nil`.
        ///   - appliedPairs: the number of find/replace pairs applied.
        ///   - bytesWritten: the number of bytes committed, or `nil`.
        ///   - hash: the whole-file freshness token over the committed bytes, or `nil`.
        public init(
            path: String,
            action: Action,
            movedTo: String?,
            appliedPairs: Int,
            bytesWritten: Int?,
            hash: String?
        ) {
            self.path = path
            self.action = action
            self.movedTo = movedTo
            self.appliedPairs = appliedPairs
            self.bytesWritten = bytesWritten
            self.hash = hash
        }
    }

    /// Why a patch was rejected, before or during application.
    ///
    /// Follows the upstream *return-don't-throw* convention (shared with
    /// ``PathViolation`` and ``ParseFailure``): a rejection is a `Result` failure,
    /// never raised. ``corrective(_:)`` carries a message the model reads and acts
    /// on — a path violation, an add onto an existing file, a delete of a missing
    /// file, a binary update target, a cross-file conflict, or a stage/commit
    /// failure. ``unresolved(path:pair:resolution:)`` carries the failing file's
    /// path, the failing ``EditEngine/Pair``, and its non-definite
    /// ``EditEngine/Resolution`` so the operation can surface the same candidates
    /// and near-misses `edit file` does. The type conforms to `Error` only so it
    /// can be a `Result` failure — it is never thrown out of the engine.
    public enum Failure: Error, Equatable, Sendable {
        /// A recoverable hard failure carrying a corrective message for the model.
        case corrective(String)

        /// An Update pair that did not resolve, carrying the file path and the engine resolution.
        case unresolved(path: String, pair: EditEngine.Pair, resolution: EditEngine.Resolution)
    }

    // MARK: Application

    /// Apply an ordered list of hunks as one all-or-nothing multi-file mutation.
    ///
    /// Runs phase 1 (``computeChanges(_:using:)``) to validate and compute every
    /// change in memory, then phase 2 (``writeChanges(_:)``) to stage, commit, and
    /// unlink. Any phase-1 failure leaves the filesystem untouched; a phase-2 stage
    /// failure discards every staged temporary, leaving destinations untouched.
    ///
    /// - Parameters:
    ///   - hunks: the parsed hunks to apply, in order.
    ///   - pathGuard: the guard that validates and resolves every path.
    /// - Returns: `.success` with the per-file outcomes, or `.failure` with a
    ///   ``Failure`` the operation layer projects.
    public static func apply(
        _ hunks: [PatchParser.Hunk],
        using pathGuard: PathGuard
    ) -> Result<[FileOutcome], Failure> {
        computeChanges(hunks, using: pathGuard).flatMap(writeChanges)
    }

    // MARK: Phase 1 — compute

    /// A computed, not-yet-written change for one hunk.
    ///
    /// The uniform in-memory representation phase 1 produces and phase 2 consumes:
    /// an optional ``Write`` (the staged bytes; `nil` for a pure Delete) and an
    /// optional ``Removal`` (a path to unlink after commits), plus the reported
    /// outcome fields. Modeling every hunk as one struct — rather than a parallel
    /// enum the write phase must re-switch on — keeps the two phases from drifting.
    private struct Change {
        /// The absolute path reported in the outcome (the source path for a move).
        let reportedPath: String

        /// The action the file underwent.
        let action: Action

        /// The absolute destination path for a move; `nil` otherwise.
        let movedTo: String?

        /// The number of find/replace pairs applied.
        let appliedPairs: Int

        /// The staged write to perform, or `nil` for a pure Delete.
        let write: Write?

        /// A path to unlink after all writes commit, or `nil`.
        let removal: Removal?
    }

    /// A file write to stage and commit: the destination and its final bytes.
    private struct Write {
        /// The resolved destination URL.
        let url: URL

        /// The bytes to commit, already re-encoded with the file's detected encoding.
        let data: Data
    }

    /// A path to unlink after all writes commit, tagged so deletes run last.
    private struct Removal {
        /// Whether the removal is a move's abandoned source or an explicit delete target.
        enum Kind {
            /// The source path of an Update-with-Move, removed after the destination commits.
            case moveSource
            /// The target of a Delete.
            case deleteTarget
        }

        /// Which kind of removal this is, controlling unlink ordering.
        let kind: Kind

        /// The resolved path to unlink.
        let url: URL
    }

    /// Compute every hunk's change in memory, then detect cross-file conflicts.
    ///
    /// Validates and resolves each hunk in order (aborting on the first failure),
    /// then rejects a patch whose changes collide on a final path. Nothing on disk
    /// is touched.
    ///
    /// - Parameters:
    ///   - hunks: the hunks to compute changes for.
    ///   - pathGuard: the guard that validates and resolves every path.
    /// - Returns: `.success` with the computed changes, or `.failure`.
    private static func computeChanges(
        _ hunks: [PatchParser.Hunk],
        using pathGuard: PathGuard
    ) -> Result<[Change], Failure> {
        var changes: [Change] = []
        for hunk in hunks {
            switch computeChange(hunk, using: pathGuard) {
            case .success(let change): changes.append(change)
            case .failure(let failure): return .failure(failure)
            }
        }
        if let conflict = conflictViolation(in: changes) {
            return .failure(.corrective(conflict))
        }
        return .success(changes)
    }

    /// Compute the change for one hunk, validating its path and resolving its bytes.
    ///
    /// - Parameters:
    ///   - hunk: the hunk to compute.
    ///   - pathGuard: the guard that validates and resolves the path.
    /// - Returns: `.success` with the computed change, or `.failure`.
    private static func computeChange(
        _ hunk: PatchParser.Hunk,
        using pathGuard: PathGuard
    ) -> Result<Change, Failure> {
        switch hunk {
        case .addFile(let path, let contents):
            return computeAdd(path: path, contents: contents, using: pathGuard)
        case .deleteFile(let path):
            return computeDelete(path: path, using: pathGuard)
        case .updateFile(let path, let movePath, let pairs):
            return computeUpdate(path: path, movePath: movePath, pairs: pairs, using: pathGuard)
        }
    }

    /// Compute an Add: validate `.write`, reject an existing target, and stage the new bytes.
    ///
    /// An Add means a *new* file (overwriting an existing file is `write file`'s
    /// job), so a target that already exists is a corrective. The contents are
    /// encoded as plain UTF-8 — a freshly created file has no prior encoding to
    /// preserve.
    ///
    /// - Parameters:
    ///   - path: the file to create.
    ///   - contents: the new file's contents.
    ///   - pathGuard: the guard that validates and resolves the path.
    /// - Returns: `.success` with the add change, or `.failure`.
    private static func computeAdd(
        path: String,
        contents: String,
        using pathGuard: PathGuard
    ) -> Result<Change, Failure> {
        validate(path, for: .write, using: pathGuard).flatMap { url in
            guard !fileExists(url) else {
                return .failure(.corrective(Messages.addExists(path: url.path)))
            }
            let data = AtomicWriter.encode(contents, as: .utf8)
            return .success(
                Change(
                    reportedPath: url.path,
                    action: .added,
                    movedTo: nil,
                    appliedPairs: 0,
                    write: Write(url: url, data: data),
                    removal: nil
                )
            )
        }
    }

    /// Compute a Delete: validate `.delete` and record the target for unlinking.
    ///
    /// The original bytes are deliberately *not* read: they are never reported and
    /// requiring readability would wrongly reject a deletable-but-unreadable file,
    /// since the `.delete` permission (unlink permission lives on the parent
    /// directory) does not require read access.
    ///
    /// - Parameters:
    ///   - path: the file to delete.
    ///   - pathGuard: the guard that validates and resolves the path.
    /// - Returns: `.success` with the delete change, or `.failure`.
    private static func computeDelete(
        path: String,
        using pathGuard: PathGuard
    ) -> Result<Change, Failure> {
        validate(path, for: .delete, using: pathGuard).map { url in
            Change(
                reportedPath: url.path,
                action: .deleted,
                movedTo: nil,
                appliedPairs: 0,
                write: nil,
                removal: Removal(kind: .deleteTarget, url: url)
            )
        }
    }

    /// Compute an Update: validate, decode, resolve the pairs, and stage the rewritten bytes.
    ///
    /// Validates the source `.edit` and, for a Move, the destination `.write`,
    /// reads and decodes the source (a binary file is a corrective), runs the
    /// ``EditEngine`` cascade over the decoded text (an unresolved pair aborts the
    /// patch, carrying the path and resolution), and re-encodes the result with the
    /// source's detected encoding — so a CRLF/BOM file keeps its convention through
    /// the decode/encode round-trip. A pure rename (a Move with no pairs) re-encodes
    /// the original content unchanged for the destination.
    ///
    /// - Parameters:
    ///   - path: the file to update.
    ///   - movePath: the rename destination, or `nil`.
    ///   - pairs: the find/replace pairs to apply, in order.
    ///   - pathGuard: the guard that validates and resolves the paths.
    /// - Returns: `.success` with the update change, or `.failure`.
    private static func computeUpdate(
        path: String,
        movePath: String?,
        pairs: [PatchParser.Pair],
        using pathGuard: PathGuard
    ) -> Result<Change, Failure> {
        validate(path, for: .edit, using: pathGuard).flatMap { sourceURL in
            resolveDestination(movePath, using: pathGuard).flatMap { destinationURL in
                decodeSource(sourceURL).flatMap { decoded in
                    resolveContent(pairs, in: decoded.text, path: sourceURL.path).map { resolved in
                        makeUpdateChange(
                            sourceURL: sourceURL,
                            destinationURL: destinationURL,
                            decoded: decoded,
                            resolved: resolved
                        )
                    }
                }
            }
        }
    }

    /// Resolve an optional move destination, validating it for `.write`.
    ///
    /// - Parameters:
    ///   - movePath: the rename destination, or `nil` for an in-place update.
    ///   - pathGuard: the guard that validates and resolves the path.
    /// - Returns: `.success` with the resolved destination URL, `.success(nil)`
    ///   for an in-place update, or `.failure`.
    private static func resolveDestination(
        _ movePath: String?,
        using pathGuard: PathGuard
    ) -> Result<URL?, Failure> {
        guard let movePath else { return .success(nil) }
        return validate(movePath, for: .write, using: pathGuard).map { $0 }
    }

    /// Read and decode a source file, rejecting an unreadable or binary file.
    ///
    /// - Parameter url: the resolved source URL.
    /// - Returns: `.success` with the decoded text and encoding, or `.failure`.
    private static func decodeSource(_ url: URL) -> Result<AtomicWriter.DecodedText, Failure> {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return .failure(.corrective(Messages.unreadable(path: url.path)))
        }
        guard let decoded = AtomicWriter.decode(data) else {
            return .failure(.corrective(Messages.binary(path: url.path)))
        }
        return .success(decoded)
    }

    /// The resolved content of an Update and the number of pairs applied.
    private struct ResolvedContent {
        /// The rewritten (or, for a pure rename, unchanged) content.
        let content: String

        /// The number of find/replace pairs applied.
        let appliedPairs: Int
    }

    /// Resolve an Update's find/replace pairs against the decoded source text.
    ///
    /// An empty pair list is a pure rename and yields the text unchanged. Otherwise
    /// the batch runs through ``EditEngine/apply(_:to:)`` with exactly `edit file`'s
    /// semantics; the first unresolved pair aborts the patch.
    ///
    /// - Parameters:
    ///   - pairs: the find/replace pairs, in order.
    ///   - text: the decoded source text to resolve against.
    ///   - path: the source path, carried on an unresolved failure.
    /// - Returns: `.success` with the resolved content, or `.failure` naming the
    ///   unresolved pair and its resolution.
    private static func resolveContent(
        _ pairs: [PatchParser.Pair],
        in text: String,
        path: String
    ) -> Result<ResolvedContent, Failure> {
        guard !pairs.isEmpty else {
            return .success(ResolvedContent(content: text, appliedPairs: 0))
        }
        let enginePairs = pairs.map { EditEngine.Pair(find: $0.find, replace: $0.replace) }
        switch EditEngine.apply(enginePairs, to: text) {
        case .applied(let content, let edits):
            return .success(ResolvedContent(content: content, appliedPairs: edits.count))
        case .failed(_, let pair, let resolution):
            return .failure(.unresolved(path: path, pair: pair, resolution: resolution))
        }
    }

    /// Assemble the ``Change`` for a resolved Update, choosing the write target and removal.
    ///
    /// An in-place update writes back to the source; a Move writes the destination
    /// and records the source for removal after the commit.
    ///
    /// - Parameters:
    ///   - sourceURL: the resolved source URL.
    ///   - destinationURL: the resolved move destination, or `nil` for in place.
    ///   - decoded: the decoded source, supplying the encoding to re-apply.
    ///   - resolved: the resolved content and applied-pair count.
    /// - Returns: the assembled change.
    private static func makeUpdateChange(
        sourceURL: URL,
        destinationURL: URL?,
        decoded: AtomicWriter.DecodedText,
        resolved: ResolvedContent
    ) -> Change {
        let writeURL = destinationURL ?? sourceURL
        let data = AtomicWriter.encode(resolved.content, as: decoded.encoding)
        return Change(
            reportedPath: sourceURL.path,
            action: destinationURL == nil ? .modified : .moved,
            movedTo: destinationURL?.path,
            appliedPairs: resolved.appliedPairs,
            write: Write(url: writeURL, data: data),
            removal: destinationURL.map { _ in Removal(kind: .moveSource, url: sourceURL) }
        )
    }

    // MARK: Cross-file conflict detection

    /// The conflict message when two changes collide on a final path, or `nil` when they do not.
    ///
    /// A patch is rejected when two hunks *produce* the same final path (two writes
    /// to one destination — the move-destination collision the ``PatchParser``
    /// leaves to apply-order semantics), or when a produced path is also a delete
    /// target (a file both written and deleted). Distinct final paths — a swap or
    /// rotation — pass.
    ///
    /// - Parameter changes: the computed changes to check.
    /// - Returns: a corrective message naming the colliding path, or `nil`.
    private static func conflictViolation(in changes: [Change]) -> String? {
        var produced: Set<String> = []
        for change in changes {
            guard let write = change.write else { continue }
            if !produced.insert(write.url.path).inserted {
                return Messages.conflict(path: write.url.path)
            }
        }
        for change in changes {
            if let removal = change.removal, removal.kind == .deleteTarget, produced.contains(removal.url.path) {
                return Messages.conflict(path: removal.url.path)
            }
        }
        return nil
    }

    // MARK: Phase 2 — write

    /// Stage, commit, and unlink every computed change as one atomic multi-file write.
    ///
    /// Stages every write first; a stage failure discards all staged temporaries
    /// and aborts with destinations untouched. Once every stage succeeds, the
    /// writes are committed and then move sources and delete targets are unlinked
    /// (deletes last, and never a path that is also a write destination). The
    /// per-file outcomes are computed from the committed bytes.
    ///
    /// - Parameter changes: the computed changes to write.
    /// - Returns: `.success` with the per-file outcomes, or `.failure`.
    private static func writeChanges(_ changes: [Change]) -> Result<[FileOutcome], Failure> {
        var staged: [AtomicWriter.StagedWrite] = []
        for write in changes.compactMap(\.write) {
            do {
                staged.append(try AtomicWriter.stage(write.data, to: write.url))
            } catch {
                staged.forEach { $0.discard() }
                return .failure(.corrective(Messages.stageFailure(path: write.url.path)))
            }
        }
        if let failure = commit(staged) {
            return .failure(failure)
        }
        performRemovals(changes)
        return .success(changes.map(outcome))
    }

    /// Commit every staged write, discarding the uncommitted remainder on a failure.
    ///
    /// The partial-write window the staged design shrinks to the sequence of
    /// renames: an interrupted commit leaves the already-committed writes in place
    /// and discards the temporaries not yet committed.
    ///
    /// - Parameter staged: the staged writes to commit, in order.
    /// - Returns: a ``Failure`` when a commit fails, or `nil` when all commit.
    private static func commit(_ staged: [AtomicWriter.StagedWrite]) -> Failure? {
        for (index, write) in staged.enumerated() {
            do {
                try write.commit()
            } catch {
                staged[index...].forEach { $0.discard() }
                return .corrective(Messages.commitFailure(path: write.destinationURL.path))
            }
        }
        return nil
    }

    /// Unlink move sources and delete targets, deletes last, skipping any write destination.
    ///
    /// The removal order is data — ``Removal/Kind/moveSource`` before
    /// ``Removal/Kind/deleteTarget`` — so "deletes last" is expressed once rather
    /// than as duplicated passes. A removal path that is also a write destination
    /// is skipped, so a swap (`a→b`, `b→a`) or rotation keeps the content a peer
    /// hunk wrote onto that path.
    ///
    /// - Parameter changes: the committed changes whose removals to perform.
    private static func performRemovals(_ changes: [Change]) {
        let writeDestinations = Set(changes.compactMap { $0.write?.url.path })
        for kind in removalOrder {
            for change in changes {
                guard let removal = change.removal, removal.kind == kind else { continue }
                guard !writeDestinations.contains(removal.url.path) else { continue }
                try? FileManager.default.removeItem(at: removal.url)
            }
        }
    }

    /// The order removals run in: move sources first, delete targets last.
    ///
    /// So an interrupted patch errs on the side of leaving extra files rather than
    /// losing content.
    private static let removalOrder: [Removal.Kind] = [.moveSource, .deleteTarget]

    /// Project a committed change into its per-file outcome.
    ///
    /// The commit-only fields are derived from the staged bytes, which are exactly
    /// the committed bytes (the temporary holding them was renamed onto the
    /// destination), so the reported ``FileOutcome/hash`` matches a subsequent
    /// `read file` over the same file.
    ///
    /// - Parameter change: the committed change.
    /// - Returns: the per-file outcome.
    private static func outcome(for change: Change) -> FileOutcome {
        FileOutcome(
            path: change.reportedPath,
            action: change.action,
            movedTo: change.movedTo,
            appliedPairs: change.appliedPairs,
            bytesWritten: change.write?.data.count,
            hash: change.write.map { Hashline.wholeFileHash(bytes: $0.data) }
        )
    }

    // MARK: Path validation

    /// Validate a path for an operation, mapping a violation to a corrective failure.
    ///
    /// - Parameters:
    ///   - path: the raw path to validate.
    ///   - operation: the access kind whose rule to apply.
    ///   - pathGuard: the guard to validate against.
    /// - Returns: `.success` with the resolved URL, or `.failure` carrying the
    ///   violation message as a corrective.
    private static func validate(
        _ path: String,
        for operation: FileOperation,
        using pathGuard: PathGuard
    ) -> Result<URL, Failure> {
        pathGuard.validate(path, for: operation).mapError { .corrective($0.message) }
    }

    /// Whether a file exists on disk at a URL, following symlinks.
    ///
    /// - Parameter url: the URL to test.
    /// - Returns: `true` when a file exists at the URL.
    private static func fileExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: Corrective messages

    /// The corrective messages for every patch rejection, defined in one place.
    private enum Messages {
        /// The corrective for an Add whose target already exists.
        ///
        /// - Parameter path: the existing target path.
        /// - Returns: the corrective message.
        static func addExists(path: String) -> String {
            "Cannot add a file that already exists: \(path). "
                + "Use an `*** Update File:` section to change an existing file."
        }

        /// The corrective for an Update source that could not be read.
        ///
        /// - Parameter path: the source path.
        /// - Returns: the corrective message.
        static func unreadable(path: String) -> String {
            "The file could not be read: \(path)"
        }

        /// The corrective for a binary (non-UTF-8) Update source.
        ///
        /// - Parameter path: the source path.
        /// - Returns: the corrective message.
        static func binary(path: String) -> String {
            "The file is not valid UTF-8 text and appears to be binary, so it cannot be patched as text: \(path)"
        }

        /// The corrective for two patch sections resolving to the same final path.
        ///
        /// - Parameter path: the colliding final path.
        /// - Returns: the corrective message.
        static func conflict(path: String) -> String {
            "Two patch sections target the same path `\(path)`; a patch must resolve each file exactly once."
        }

        /// The corrective for a write that could not be staged (nothing was changed).
        ///
        /// - Parameter path: the destination that failed to stage.
        /// - Returns: the corrective message.
        static func stageFailure(path: String) -> String {
            "A file in the patch could not be staged for writing, so no files were changed: \(path)"
        }

        /// The corrective for a staged write that could not be committed.
        ///
        /// - Parameter path: the destination that failed to commit.
        /// - Returns: the corrective message.
        static func commitFailure(path: String) -> String {
            "The patch resolved but a file could not be committed: \(path)"
        }
    }
}
