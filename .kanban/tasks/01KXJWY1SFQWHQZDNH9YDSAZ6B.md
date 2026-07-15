---
depends_on:
- 01KXJWG0E2246T5Y42D8N71Z1G
position_column: todo
position_ordinal: '9180'
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