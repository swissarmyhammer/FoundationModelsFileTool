---
depends_on:
- 01KXJWHT8YA35WZ6GGKA76XPF4
- 01KXJWJ4C4JY6N54WN9PH3QBQ5
position_column: todo
position_ordinal: '8980'
title: 'edit file operation: batch commit with encoding/line-ending preservation'
---
## What
Per plan.md §3 op table row 3. Create `Sources/FileTool/Operations/EditFile.swift` wiring EditEngine to real files via AtomicWriter:
- Params: `filePath` (req), `find`/`replace` (scalar or parallel arrays), `replaceAll?`, `occurrence?`, `edits?` — resolver aliases declared in the fusion task
- Read with encoding detection (BOM sniff → detected encoding → UTF-8 fallback; undecodable → corrective) and line-ending detection (`lf`/`crlf`/`cr`/`mixed`), recorded not rewritten
- Resolve full batch in memory via EditEngine; any ambiguous/no-match → return the structured outcome, file byte-identical
- On success: single atomic commit via AtomicWriter — re-encode with detected encoding, preserve permission bits; mtime deliberately fresh (plan decision §6.12)
- Output `EditResult: Encodable { path, status, applied, outcomes, bytesWritten?, encoding?, lineEndings?, hash?, taggedContent?, diagnostics? }` — `diagnostics` nil until bridge task

## Acceptance Criteria
- [ ] CRLF file edited in one spot stays byte-identical elsewhere (line endings preserved); same for UTF-8-BOM file (BOM intact)
- [ ] 0755 script stays executable after edit
- [ ] Ambiguous/no-match/failed commit leaves the file byte-identical (checksum before == after)
- [ ] Write-envelope anchor from a prior `write file` resolves in an edit with no intervening read (closes the chaining acceptance from the write task)

## Tests
- [ ] `Tests/FileToolTests/EditFileTests.swift`: single/replaceAll/occurrence edits; multi-pair batch; CRLF and BOM round-trips (byte compare outside edited range); mixed line endings reported; executable bit; readonly file corrective + byte-identical; commit-failure cleanup (no temp files); EditResult field shapes for every status; write→edit anchor chaining
- [ ] Run `swift test --filter EditFileTests` — expect: green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.