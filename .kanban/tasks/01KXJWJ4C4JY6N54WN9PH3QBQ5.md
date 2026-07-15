---
depends_on:
- 01KXJWGS1DPP92870X79GPX96T
- 01KXJWY1SFQWHQZDNH9YDSAZ6B
position_column: todo
position_ordinal: '8680'
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