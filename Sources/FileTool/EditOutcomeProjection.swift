import Foundation

/// The shared projection from an ``EditEngine/Resolution`` to its model-facing wire vocabulary, used by both `edit file` and `patch files`.
///
/// `edit file` and `patch files` both resolve find/replace pairs through the
/// same ``EditEngine`` cascade, so they must report an identical wire
/// vocabulary: the ``EditResult/status`` / ``EditOutcome/matchedBy`` names, and
/// the ``EditOutcome`` candidate and near-miss projections. Housing that mapping
/// here — rather than in one operation the other reaches into — keeps the two
/// ops' reporting from drifting: there is exactly one ``EditEngine/Resolution``
/// → wire-name table and one ``EditEngine/Resolution`` → ``EditOutcome``
/// translation, shared by both.
enum EditOutcomeProjection {
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

    /// The whole-batch status of a successfully applied batch or patch.
    static let appliedStatus = "applied"

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
    static func statusName(for resolution: EditEngine.Resolution) -> String {
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
    static func outcome(for resolution: EditEngine.Resolution, find: String) -> EditOutcome {
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
            lines: nearMiss.lines.map { EditDiffLine(change: changeName(for: $0.change), text: $0.text) },
            note: nearMiss.note
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
}
