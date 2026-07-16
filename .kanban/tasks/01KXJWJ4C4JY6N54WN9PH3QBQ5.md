---
comments:
- actor: claude-code
  id: 01kxm6r7ttcaj3wfnxp2ac9v6e
  text: 'Picked up by /finish. Deps done: Hashline (9gpx96t, anchor rung), EditMatch (ydsaz6b, ladder rung 3). EditEngine.swift — pure in-memory core, NO file I/O. normalize(args)→[Pair] (scalar find/replace, N+N zip parallel arrays, N finds+1 replace broadcast delete, edits[] array; count mismatch→corrective listing unpaired remainder; find==replace no-op→corrective). resolve(pair,in:working) cascade: hashline anchor (Hashline, ±50 drift, |text verify) → literal substring (first occ; replaceAll=global-literal; occurrence selects) → recovery ladder (EditMatch). Outcomes .anchor/.literal/.recovered/.ambiguous([Candidate] 1-based occ,line,text,±2 ctx)/.noMatch([NearMiss] line-diff from EditMatch near-miss). Competing anchor+literal→candidates never guessed. Batch: pairs apply sequentially vs working copy; reclassify bare no-match to .alreadyApplied/.consumedTarget via batch/idempotency ctx; any ambiguous/no-match short-circuits BEFORE mutation. REUSE Hashline (resolveAnchor/parseAnchor) + EditMatch (findMatch/near-miss) — no reimpl. Front-load conventions (public/DocC incl -Throws:/-Parameters:/-Returns/no-abbrev/named-constants incl ±50/±2/data-driven cascade/no-dup-literals/low-complexity/arg-labels) — grep/edit-match cost 3-5 review rounds on these. Starting implement→test→commit→review loop.'
  timestamp: 2026-07-16T00:55:44.218127+00:00
- actor: claude-code
  id: 01kxm7gtmjr39gmtan357847be
  text: 'Research done. Studied Hashline (parseAnchor/resolveAnchor/tag/splitLines/proximityWindow public), EditMatch (findMatch + Span/MatchResult/Rung public, near-miss data), CorrectiveEncodable, WriteFile for conventions. Design: pure EditEngine enum namespace. normalize(EditArguments)->Normalization(.pairs/.corrective) covering scalar/zip/broadcast(N+1)/edits[] + mismatch corrective listing unpaired remainder + no-op rejection. resolve(pair,in:)->Resolution cascade: (1) anchor rung reuses Hashline.resolveAnchor when find parses as anchor; (2) plain literal substring (first occ / occurrence-select / replaceAll-first / multi=ambiguous); (3) ladder reuses EditMatch.findMatch (.unique->.recovered, .ambiguous->candidates, .noMatch->NearMiss line diff). Competing = anchor resolves AND its |text payload matches literally on a DIFFERENT line -> .ambiguous (anchor occ1 + literal occ2..). apply(pairs,to:)->BatchOutcome drives sequential working copy, reclassifies bare noMatch to .consumedTarget (literal was in pre-batch original) / .alreadyApplied (replace present, target never in original), and short-circuits to .failed(index,pair,resolution) on any ambiguous/noMatch/alreadyApplied/consumedTarget leaving original untouched. Starting TDD: tests first.'
  timestamp: 2026-07-16T01:09:09.906151+00:00
- actor: claude-code
  id: 01kxm7t9w4869gm6fe0jp1e290
  text: 'Implementation landed. Created Sources/FileTool/EditEngine.swift (pure, no I/O) + Tests/FileToolTests/EditEngineTests.swift (22 tests, TDD red->green). `swift test --filter EditEngineTests`: 22/22 pass. Full `swift test`: 164 tests in 10 suites + integration scaffold all green. No EditEngine build warnings. Cascade reuses Hashline.resolveAnchor/parseAnchor (anchor rung) and EditMatch.findMatch + Span near-miss data (ladder rung); literal rung is plain substring search (engine''s own rung 2, not the ladder). Running adversarial double-check before handoff.'
  timestamp: 2026-07-16T01:14:20.420766+00:00
- actor: claude-code
  id: 01kxm85gpkrw22hjk3h0jm631v
  text: |-
    Adversarial double-check verdict: REVISE with 3 low-severity, non-blocking findings (no correctness/completeness/intent defect found; both test commands green). Actions taken:
    - Finding 1 (convention: bare `1` literal in competingCandidates occurrence math): FIXED — occurrence now derived from candidates.count + firstOccurrence, no hardcoded literal.
    - Finding 2 (substring reclassification heuristic could false-positive on a short/common replace): the "find absent + replace present" heuristic faithfully implements the task's stated idempotency contract, so kept as spec'd; added test genuineNearMissIsNotReclassifiedWhenReplaceIsAbsent pinning that a typo'd find with an absent replace stays .noMatch (not falsely alreadyApplied/consumedTarget).
    - Finding 3 (resolve never exercised with empty find): added test emptyFindResolvesToNoMatch pinning .noMatch([]).
    Final: `swift test --filter EditEngineTests` 24/24 green; full `swift test` 166 unit + 1 integration scaffold all green; no EditEngine warnings. Task complete and left in doing for /review.
  timestamp: 2026-07-16T01:20:27.859730+00:00
- actor: claude-code
  id: 01kxm86d1nkcp6y2r1mzxg8mgx
  text: 'Iteration 1: implement landed green. EditEngine.swift — pure, no I/O. normalize(_:)→Normalization (scalar / N+N zip / single-replace broadcast / edits[] → [Pair]; count mismatch→corrective listing unpaired remainder; empty finds + find==replace no-ops→corrective). resolve(_:in:)→Resolution cascade in order: (1) anchor (Hashline.parseAnchor+resolveAnchor, ±50 drift, |text verify) → (2) literal substring (engine''s own byte search; single/occurrence-selected/replaceAll-first) → (3) recovery ladder (EditMatch.findMatch). Outcomes .anchor/.literal/.recovered/.ambiguous([Candidate])/.noMatch([NearMiss] line-diff from EditMatch.Span). COMPETING anchor+literal→.ambiguous (anchor=occ 1, competing literals follow) — never guessed. apply(_:to:)→BatchOutcome: pairs sequential vs evolving working copy; bare .noMatch reclassified to .consumedTarget (literal in pre-batch original, consumed by earlier pair) or .alreadyApplied (never present, replacement already there); any ambiguous/noMatch/alreadyApplied/consumedTarget → .failed(index:pair:resolution:) BEFORE commit, original untouched, failing pair named. REUSE Hashline (parseAnchor/resolveAnchor/splitLines) + EditMatch (findMatch/Span near-miss) — no reimpl. EditEngineTests.swift 24 tests (cascade order; N+1 broadcast; mismatch corrective; competing anchor+literal; occurrence incl out-of-range; replaceAll global; already-applied + consumed-target batch reclassification; near-miss diff; no-op rejection). double-check REVISE→addressed (1 convention nit fixed + 2 tests pinning near-miss-preservation/empty-find). swift test --filter EditEngineTests 24/24; full 166 unit + 1 integration green, 0 warnings. Left in doing → /test → /commit → /review.'
  timestamp: 2026-07-16T01:20:56.885490+00:00
depends_on:
- 01KXJWGS1DPP92870X79GPX96T
- 01KXJWY1SFQWHQZDNH9YDSAZ6B
position_column: doing
position_ordinal: '80'
title: 'EditEngine core: normalization + resolution cascade (pure, no I/O)'
---
## What
Per plan.md §3 "EditEngine" — the pure in-memory core, no file I/O in this task. The recovery ladder itself lives in `EditMatch.swift` (separate task); this task consumes it as cascade rung 3. Create `Sources/FileTool/EditEngine.swift`:
- `normalize(args) → [Pair]`: scalar find/replace, parallel arrays (N+N zip; N finds + 1 replace broadcast delete), `edits[]` array; count mismatch → corrective listing the unpaired remainder; `find == replace` no-op → corrective
- `resolve(pair, in: working)` cascade: hashline anchor (via Hashline, ±50 drift, `|text` verify) → literal substring (first occurrence; `replaceAll` = global-literal path; `occurrence` selects among candidates) → recovery ladder (call into EditMatch)
- Outcomes: `.anchor(line)` / `.literal(range)` / `.recovered(range)` / `.ambiguous([Candidate])` (1-based occurrence, line, current text, ±2 lines context) / `.noMatch([NearMiss])` (line-level diff of find vs current, built from EditMatch near-miss data)
- Competing resolving-anchor + literal → candidates, never guessed
- Batch semantics: pairs apply sequentially against the working copy; reclassify bare no-match to `.alreadyApplied` / `.consumedTarget` using batch/idempotency context; any ambiguous/no-match short-circuits before mutation

## Acceptance Criteria
- [ ] Cascade order verified: a resolving anchor wins over literal; literal wins over ladder; competing anchor+literal yields candidates
- [ ] Ambiguous result lists ALL candidates with correct 1-based occurrence numbers and ±2-line context
- [ ] A short-circuited batch reports which pair failed and leaves the working copy unchanged

## Tests
- [ ] `Tests/FileToolTests/EditEngineTests.swift`: cascade-order fixtures; N+1 broadcast; mismatch corrective; competing anchor+literal; occurrence selection incl. out-of-range; replaceAll global; already-applied and consumed-target reclassification in batches; near-miss diff content; no-op rejection
- [ ] Run `swift test --filter EditEngineTests` — expect: green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.