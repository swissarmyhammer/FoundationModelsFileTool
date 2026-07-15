---
depends_on:
- 01KXJWGS1DPP92870X79GPX96T
- 01KXJWH0ZGPEAKRDWN520P15XY
position_column: todo
position_ordinal: '8580'
title: AtomicWriter + write file operation
---
## What
Per plan.md §3 op table row 2. Create `Sources/FileTool/AtomicWriter.swift` and `Sources/FileTool/Operations/WriteFile.swift`:
- `AtomicWriter`: write to `{path}.tmp.{uuid}` in the **same directory** → `rename` onto target; single cleanup path removes temp on any failure (write or rename); creates parent directories; re-applies original permission bits when overwriting; owns encoding/line-ending detection+re-encode hooks (consumed fully by the edit task)
- `WriteFile` op: params `filePath` (req), `content` (req, ≤ 10 MiB → corrective over cap). Unconditional clobber (no freshness check — parity). Output `WriteResult: Encodable { path, bytesWritten, hash, taggedContent, diagnostics? }` with `diagnostics` left nil (bridge task wires it)

(Anchor-chaining into a subsequent edit is verified by the edit-file task, which owns that acceptance criterion.)

## Acceptance Criteria
- [ ] Interrupted/failed write leaves target untouched and no `.tmp.*` files behind (incl. rename-failure: target is a directory)
- [ ] Overwriting a 0755 file keeps it 0755
- [ ] `taggedContent` anchors and `hash` in the envelope match a subsequent `read file` of the same path

## Tests
- [ ] `Tests/FileToolTests/WriteFileTests.swift`: new/overwrite/parent creation; blank path corrective; content exactly over 10 MiB rejected, at cap accepted; readonly target corrective; cleanup on write-failure and rename-failure; no temp files remain (directory scan); unicode/empty content; envelope fields (bytesWritten, hash matches re-read token, taggedContent equals read-back tagging)
- [ ] Run `swift test --filter WriteFileTests` — expect: green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.