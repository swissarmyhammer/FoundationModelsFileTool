import Foundation
import Testing

@testable import FileTool

/// Behavioral tests for the ``EditEngine`` pure normalization + resolution core.
///
/// The engine is IO-free: it turns `edit file` argument shapes into `find` /
/// `replace` pairs, resolves each pair against an in-memory working copy through
/// the anchor → literal → recovery-ladder cascade, and drives a batch of pairs
/// against an evolving working copy with idempotency reclassification and
/// before-mutation short-circuit. These tests exercise each cascade rung, the
/// competing-anchor/literal candidate path, occurrence selection, `replaceAll`,
/// the near-miss line diff, and the batch semantics.
@Suite struct EditEngineTests {
    // MARK: Helpers

    /// The hashline anchor string (`N:HH|text`) for the 1-based `line` of `content`.
    ///
    /// Built by tagging `content` with ``Hashline/tag(lines:startingAtLine:)`` so
    /// the anchor's hash is guaranteed valid and resolvable.
    ///
    /// - Parameters:
    ///   - line: the 1-based line whose anchor to extract.
    ///   - content: the content to tag.
    /// - Returns: the tagged anchor string for that line.
    private func anchor(forLine line: Int, in content: String) -> String {
        let tagged = Hashline.splitLines(Hashline.tag(lines: content, startingAtLine: 1)).map(\.text)
        return tagged[line - 1]
    }

    // MARK: normalize — shapes

    @Test func scalarPairNormalizes() {
        let result = EditEngine.normalize(.init(finds: ["a"], replaces: ["b"]))
        #expect(result == .pairs([EditEngine.Pair(find: "a", replace: "b")]))
    }

    @Test func parallelArraysZipPairwise() {
        let result = EditEngine.normalize(.init(finds: ["a", "b"], replaces: ["X", "Y"]))
        #expect(
            result == .pairs([
                EditEngine.Pair(find: "a", replace: "X"),
                EditEngine.Pair(find: "b", replace: "Y"),
            ])
        )
    }

    @Test func singleReplaceBroadcastsAcrossFinds() {
        let result = EditEngine.normalize(.init(finds: ["a", "b", "c"], replaces: ["X"]))
        #expect(
            result == .pairs([
                EditEngine.Pair(find: "a", replace: "X"),
                EditEngine.Pair(find: "b", replace: "X"),
                EditEngine.Pair(find: "c", replace: "X"),
            ])
        )
    }

    @Test func countMismatchIsCorrectiveListingRemainder() {
        let result = EditEngine.normalize(.init(finds: ["a", "b", "c"], replaces: ["X", "Y"]))
        guard case .corrective(let message) = result else {
            Issue.record("expected corrective, got \(result)")
            return
        }
        #expect(message.contains("\"c\""))
    }

    @Test func editsArrayNormalizesWithPerEditReplaceAll() {
        let result = EditEngine.normalize(
            .init(edits: [
                EditEngine.EditSpec(find: "a", replace: "b"),
                EditEngine.EditSpec(find: "c", replace: "d", replaceAll: true),
            ])
        )
        #expect(
            result == .pairs([
                EditEngine.Pair(find: "a", replace: "b", replaceAll: false),
                EditEngine.Pair(find: "c", replace: "d", replaceAll: true),
            ])
        )
    }

    @Test func identicalFindAndReplaceIsRejectedAsNoOp() {
        let result = EditEngine.normalize(.init(finds: ["same"], replaces: ["same"]))
        guard case .corrective = result else {
            Issue.record("expected corrective no-op, got \(result)")
            return
        }
    }

    @Test func emptyFindsAreCorrective() {
        let result = EditEngine.normalize(.init())
        guard case .corrective = result else {
            Issue.record("expected corrective, got \(result)")
            return
        }
    }

    // MARK: resolve — cascade order

    @Test func resolvingAnchorWinsOverLiteral() {
        let content = "alpha\nbeta\ngamma\n"
        let pair = EditEngine.Pair(find: anchor(forLine: 2, in: content), replace: "BETA")
        #expect(EditEngine.resolve(pair, in: content) == .anchor(line: 2))
    }

    @Test func literalWinsOverLadder() {
        let content = "foo bar\nfoo baz\n"
        let pair = EditEngine.Pair(find: "foo bar", replace: "X")
        guard case .literal(let range) = EditEngine.resolve(pair, in: content) else {
            Issue.record("expected literal")
            return
        }
        #expect(range == 0..<7)
    }

    @Test func ladderRecoversLineEndingDrift() {
        let content = "line one\r\nline two\r\nline three\r\n"
        let pair = EditEngine.Pair(find: "line one\nline two", replace: "X")
        guard case .recovered(let range) = EditEngine.resolve(pair, in: content) else {
            Issue.record("expected recovered")
            return
        }
        #expect(range == 0..<18)
    }

    // MARK: resolve — competing anchor + literal

    @Test func competingAnchorAndLiteralYieldCandidates() {
        let content = "alpha\nbeta\ngamma\nbeta\n"
        let pair = EditEngine.Pair(find: anchor(forLine: 2, in: content), replace: "X")
        guard case .ambiguous(let candidates) = EditEngine.resolve(pair, in: content) else {
            Issue.record("expected ambiguous")
            return
        }
        #expect(candidates.count == 2)
        #expect(candidates[0].occurrence == 1)
        #expect(candidates[0].line == 2)
        #expect(candidates[1].occurrence == 2)
        #expect(candidates[1].line == 4)
    }

    // MARK: resolve — occurrence selection

    @Test func occurrenceSelectsAmongLiteralCandidates() {
        let content = "x\nx\nx\n"
        let pair = EditEngine.Pair(find: "x", replace: "y", occurrence: 2)
        #expect(EditEngine.resolve(pair, in: content) == .literal(range: 2..<3))
    }

    @Test func outOfRangeOccurrenceListsAllCandidates() {
        let content = "x\nx\nx\n"
        let pair = EditEngine.Pair(find: "x", replace: "y", occurrence: 5)
        guard case .ambiguous(let candidates) = EditEngine.resolve(pair, in: content) else {
            Issue.record("expected ambiguous")
            return
        }
        #expect(candidates.map(\.occurrence) == [1, 2, 3])
        #expect(candidates.map(\.line) == [1, 2, 3])
    }

    @Test func multipleLiteralOccurrencesWithoutSelectorAreAmbiguous() {
        let content = "x\nx\n"
        let pair = EditEngine.Pair(find: "x", replace: "y")
        guard case .ambiguous(let candidates) = EditEngine.resolve(pair, in: content) else {
            Issue.record("expected ambiguous")
            return
        }
        #expect(candidates.count == 2)
    }

    @Test func ambiguousCandidatesCarryContextWindow() {
        let content = "a\nb\nTARGET\nd\ne\nf\ng\nTARGET\ni\n"
        let pair = EditEngine.Pair(find: "TARGET", replace: "Z")
        guard case .ambiguous(let candidates) = EditEngine.resolve(pair, in: content) else {
            Issue.record("expected ambiguous")
            return
        }
        #expect(candidates.count == 2)
        #expect(candidates[0].line == 3)
        #expect(candidates[0].text == "TARGET")
        #expect(
            candidates[0].context == [
                EditEngine.ContextLine(line: 1, text: "a"),
                EditEngine.ContextLine(line: 2, text: "b"),
                EditEngine.ContextLine(line: 4, text: "d"),
                EditEngine.ContextLine(line: 5, text: "e"),
            ]
        )
        #expect(candidates[1].line == 8)
        #expect(
            candidates[1].context == [
                EditEngine.ContextLine(line: 6, text: "f"),
                EditEngine.ContextLine(line: 7, text: "g"),
                EditEngine.ContextLine(line: 9, text: "i"),
            ]
        )
    }

    // MARK: resolve — replaceAll global literal

    @Test func replaceAllResolvesToFirstOccurrence() {
        let content = "x\nx\nx\n"
        let pair = EditEngine.Pair(find: "x", replace: "y", replaceAll: true)
        #expect(EditEngine.resolve(pair, in: content) == .literal(range: 0..<1))
    }

    @Test func replaceAllRewritesEveryOccurrence() {
        let pair = EditEngine.Pair(find: "x", replace: "y", replaceAll: true)
        guard case .applied(let content, _) = EditEngine.apply([pair], to: "x\nx\nx\n") else {
            Issue.record("expected applied")
            return
        }
        #expect(content == "y\ny\ny\n")
    }

    // MARK: resolve — near-miss diff

    @Test func noMatchCarriesLineDiff() {
        let content = "the quick brown fox\n"
        let pair = EditEngine.Pair(find: "the quick red fox", replace: "X")
        guard case .noMatch(let nearMisses) = EditEngine.resolve(pair, in: content) else {
            Issue.record("expected noMatch")
            return
        }
        #expect(nearMisses.count == 1)
        #expect(nearMisses[0].startLine == 1)
        #expect(
            nearMisses[0].lines == [
                EditEngine.DiffLine(change: .expected, text: "the quick red fox"),
                EditEngine.DiffLine(change: .actual, text: "the quick brown fox"),
            ]
        )
    }

    @Test func emptyFindResolvesToNoMatch() {
        let pair = EditEngine.Pair(find: "", replace: "x")
        #expect(EditEngine.resolve(pair, in: "abc\n") == .noMatch([]))
    }

    // MARK: apply — batch semantics

    @Test func batchAppliesPairsSequentially() {
        let pairs = [
            EditEngine.Pair(find: "foo", replace: "FOO"),
            EditEngine.Pair(find: "bar", replace: "BAR"),
        ]
        guard case .applied(let content, let edits) = EditEngine.apply(pairs, to: "foo\nbar\n") else {
            Issue.record("expected applied")
            return
        }
        #expect(content == "FOO\nBAR\n")
        #expect(edits.count == 2)
    }

    @Test func alreadyAppliedReclassifiesBareNoMatch() {
        let pair = EditEngine.Pair(find: "hello", replace: "world")
        guard case .failed(let index, _, let resolution) = EditEngine.apply([pair], to: "world\n") else {
            Issue.record("expected failed")
            return
        }
        #expect(index == 0)
        #expect(resolution == .alreadyApplied)
    }

    @Test func consumedTargetReclassifiesBareNoMatchInBatch() {
        let pairs = [
            EditEngine.Pair(find: "foo", replace: "XXX"),
            EditEngine.Pair(find: "foo", replace: "YYY"),
        ]
        guard case .failed(let index, _, let resolution) = EditEngine.apply(pairs, to: "foo\nbar\n") else {
            Issue.record("expected failed")
            return
        }
        #expect(index == 1)
        #expect(resolution == .consumedTarget)
    }

    @Test func genuineNearMissIsNotReclassifiedWhenReplaceIsAbsent() {
        // A typo'd `find` that is absent and whose `replace` is also absent must
        // stay a near-miss, not be mislabelled already-applied/consumed-target.
        let pair = EditEngine.Pair(find: "helo", replace: "WORLD")
        guard case .failed(_, _, let resolution) = EditEngine.apply([pair], to: "hello\n") else {
            Issue.record("expected failed")
            return
        }
        guard case .noMatch = resolution else {
            Issue.record("expected noMatch, got \(resolution)")
            return
        }
    }

    @Test func ambiguousPairShortCircuitsBatchLeavingContentUnchanged() {
        let pairs = [
            EditEngine.Pair(find: "foo", replace: "ZZZ"),
            EditEngine.Pair(find: "x", replace: "Y"),
        ]
        let outcome = EditEngine.apply(pairs, to: "foo\nx\nx\n")
        guard case .failed(let index, _, let resolution) = outcome else {
            Issue.record("expected failed, got \(outcome)")
            return
        }
        #expect(index == 1)
        guard case .ambiguous = resolution else {
            Issue.record("expected ambiguous resolution")
            return
        }
    }
}
