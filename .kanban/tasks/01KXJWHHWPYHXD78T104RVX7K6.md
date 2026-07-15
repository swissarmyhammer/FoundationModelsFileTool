---
depends_on:
- 01KXJWGS1DPP92870X79GPX96T
- 01KXJWH0ZGPEAKRDWN520P15XY
position_column: todo
position_ordinal: '8480'
title: read file operation
---
## What
Per plan.md §3 op table row 1. Create `Sources/FileTool/Operations/ReadFile.swift` — `@Generable @Operation` struct on `FileContext`:
- Params: `path` (req), `offset?` (1-based line, ≤ 1,000,000), `limit?` (> 0, ≤ 100,000), `format?` (`hashline` | `plain`, default `hashline`)
- Pipeline: PathGuard validate → read full file, UTF-8-or-reject (binary → corrective message, never decoded) → window (offset/limit over lines) → hashline tag with **absolute** start line
- Output `ReadResult: Encodable { hash, lines, note? }` — `hash` is the whole-file token over full on-disk bytes regardless of windowing; `note` reports the window ("showing lines 60–120 of 843")
- Bound violations (offset > 1M, limit 0 or > 100k, unknown format) → corrective messages naming valid values

## Acceptance Criteria
- [ ] `#hash` token identical whether reading whole file or any window
- [ ] Anchors carry absolute line numbers under offset (line 60 tags as `60:HH|`)
- [ ] Binary file rejected in both formats with a corrective message

## Tests
- [ ] `Tests/FileToolTests/ReadFileTests.swift`: offset/limit/both; each bound violation; anchors absolute under windowing; token = full-file under window; plain opt-out (no anchors, no per-line tags); binary rejection both formats; empty file; unicode content; missing path corrective
- [ ] Run `swift test --filter ReadFileTests` — expect: green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.