---
depends_on:
- 01KXJWG63P8ZHF0M277HKQ2GFF
- 01KXJWHT8YA35WZ6GGKA76XPF4
- 01KXJWKBK3F6QH05RQS0EFWS09
position_column: todo
position_ordinal: 8a80
title: 'DiagnosticsBridge: CodeContextManager per-file routing + FileDiagnostics in write/edit results'
---
## What
Rescoped 2026-07-15 (supersedes plan.md §4's single-`CodeContext` design — update §4 as part of this task): the live edit error detection layer, now multi-project. `FileContext.root` may sit ABOVE several git projects; the bridge therefore wraps one `CodeContextManager` (not one `CodeContext`) and resolves the covering context per mutated file. `PathGuard`/read/glob/grep are untouched.

Create `Sources/FileTool/DiagnosticsBridge.swift` and `Sources/FileTool/NullEmbedder.swift`, and replace the stubs in `FileContext.swift` / `FileDiagnostics.swift`:
- `NullEmbedder: TextEmbedding` (dimension 1, zero vectors) so contexts start without a real embedding model
- **Bridge owns one lazily-created `CodeContextManager<ProcessLanguageServerConnection>`** — created on the first mutation of a diagnosable file; `.disabled` mode never creates it. Individual `CodeContext`s open lazily per project via the manager. Expose an `internal` accessor for the manager's currently-open roots (via `@testable import`) so integration suite C can assert which contexts were (and were NOT) opened.
- **Per-file resolution after a committed write/edit of a diagnosable file** (absolute path P, already PathGuard-validated):
  1. `manager.context(containing: P, openIfNeeded: true)` — longest-prefix match on open roots, else git-root discovery + open/start
  2. `nil` (file not inside any git repo, e.g. a stray file directly under a multi-project session root) → `FileDiagnostics(status: "skipped", note: "not inside a git workspace — no diagnostics pass")`
  3. non-nil → `context.diagnostics(scope: .file(P.path), severity: .warning, includeDependents: true, settleWindow:, hardTimeout:, perReportCap:)`. The scope INPUT takes the absolute path as-is — upstream's `DiagnosticsScopeResolver.confinedRelativePath` handles absolute paths itself. It is the OUTPUT that needs rebasing (next bullet).
- **Counts must be true even when items are capped**: upstream truncates `records` to `perReportCap` BEFORE deriving `counts`, so the bridge passes an explicit large `perReportCap` (10_000; constant documented, residual upstream limit noted) and applies its own smaller documented item cap only when mapping to `FileDiagnostics.items` — `errors`/`warnings` are counted from the full pre-item-cap records.
- **Glob-metacharacter gate**: upstream treats a `.file` scope containing `*`, `?`, or `[` as a glob, which can silently resolve to zero targets (falsely `clean`). A mutated filename containing any of these → `skipped` + note, before resolution.
- **Error degradation, never a gate**: mutation success is already committed. Manager/open errors (`CodeContextError.overlappingRoot`, `start()` failure) and diagnostics errors all degrade to `status: "pending"` + note; the op never fails because of the bridge.
- **Nested-repo semantics (documented behavior, not accident)**: nearest-open-ancestor wins — once an outer repo's context is open, files in a nested repo/submodule route to the outer context via longest-prefix match; conversely, if an inner repo opened first, a later outer-root open throws `overlappingRoot` and degrades to `pending`. Record both in plan.md §4 and in the DocC comment on the bridge.
- **Start policy**: lazy by default. Add `eagerWarmup: Bool = false` to `FileContext.init` — the one case where the manager is created before any mutation: at context creation, best-effort `manager.context(containing: root, openIfNeeded: true)`, ignoring `nil`/errors. Warms the enclosing project when the session root is itself inside a git repo; a true multi-project parent root warms nothing (projects warm on first mutation).
- **Configurable settle parameters (test seam)**: `settleWindow`/`hardTimeout` injectable on the bridge (defaults 300 ms / 5 s)
- **Diagnostics seam (resolver-shaped protocol shim)**: `protocol DiagnosticsResolving: Sendable` with one method mirroring resolve-then-diagnose — `func diagnostics(forFileAt: URL, severity:, includeDependents:, settleWindow:, hardTimeout:, perReportCap:) async throws -> DiagnosticsReport?` where `nil` means "no covering workspace". Production conformance wraps the manager (resolution + per-context call + root tracking for output rebase); unit tests use a fake keyed by path prefix. No dependency on CodeContext internals.
- Diagnosable-extension gate BEFORE resolution: non-LSP extensions (`.md`, `.json`, `.yaml`, …) → `skipped` without the manager ever being created
- Map report → `FileDiagnostics: Encodable { status (clean|errors|warnings|pending|skipped), errors, warnings, items [{file, line, column, severity, message, code?}] (capped, cap constant documented), note? }`. `DiagnosticRecord.path` is workspace-root-relative to the RESOLVED context's root — rebase every item path to SESSION-root-relative (join with `context.rootDirectory`, public per upstream task ^hkq2gff, then relativize against `FileContext.root`) so the model can feed them straight back into `edit file`.
- `stop()`/deinit path → `manager.shutdown()` (closes every open context)
- Wire into `WriteResult.diagnostics` / `EditResult.diagnostics`

## Acceptance Criteria
- [ ] With default (lazy) policy, a non-diagnosable file produces `skipped` with no manager created; `eagerWarmup: true` creates the manager and triggers one best-effort `context(containing: root)` at creation
- [ ] Fake resolver: files under two different fake roots produce reports from their respective providers (per-file routing observable); a path under no fake root maps to `skipped` + not-in-workspace note; a filename containing `*`/`?`/`[` maps to `skipped` + glob note
- [ ] Report with errors → `status: errors` with line/column/message items rebased to session-root-relative paths; warnings-only → `warnings`; empty → `clean`; a fake report with more records than the item cap yields capped `items` but full `errors`/`warnings` counts
- [ ] `pending` report, resolver exceptions, and overlapping-root errors all surface as `pending` + note (or `skipped` for nil), with the mutation still committed
- [ ] Injected `settleWindow`/`hardTimeout`/`perReportCap` are honored (observable via the fake)

## Tests
- [ ] `Tests/FileToolTests/DiagnosticsBridgeTests.swift`: mapping table (clean/errors/warnings/pending/skipped) against a fake `DiagnosticsResolving`; per-file routing across two fake roots; nil-resolution → skipped; glob-metachar filename → skipped; severity floor; item cap with true counts; path rebase to session root; diagnosable-extension gate; lazy vs eager start; disabled mode; error degradation; injected settle params
- [ ] Run `swift test --filter DiagnosticsBridgeTests` — expect: green (real-LSP and real-manager behavior covered by the integration-suite tasks)

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.