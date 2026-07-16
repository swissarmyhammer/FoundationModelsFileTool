import Foundation

/// Pure, IO-free literal-find recovery ladder for the `edit files` tool.
///
/// When an `edit files` operation supplies a bare-string `find` (not a hashline
/// anchor), that string is a *description* of a span, not a byte-exact copy: the
/// model may have dropped indentation, normalized line endings, or paraphrased
/// an interior line. ``findMatch(find:in:)`` resolves such a description to a
/// concrete byte span in the original content by climbing a four-rung ladder and
/// stopping at the first unique, confident match:
///
/// 1. ``Rung/exact`` — literal substring match.
/// 2. ``Rung/normalized`` — match after normalizing line endings and trailing
///    whitespace, returning the span in the *original* bytes so the caller edits
///    the original.
/// 3. ``Rung/anchor`` — match the unique first and last lines of `find` and span
///    the region between them, tolerating interior drift.
/// 4. ``Rung/fuzzy`` — similarity-scored match, accepted only when it clears
///    ``fuzzyAcceptThreshold`` and beats the runner-up by at least
///    ``fuzzyRunnerUpMargin``. A fuzzy match is never applied silently.
///
/// This is an algorithm-exact port of the Rust `swissarmyhammer-edit-match`
/// crate; the ladder rungs, thresholds, and outcomes mirror it rung-for-rung so
/// the Swift and Rust `edit files` tools resolve a drifted `find` to the same
/// byte span. Parity is pinned by golden vectors generated from the Rust crate
/// (`Tests/FileToolTests/Fixtures/edit-match-golden.json`).
///
/// All byte ranges returned index the **original** content's UTF-8 bytes, so a
/// located span preserves the original indentation and line endings even when
/// `find` had dropped them. The module performs no IO.
public enum EditMatch {
    // MARK: Public types

    /// Which rung of the ladder produced a match.
    public enum Rung: Equatable, Sendable {
        /// Literal substring match — the `find` occurs verbatim in the content.
        case exact
        /// Match after normalizing line endings and trailing whitespace.
        case normalized
        /// Match keyed on the unique first and last lines of `find`, spanning the
        /// (possibly drifted) interior between them.
        case anchor
        /// Similarity-scored match accepted under the fuzzy thresholds.
        case fuzzy
    }

    /// A located span in the original content.
    public struct Span: Equatable, Sendable {
        /// UTF-8 byte range into the original content.
        public let range: Range<Int>
        /// The 1-based first line of the span.
        public let startLine: Int
        /// The 1-based last line of the span.
        public let endLine: Int
        /// The original text covered by ``range``.
        public let text: String
    }

    /// The result of running the literal-find ladder.
    public enum MatchResult: Equatable, Sendable {
        /// Exactly one confident match was found.
        ///
        /// - `range`: the UTF-8 byte range into the original content the caller
        ///   should edit.
        /// - `rung`: which rung produced the match.
        /// - `confidence`: confidence in `[0.0, 1.0]` (`1.0` for the exact,
        ///   normalized, and anchor rungs; the similarity score for the fuzzy rung).
        case unique(range: Range<Int>, rung: Rung, confidence: Float)
        /// Two or more candidates tied with no confident winner; the caller must
        /// not pick one silently.
        ///
        /// - `candidates`: the competing candidate spans.
        case ambiguous(candidates: [Span])
        /// No candidate cleared the bar for its rung.
        ///
        /// - `near`: best-effort near-miss spans, surfaced for diagnostics
        ///   (a later near-miss diff). May be empty.
        case noMatch(near: [Span])
    }

    // MARK: Public constants

    /// Minimum similarity (inclusive) for a fuzzy candidate to be accepted as a
    /// unique match.
    ///
    /// Compared with a tolerance of ``fuzzyBoundaryEpsilon`` so a candidate
    /// sitting exactly on the threshold counts as meeting it. Mirrors the Rust
    /// crate's `FUZZY_ACCEPT_THRESHOLD`.
    public static let fuzzyAcceptThreshold: Float = 0.85

    /// Minimum similarity gap the best fuzzy candidate must hold over the
    /// runner-up to be accepted as the winner.
    ///
    /// A smaller gap yields ``MatchResult/ambiguous(candidates:)``. Mirrors the
    /// Rust crate's `FUZZY_RUNNER_UP_MARGIN`.
    public static let fuzzyRunnerUpMargin: Float = 0.10

    /// Tolerance for the floating-point threshold and margin comparisons.
    ///
    /// Similarities are derived from integer edit counts (`1 - edits / length`),
    /// so a value that is mathematically *equal* to a constant can land an ULP
    /// below it in `Float` — for example `0.95 - 0.85` evaluates to `0.099999964`,
    /// not exactly `0.10`. Comparing with this epsilon makes a candidate sitting
    /// exactly on the threshold or margin count as meeting it. Mirrors the Rust
    /// crate's `FUZZY_BOUNDARY_EPSILON`.
    public static let fuzzyBoundaryEpsilon: Float = 1e-4

    // MARK: Public entry points

    /// Run the literal-find recovery ladder, returning the first unique confident match.
    ///
    /// Climbs the ladder (``Rung/exact`` → ``Rung/normalized`` → ``Rung/anchor``
    /// → ``Rung/fuzzy``) and stops at the first rung that produces a definite
    /// verdict, so a higher rung is always preferred over a lower one. Pure:
    /// `(find, content)` in, ``MatchResult`` out, no IO.
    ///
    /// - Parameters:
    ///   - find: the drifted / re-indented / line-ending-normalized description
    ///     of the span to locate.
    ///   - content: the original content to locate `find` within; the returned
    ///     range indexes this string's UTF-8 bytes.
    /// - Returns: ``MatchResult/unique(range:rung:confidence:)`` for a single
    ///   confident match, ``MatchResult/ambiguous(candidates:)`` when candidates
    ///   tie with no confident winner, or ``MatchResult/noMatch(near:)`` (with
    ///   best-effort near-miss spans) when nothing clears the bar.
    public static func findMatch(find: String, in content: String) -> MatchResult {
        let contentBytes = Array(content.utf8)
        for rung in ladder {
            if let result = rung.locate(contentBytes, find, rung.rung) {
                return result
            }
        }
        // The fuzzy rung always yields a verdict, so the loop always returns; this
        // is an unreachable total-function fallback.
        return .noMatch(near: [])
    }

    /// The normalized similarity between two strings in `[0.0, 1.0]`.
    ///
    /// Computed as `1 - levenshtein(a, b) / max(scalars(a), scalars(b))` over
    /// Unicode scalar values: identical strings (including two empty strings)
    /// score `1.0`, and strings sharing no aligned content score `0.0`. The
    /// fuzzy rung and its boundary tests build on this scale. Mirrors the Rust
    /// crate's `similarity`.
    ///
    /// - Parameters:
    ///   - a: the first string to compare.
    ///   - b: the second string to compare.
    /// - Returns: the similarity in `[0.0, 1.0]`; `1.0` for two empty strings.
    public static func similarity(_ a: String, _ b: String) -> Float {
        let scalarsA = Array(a.unicodeScalars)
        let scalarsB = Array(b.unicodeScalars)
        let maxLength = max(scalarsA.count, scalarsB.count)
        if maxLength == 0 {
            return 1
        }
        let distance = Float(levenshtein(scalarsA, scalarsB))
        return 1 - distance / Float(maxLength)
    }

    // MARK: Ladder table

    /// One rung of the recovery ladder: a named strategy that either locates a
    /// verdict or defers (`nil`) to the next rung.
    private struct LadderRung: Sendable {
        /// The rung tag stamped onto matches this strategy produces.
        let rung: Rung
        /// Locate a verdict for `find` in the content bytes, or `nil` to descend.
        let locate: @Sendable (_ contentBytes: [UInt8], _ find: String, _ rung: Rung) -> MatchResult?
    }

    /// The recovery ladder as an ordered table, driven by the single cascade
    /// loop in ``findMatch(find:in:)``. The order is the contract: earlier rungs
    /// win, and the trailing ``Rung/fuzzy`` rung always returns a verdict.
    private static let ladder: [LadderRung] = [
        LadderRung(rung: .exact, locate: locateExact),
        LadderRung(rung: .normalized, locate: locateLineBlock),
        LadderRung(rung: .anchor, locate: locateAnchor),
        LadderRung(rung: .fuzzy, locate: locateFuzzy),
    ]

    // MARK: Rung 1 — exact

    /// Rung 1 — literal substring match; `nil` means "no exact occurrence, descend".
    ///
    /// A single-line `find` is a line description, so its literal occurrences
    /// must be line-aligned (bounded by start/end of content or a newline) to
    /// count as exact; a mid-line substring (for example the un-indented form of
    /// an indented line) is deliberately rejected so the normalized rung can
    /// recover the full original line. A multi-line `find` is treated as a
    /// verbatim block and matched as a raw substring.
    ///
    /// - Parameters:
    ///   - contentBytes: the original content's UTF-8 bytes.
    ///   - find: the description to locate.
    ///   - rung: the rung tag to stamp onto a match.
    /// - Returns: a verdict, or `nil` to descend to the next rung.
    private static func locateExact(contentBytes: [UInt8], find: String, rung: Rung) -> MatchResult? {
        if find.isEmpty {
            return nil
        }
        let findBytes = Array(find.utf8)
        let singleLine = !find.contains("\n")
        let offsets = byteOffsets(of: findBytes, in: contentBytes).filter { start in
            !singleLine || isLineAligned(contentBytes, start: start, length: findBytes.count)
        }
        let ranges = offsets.map { start in start..<(start + findBytes.count) }
        return finalizeBlockMatches(contentBytes, ranges, rung)
    }

    /// Whether the byte range `start..<start+length` sits on physical line boundaries.
    ///
    /// Line-aligned means preceded by the start of content or a newline, and
    /// followed by the end of content or a newline (a trailing carriage return
    /// before the newline, or at end of content, is tolerated).
    ///
    /// - Parameters:
    ///   - contentBytes: the original content's UTF-8 bytes.
    ///   - start: the byte offset of the range's start.
    ///   - length: the range's length in bytes.
    /// - Returns: `true` when both the left and right boundaries are line-aligned.
    private static func isLineAligned(_ contentBytes: [UInt8], start: Int, length: Int) -> Bool {
        let end = start + length
        let leftOK = start == 0 || contentBytes[start - 1] == newlineByte
        let rightOK =
            end == contentBytes.count
            || contentBytes[end] == newlineByte
            || (contentBytes[end] == carriageReturnByte && end + 1 < contentBytes.count
                && contentBytes[end + 1] == newlineByte)
            || (contentBytes[end] == carriageReturnByte && end + 1 == contentBytes.count)
        return leftOK && rightOK
    }

    /// All byte offsets where `needle` occurs in `haystack`, advancing past each
    /// full (non-overlapping) match.
    ///
    /// - Parameters:
    ///   - needle: the byte sequence to search for.
    ///   - haystack: the bytes to search within.
    /// - Returns: the ascending byte offsets of each non-overlapping occurrence;
    ///   empty when `needle` is empty or longer than `haystack`.
    private static func byteOffsets(of needle: [UInt8], in haystack: [UInt8]) -> [Int] {
        guard !needle.isEmpty, needle.count <= haystack.count else { return [] }
        var offsets: [Int] = []
        var index = 0
        let lastStart = haystack.count - needle.count
        while index <= lastStart {
            if matches(needle, in: haystack, at: index) {
                offsets.append(index)
                index += needle.count
            } else {
                index += 1
            }
        }
        return offsets
    }

    /// Whether `needle` occurs in `haystack` starting at byte offset `index`.
    private static func matches(_ needle: [UInt8], in haystack: [UInt8], at index: Int) -> Bool {
        for offset in 0..<needle.count where haystack[index + offset] != needle[offset] {
            return false
        }
        return true
    }

    // MARK: Rung 2 — normalized line block

    /// Rung 2 — whitespace-normalized, whole-line-block match; `nil` to descend.
    ///
    /// Normalizes both the content's physical lines and `find`'s lines, then
    /// locates runs of consecutive content lines whose normalized forms equal
    /// the normalized `find` lines. The returned span covers the **original**
    /// bytes from the start of the first matched line to the end of the last, so
    /// the caller rewrites the original indentation and line endings.
    ///
    /// - Parameters:
    ///   - contentBytes: the original content's UTF-8 bytes.
    ///   - find: the description to locate.
    ///   - rung: the rung tag to stamp onto a match.
    /// - Returns: a verdict, or `nil` to descend to the next rung.
    private static func locateLineBlock(contentBytes: [UInt8], find: String, rung: Rung) -> MatchResult? {
        let contentLines = physicalLines(in: contentBytes)
        let findNormalized = trimmingTrailingEmpty(lines(of: find).map(normalize))
        if findNormalized.isEmpty {
            return nil
        }
        let contentNormalized = contentLines.map { normalize(text(of: contentBytes, in: $0)) }
        guard findNormalized.count <= contentNormalized.count else { return nil }

        var matchedRanges: [Range<Int>] = []
        for windowStart in 0...(contentNormalized.count - findNormalized.count) {
            let window = contentNormalized[windowStart..<(windowStart + findNormalized.count)]
            if Array(window) == findNormalized {
                let first = contentLines[windowStart]
                let last = contentLines[windowStart + findNormalized.count - 1]
                matchedRanges.append(first.lowerBound..<last.upperBound)
            }
        }
        return finalizeBlockMatches(contentBytes, matchedRanges, rung)
    }

    /// Turn matched byte ranges into a verdict: one → unique, many → ambiguous,
    /// none → descend (`nil`).
    ///
    /// - Parameters:
    ///   - contentBytes: the original content's UTF-8 bytes.
    ///   - matchedRanges: the matched byte ranges.
    ///   - rung: the rung tag to stamp onto a unique match.
    /// - Returns: a verdict, or `nil` when there were no matches.
    private static func finalizeBlockMatches(
        _ contentBytes: [UInt8],
        _ matchedRanges: [Range<Int>],
        _ rung: Rung
    ) -> MatchResult? {
        switch matchedRanges.count {
        case 0:
            return nil
        case 1:
            return .unique(range: matchedRanges[0], rung: rung, confidence: confidentMatchScore)
        default:
            return .ambiguous(candidates: matchedRanges.map { span(of: contentBytes, range: $0) })
        }
    }

    // MARK: Rung 3 — anchor

    /// Rung 3 — first/last-line anchor match; `nil` to descend.
    ///
    /// Requires `find` to have at least two non-empty anchor lines. The first
    /// normalized line of `find` must occur on exactly one content line, the
    /// last on exactly one content line strictly after it; the span runs from the
    /// start of the first to the end of the last, covering any interior drift.
    ///
    /// - Parameters:
    ///   - contentBytes: the original content's UTF-8 bytes.
    ///   - find: the description to locate.
    ///   - rung: the rung tag to stamp onto a match.
    /// - Returns: a verdict, or `nil` to descend to the next rung.
    private static func locateAnchor(contentBytes: [UInt8], find: String, rung: Rung) -> MatchResult? {
        let findNormalized = trimmingTrailingEmpty(lines(of: find).map(normalize))
        guard findNormalized.count >= 2,
            let first = findNormalized.first, let last = findNormalized.last,
            !first.isEmpty, !last.isEmpty
        else { return nil }

        let contentLines = physicalLines(in: contentBytes)
        let contentNormalized = contentLines.map { normalize(text(of: contentBytes, in: $0)) }
        let firstHits = contentNormalized.indices.filter { contentNormalized[$0] == first }
        let lastHits = contentNormalized.indices.filter { contentNormalized[$0] == last }
        guard firstHits.count == 1, lastHits.count == 1 else { return nil }

        let startIndex = firstHits[0]
        let endIndex = lastHits[0]
        guard endIndex > startIndex else { return nil }
        let range = contentLines[startIndex].lowerBound..<contentLines[endIndex].upperBound
        return .unique(range: range, rung: rung, confidence: confidentMatchScore)
    }

    // MARK: Rung 4 — fuzzy

    /// Rung 4 — fuzzy, similarity-scored match over physical lines.
    ///
    /// Scores every content line against the normalized `find`, then applies the
    /// threshold and runner-up margin: the best candidate wins only if it clears
    /// ``fuzzyAcceptThreshold`` and beats the runner-up by at least
    /// ``fuzzyRunnerUpMargin``. Multiple above-threshold candidates within the
    /// margin are ambiguous; nothing above threshold is a no-match with the
    /// strongest near-misses retained. This rung always returns a verdict.
    ///
    /// - Parameters:
    ///   - contentBytes: the original content's UTF-8 bytes.
    ///   - find: the description to locate.
    ///   - rung: the rung tag to stamp onto a match.
    /// - Returns: a definite verdict (never `nil`).
    private static func locateFuzzy(contentBytes: [UInt8], find: String, rung: Rung) -> MatchResult? {
        let findNormalized = normalizeMultiline(find)
        let contentLines = physicalLines(in: contentBytes)

        var scored: [(score: Float, index: Int, range: Range<Int>)] = contentLines.enumerated()
            .map { index, range in
                (similarity(findNormalized, normalize(text(of: contentBytes, in: range))), index, range)
            }
        // Descending by score; ties keep source (line) order for a stable result.
        scored.sort { lhs, rhs in
            lhs.score != rhs.score ? lhs.score > rhs.score : lhs.index < rhs.index
        }

        let acceptFloor = fuzzyAcceptThreshold - fuzzyBoundaryEpsilon
        let above = scored.filter { $0.score >= acceptFloor }
        switch above.count {
        case 0:
            let near = scored.prefix(maxNearMisses)
                .filter { $0.score > 0 }
                .map { span(of: contentBytes, range: $0.range) }
            return .noMatch(near: near)
        case 1:
            return .unique(range: above[0].range, rung: rung, confidence: above[0].score)
        default:
            let best = above[0].score
            let runnerUp = above[1].score
            if best - runnerUp >= fuzzyRunnerUpMargin - fuzzyBoundaryEpsilon {
                return .unique(range: above[0].range, rung: rung, confidence: best)
            }
            return .ambiguous(candidates: above.map { span(of: contentBytes, range: $0.range) })
        }
    }

    // MARK: Line model and normalization

    /// Split the content bytes into the byte ranges of their physical lines.
    ///
    /// The newline is excluded; a trailing carriage return before the newline is
    /// also excluded. A trailing newline does not produce a phantom empty final
    /// line. This is the single line model the whole ladder is numbered against.
    ///
    /// - Parameter contentBytes: the original content's UTF-8 bytes.
    /// - Returns: the physical lines' byte ranges in order; empty for empty input.
    private static func physicalLines(in contentBytes: [UInt8]) -> [Range<Int>] {
        var lineRanges: [Range<Int>] = []
        var start = 0
        for index in contentBytes.indices where contentBytes[index] == newlineByte {
            let end =
                (index > start && contentBytes[index - 1] == carriageReturnByte) ? index - 1 : index
            lineRanges.append(start..<end)
            start = index + 1
        }
        if start < contentBytes.count {
            lineRanges.append(start..<contentBytes.count)
        }
        return lineRanges
    }

    /// Split a string into physical lines mirroring the Rust `str::lines()`.
    ///
    /// Splits on the newline and strips a trailing carriage return from each
    /// line; a trailing newline yields no phantom empty final line. Reuses
    /// ``physicalLines(in:)`` over the string's UTF-8 bytes so the content and
    /// `find` line models are identical.
    ///
    /// - Parameter string: the string to split.
    /// - Returns: the physical lines, terminators excluded; empty for an empty string.
    private static func lines(of string: String) -> [String] {
        let bytes = Array(string.utf8)
        return physicalLines(in: bytes).map { text(of: bytes, in: $0) }
    }

    /// Normalize a line for whitespace-insensitive comparison.
    ///
    /// Trims leading and trailing horizontal whitespace and carriage returns
    /// (space, tab, carriage return) per Unicode scalar, preserving interior
    /// content. Mirrors the Rust `trim_matches([' ', '\t', '\r'])`.
    ///
    /// - Parameter text: the line text to normalize.
    /// - Returns: the trimmed text.
    private static func normalize(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r"))
    }

    /// Normalize a possibly-multiline `find` into one comparison string.
    ///
    /// Trims each line and rejoins with a newline, so fuzzy scoring is
    /// insensitive to indentation and line-ending style. Mirrors the Rust
    /// `normalize_multiline`.
    ///
    /// - Parameter find: the description to normalize.
    /// - Returns: the trimmed lines joined by newlines.
    private static func normalizeMultiline(_ find: String) -> String {
        lines(of: find).map(normalize).joined(separator: "\n")
    }

    /// Strip trailing all-whitespace (normalized-empty) lines from an array.
    ///
    /// - Parameter lines: the normalized lines.
    /// - Returns: the prefix with trailing empty lines removed.
    private static func trimmingTrailingEmpty(_ lines: [String]) -> [String] {
        Array(lines.reversed().drop(while: { $0.isEmpty }).reversed())
    }

    // MARK: Span construction

    /// Build a ``Span`` from a byte range over the content bytes.
    ///
    /// - Parameters:
    ///   - contentBytes: the original content's UTF-8 bytes.
    ///   - range: the byte range the span covers.
    /// - Returns: the span with its 1-based start/end line numbers and covered text.
    private static func span(of contentBytes: [UInt8], range: Range<Int>) -> Span {
        let startLine = lineNumber(in: contentBytes, at: range.lowerBound)
        // The end is exclusive; the last covered byte is `range.upperBound - 1`.
        // An empty range falls back to the start line.
        let endLine =
            range.upperBound > range.lowerBound
            ? lineNumber(in: contentBytes, at: range.upperBound - 1) : startLine
        return Span(range: range, startLine: startLine, endLine: endLine, text: text(of: contentBytes, in: range))
    }

    /// The 1-based line number of the byte at `offset` (newlines before it, plus one).
    private static func lineNumber(in contentBytes: [UInt8], at offset: Int) -> Int {
        contentBytes[0..<offset].reduce(1) { count, byte in count + (byte == newlineByte ? 1 : 0) }
    }

    /// Decode the UTF-8 byte range `range` of the content bytes into a string.
    private static func text(of contentBytes: [UInt8], in range: Range<Int>) -> String {
        String(decoding: contentBytes[range], as: UTF8.self)
    }

    // MARK: Edit distance

    /// Classic two-row Levenshtein edit distance over Unicode scalar slices.
    ///
    /// - Parameters:
    ///   - a: the first scalar sequence.
    ///   - b: the second scalar sequence.
    /// - Returns: the minimum number of single-scalar insertions, deletions, or
    ///   substitutions to turn `a` into `b`.
    private static func levenshtein(_ a: [Unicode.Scalar], _ b: [Unicode.Scalar]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = Array(repeating: 0, count: b.count + 1)
        for (indexA, scalarA) in a.enumerated() {
            current[0] = indexA + 1
            for (indexB, scalarB) in b.enumerated() {
                let cost = scalarA == scalarB ? 0 : 1
                current[indexB + 1] = min(previous[indexB + 1] + 1, current[indexB] + 1, previous[indexB] + cost)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    // MARK: Private constants

    /// The confidence stamped onto a definite (non-fuzzy) match.
    private static let confidentMatchScore: Float = 1.0

    /// The number of fuzzy near-miss candidates retained in a no-match verdict.
    ///
    /// Keeping only the strongest few avoids returning every line. Mirrors the
    /// Rust crate's `MAX_NEAR_MISSES`.
    private static let maxNearMisses = 3

    /// The UTF-8 byte for a line feed (`\n`).
    private static let newlineByte: UInt8 = 0x0A

    /// The UTF-8 byte for a carriage return (`\r`).
    private static let carriageReturnByte: UInt8 = 0x0D
}
