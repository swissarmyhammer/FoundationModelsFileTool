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
title: 'Upstream: expose CodeContext.rootDirectory publicly + bump pin to CodeContextManager revision'
---
## What
Rescoped 2026-07-15: the original ask (make `DiagnosticsReport` contents public) is ALREADY DONE upstream — `DiagnosticsReport.records/counts/pending`, `DiagnosticRecord`, and `Counts` are public in `FoundationModelsCodeContext` (see `Diagnostics/DiagnosticRecord.swift`, doc comment "A sibling-consumable value type"). Upstream also now has `CodeContextManager` (`Sources/FoundationModelsCodeContext/CodeContextManager.swift`) with `context(containing:openIfNeeded:)` per-file routing, which the DiagnosticsBridge task now builds on.

Remaining work, in the upstream repo `/Users/wballard/github/swissarmyhammer/FoundationModelsCodeContext`:
- Make `CodeContext.rootDirectory` public (it is `private let` today, `CodeContext.swift`; immutable on an actor, so expose as `public nonisolated`). Why the bridge needs it — the OUTPUT side, not the input: `DiagnosticsScope.file` already accepts absolute paths (`DiagnosticsScopeResolver.confinedRelativePath` handles the leading-`/` case itself), but every `DiagnosticRecord.path` in the returned report is relative to the RESOLVED context's workspace root. To rebase item paths to session-root-relative (the bridge task's mapping requirement), a sibling package must be able to read which root the resolved context is rooted at. Alternative if upstream prefers: a manager API returning `(root, context)` pairs — `rootDirectory` is the minimal change.
- Commit/push upstream (branch `main`), then in THIS package run `swift package update FoundationModelsCodeContext` so `Package.resolved` pins a revision containing both `CodeContextManager` and public `rootDirectory`.

## Acceptance Criteria
- [ ] `CodeContext.rootDirectory` is `public nonisolated` upstream; upstream test suite still green
- [ ] This package's `Package.resolved` pins a `FoundationModelsCodeContext` revision containing `CodeContextManager`, `context(containing:)`, public `DiagnosticsReport` members, and public `rootDirectory`
- [ ] A compile-visibility probe in this package proves sibling consumption: constructs `CodeContextManager`, reads `report.records/counts/pending` and `context.rootDirectory` with plain `import FoundationModelsCodeContext` (no `@testable`). `CodeContextManager.init` requires a `TextEmbedding`; `NullEmbedder` lands only in the later bridge task, so the probe defines its own trivial throwaway embedder in the test target.

## Tests
- [ ] Upstream: `swift test` in `FoundationModelsCodeContext` — green
- [ ] This package: `Tests/FileToolTests/UpstreamVisibilityTests.swift` — a compile-time probe (no LSP spawn) touching the public surface above, with a local throwaway `TextEmbedding` conformance; `swift test --filter UpstreamVisibilityTests` — green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.