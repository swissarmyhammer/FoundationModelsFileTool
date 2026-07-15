---
comments:
- actor: claude-code
  id: 01kxk5m16xb9akvqy840feeegz
  text: |-
    PARKED / delegated per user (2026-07-15). This task's work lives in another repo (FoundationModelsCodeContext), so instead of making the upstream change from /finish, I filed it as a task on the CodeContext board:
      CodeContext board → task short_id 2hsy4gh (ULID 01KXK5KDHA557YS80A32HSY4GH), column todo, title "Make DiagnosticsReport contents public (records/counts/pending, DiagnosticRecord, Counts)".
    That task has the exact file (Sources/FoundationModelsCodeContext/Diagnostics/DiagnosticRecord.swift), current-visibility facts, change list, acceptance criteria, and a non-@testable visibility test spec.
    Leaving hkq2gff in todo on the FileTool board — it is effectively blocked on CodeContext 2hsy4gh (cross-board, so no depends_on link possible). /finish is skipping it this batch (no in-FileTool-repo work here). It blocks only downstream FileTool task 01KXJWKVHSPFD5TYG8B1CRX7KF, which will stay not-ready until the CodeContext change ships and this card is closed.
  timestamp: 2026-07-15T15:16:43.357851+00:00
position_column: todo
position_ordinal: '8180'
title: 'Upstream PR: make DiagnosticsReport contents public in FoundationModelsCodeContext'
---
## What
Per plan.md §4/§10 task 2 — the one external blocker. In `../FoundationModelsCodeContext` (`Sources/FoundationModelsCodeContext/Diagnostics/DiagnosticRecord.swift`):
- Make `DiagnosticsReport.records`, `.counts`, `.pending` public; make `DiagnosticRecord` and `Counts` (and their stored properties) public. Public init NOT required.
- Add a DocC note that the report is a sibling-consumable value (completes the package's stated "Tool-ready" intent).
- Commit on a branch in that repo and open a PR (or commit to main if that's the repo's convention — check its history).

## Acceptance Criteria
- [ ] A downstream (non-`@testable`) import can compile `report.records.map(\.message)`, `report.counts.errors`, `report.pending`
- [ ] Upstream `swift test` remains green

## Tests
- [ ] Add an upstream test (plain `import FoundationModelsCodeContext`, no `@testable`) that constructs/receives a `DiagnosticsReport` via the fake-connection seam and reads records/counts/pending — proves public visibility
- [ ] Run `swift test` in ../FoundationModelsCodeContext — expect: green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.