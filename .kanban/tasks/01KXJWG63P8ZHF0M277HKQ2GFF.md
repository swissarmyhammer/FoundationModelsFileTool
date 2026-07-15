---
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