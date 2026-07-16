---
comments:
- actor: claude-code
  id: 01kxm3pj01g9j5xc9dkhs8mrnn
  text: 'Picked up by /finish. Dep done: scaffolding (8n71z1g). Table-driven port of ../swissarmyhammer/crates/swissarmyhammer-edit-match → Sources/FileTool/EditMatch.swift. Pure functions, no file I/O (EditEngine cascade rung 3 consumes it). findMatch(find:in:)->MatchResult locating drifted/re-indented/CRLF-normalized find while preserving original surrounding bytes/indentation in the returned range; rungs ported EXACTLY (mirror Rust rung order/semantics), each with its own parity fixture table generated from the Rust crate''s own test cases; non-matches return structured near-miss (closest candidate + similarity). Similar shape to the Hashline bit-exact port — generate fixtures from Rust, revert the Rust repo clean afterward. Front-load conventions (public/DocC incl -Throws:/-Parameters:/-Returns/no-abbrev/named-constants/data-driven rung table/no-dup-literals/low-complexity/arg-labels) — grep took 5 review rounds on exactly these quality dims. Starting implement→test→commit→review loop. NOTE: this is the LAST in-repo ready task; after it, only the parked upstream hkq2gff remains in scope.'
  timestamp: 2026-07-16T00:02:23.361428+00:00
- actor: claude-code
  id: 01kxm3y97fsrdzfy9g88v1ydkj
  text: 'Picked up, moved to doing. Read the Rust crate swissarmyhammer-edit-match (src/lib.rs + tests/rungs.rs, fuzzy_boundary.rs, edge_cases.rs, properties.rs) in full and the Swift conventions (Hashline.swift + HashlineTests.swift + hashline-golden.json). Rust repo confirmed git-clean at start. Ladder: Exact -> Normalized(line-block) -> Anchor(first/last unique line) -> Fuzzy(similarity, threshold 0.85, runner-up margin 0.10, epsilon 1e-4). Plan: generate edit-match-golden.json via a throwaway cargo example in the Rust crate (untracked, deleted after -> repo stays clean), then TDD the Swift port over UTF-8 byte offsets for exact byte-range parity.'
  timestamp: 2026-07-16T00:06:36.527878+00:00
- actor: claude-code
  id: 01kxm4ehj39m7qqd3my002wrtc
  text: |-
    Implementation landed and green (TDD: RED stub -> full port -> GREEN).

    Files:
    - Sources/FileTool/EditMatch.swift: table-driven recovery-ladder port. Ladder expressed as DATA (private `ladder: [LadderRung]`, ordered exact->normalized->anchor->fuzzy) driven by ONE cascade loop in findMatch(find:in:). Each rung is a distinct named strategy (locateExact/locateLineBlock/locateAnchor/locateFuzzy) stamped with its Rung from the table. Works over UTF-8 byte offsets (Range<Int>) for exact byte-range parity with Rust; similarity/levenshtein over Unicode scalars (Rust `char`). Public MatchResult { unique(range,rung,confidence) | ambiguous(candidates:[Span]) | noMatch(near:[Span]) }; Span carries range/startLine/endLine/text as the structured near-miss data. Full DocC on every public symbol; named constants for all thresholds/bytes (fuzzyAcceptThreshold 0.85, fuzzyRunnerUpMargin 0.10, fuzzyBoundaryEpsilon 1e-4, maxNearMisses 3, newlineByte/carriageReturnByte, confidentMatchScore).
    - Tests/FileToolTests/EditMatchTests.swift: per-rung parity tables (exact/normalized/crlf/anchor/fuzzy/ambiguous/noMatch/empty/combined groups), similarity golden values, byte-preservation assertions (indentation + CRLF retained in returned range), near-miss candidate-quality test, ambiguous-never-silent test.
    - Tests/FileToolTests/Fixtures/edit-match-golden.json: 26 cases + 11 similarity vectors, generated FROM the Rust crate via a throwaway cargo example (examples/editmatch_dump.rs), then deleted -> Rust repo confirmed byte-clean (git status --porcelain empty), examples/ dir removed, nothing committed there.

    Rung semantics mirrored exactly incl.: single-line exact must be line-aligned (mid-line substring rejected so Normalized recovers full original line); str::lines()==physical_lines semantics reused via one splitter; trim_trailing_empty; anchor requires 2 non-empty unique first/last with end>start; fuzzy stable descending sort (index tiebreaker), accept floor = threshold - epsilon, runner-up margin - epsilon, near = prefix(3).filter(>0).

    swift test --filter EditMatchTests: 15/15 pass. Full swift test: 142 tests / 9 suites pass + integration 1/1. Zero failures/warnings. Running adversarial double-check before handoff.
  timestamp: 2026-07-16T00:15:29.347805+00:00
- actor: claude-code
  id: 01kxm4qtn4b3dgw66fdqj1qne1
  text: |-
    Adversarial double-check: VERDICT PASS. The critic cross-checked EditMatch.swift line-by-line against the Rust src/lib.rs and all four Rust test files, hand-re-derived several non-trivial fixture entries (empty-find blank-line ambiguity with empty ranges 2..2/3..3, reindent block 7..34, crlf+reindent 11..46, trailing-cr-at-eof 6..10, repeated-block line numbers) and confirmed they match, and verified: rung order + data-driven ladder, scalar-vs-byte boundary, float op order + epsilon at the ULP boundary cases, the explicit index tiebreaker compensating for Swift's non-stable sort, take(3)-then-filter(>0) near-miss ordering, str::lines()==physicalLines equivalence, is_line_aligned edge cases, byteOffsets guard, and all empty/inverted/non-unique anchor guards. Conventions (public, complete DocC, no abbreviations, named constants, single-loop data-driven ladder) all satisfied. No findings.

    really-done gate satisfied: swift test --filter EditMatchTests 15/15, full swift test 142 tests/9 suites + integration 1/1, exit 0, zero warnings. Rust repo byte-clean (git status --porcelain empty; examples/ removed). Leaving task in doing for /review.
  timestamp: 2026-07-16T00:20:33.572061+00:00
- actor: claude-code
  id: 01kxm4rtzf9pfzwsm3nbp12xvy
  text: 'Iteration 1: implement landed green. EditMatch.swift — findMatch(find:in:)->MatchResult + similarity(_:_:). Four-rung ladder as DATA: ordered private ladder:[LadderRung] (exact→normalized→anchor→fuzzy) driven by ONE cascade loop, each rung a named strategy stamped with its Rung. UTF-8 byte-offset ranges (Range<Int>) for exact byte-range parity w/ Rust; similarity/levenshtein over Unicode scalars (Rust char). MatchResult = unique(range,rung,confidence)|ambiguous(candidates:[Span])|noMatch(near:[Span]); Span(range/startLine/endLine/text) = structured near-miss. Pure, no I/O. Mirrored Rust src/lib.rs + all 4 test files: single-line exact line-aligned; str::lines()≡physicalLines one splitter; trim_trailing_empty; anchor needs 2 unique non-empty first/last w/ end>start; fuzzy stable descending sort w/ explicit index tiebreaker (Swift sort not stable); accept floor = threshold−epsilon; near = prefix(3).filter(>0). Fixtures generated FROM Rust via throwaway examples/editmatch_dump.rs (cargo run --example), example deleted, Rust repo confirmed byte-clean (git status --porcelain empty). EditMatchTests.swift 15 tests (per-rung parity exact/normalized/crlf/anchor/fuzzy/ambiguous/noMatch/empty/combined; similarity golden; byte-preservation incl indentation+CRLF; near-miss quality; ambiguous-never-silent) + Fixtures/edit-match-golden.json (26 cases + 11 similarity vectors). double-check PASS (line-by-line Rust cross-check). swift test --filter EditMatchTests 15/15; full 142 unit + 1 integration green, 0 warnings. Left in doing → /test → /commit → /review.'
  timestamp: 2026-07-16T00:21:06.671732+00:00
depends_on:
- 01KXJWG0E2246T5Y42D8N71Z1G
position_column: doing
position_ordinal: '80'
title: Recovery ladder port (swissarmyhammer-edit-match)
---
## What
Split out of EditEngine per plan risk §9.4 (the ladder is subtle — port rungs with parity fixtures, don't reinvent heuristics). Create `Sources/FileTool/EditMatch.swift`, a table-driven port of `../swissarmyhammer/crates/swissarmyhammer-edit-match`:
- `findMatch(find:in:) -> MatchResult` locating a `find` string that has drifted, been re-indented, or had line endings normalized, while preserving the original surrounding bytes/indentation in the returned range
- Rungs ported exactly as in the Rust crate (read its source and mirror the rung order/semantics); each rung gets its own fixture table
- Pure functions, no file I/O; consumed by EditEngine's cascade rung 3

## Acceptance Criteria
- [ ] Every rung reproduces the Rust crate's result on its parity fixtures (drift, re-indent, CRLF-normalized find, combined)
- [ ] A match through the ladder preserves original file bytes outside the matched range (indentation/line-ending untouched)
- [ ] Non-matches return structured near-miss data (closest candidate + similarity) for EditEngine's near-miss diff

## Tests
- [ ] `Tests/FileToolTests/EditMatchTests.swift`: table-driven parity fixtures per rung (generated from / checked against the Rust crate's own test cases); byte-preservation assertions; near-miss candidate quality
- [ ] Run `swift test --filter EditMatchTests` — expect: green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.