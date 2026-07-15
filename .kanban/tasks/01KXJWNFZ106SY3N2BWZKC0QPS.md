---
depends_on:
- 01KXJWN2G2Z6MV4N7RSD96HKPG
position_column: todo
position_ordinal: '8e80'
title: 'Integration suite B: edits-OK paths + cross-op flows in isolated directories'
---
## What
Per plan.md §10 task 10 (second half). Reuses suite A's `withIsolatedWorkspace` / `withIsolatedSwiftPackage` helpers, shared warm CodeContext, and the same gating rule (**local: skip cleanly without sourcekit-lsp; CI: missing sourcekit-lsp is a failure, never a skip**):
- **Edits-OK paths** (each commits and asserts `diagnostics.status == clean` where applicable):
  - [ ] clean write of a valid Swift file → `clean`
  - [ ] each cascade rung against a real file: anchor edit, literal edit, recovered (drifted) edit, `replaceAll`, `occurrence`-disambiguated, multi-pair batch
  - [ ] error-then-fix round trip: edit breaks the build → diagnostics show it → second edit repairs → `clean`
  - [ ] non-diagnosable file (`README.md`, `.json`) → `skipped`, CodeContext untouched
  - [ ] read-only tool (`FileTool.makeReadOnly`) never triggers the bridge
- **Cross-op flows**: write → read (anchors) → edit-by-anchor → diagnostics; glob → grep → edit; gitignore end-to-end (ignored file invisible to glob/grep but readable by explicit path); concurrency smoke (parallel reads during an edit; concurrent edits to distinct files)
- Byte-level assertions on encoding/line-ending/permission preservation in the real-workspace setting (CRLF fixture, BOM fixture, executable script)

## Acceptance Criteria
- [ ] Every listed path runs through full op dispatch in a fresh isolated directory and passes
- [ ] Suite green on the macOS 27 CI runner with the no-silent-skip gating; documented wall-clock budget for the combined integration tier (suite A + B) in the test file header

## Tests
- [ ] `Tests/FileToolIntegrationTests/EditsOKTests.swift` and `CrossOpFlowTests.swift` — the checklists above ARE the test lists
- [ ] Run `swift test --filter "EditsOKTests|CrossOpFlowTests"` — expect: green (or explicit local skip without sourcekit-lsp; CI never skips)

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.