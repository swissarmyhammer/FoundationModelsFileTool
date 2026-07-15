---
depends_on:
- 01KXJWG63P8ZHF0M277HKQ2GFF
- 01KXJWHT8YA35WZ6GGKA76XPF4
- 01KXJWKBK3F6QH05RQS0EFWS09
position_column: todo
position_ordinal: 8a80
title: 'DiagnosticsBridge: CodeContext lifecycle + FileDiagnostics in write/edit results'
---
## What
Per plan.md §4 — the live edit error detection layer. Create `Sources/FileTool/DiagnosticsBridge.swift` and `Sources/FileTool/NullEmbedder.swift`:
- `NullEmbedder: TextEmbedding` (dimension 1, zero vectors) so CodeContext starts without a real embedding model
- **Start policy (decided): lazy by default** — CodeContext starts on the first mutation of a diagnosable file; an opt-in `eagerWarmup: Bool` on `FileContext` starts it at context creation (plan risk §9.2 mitigation). `.disabled` mode never starts it.
- **Configurable settle parameters (test seam):** `settleWindow` and `hardTimeout` are injectable on the bridge (defaults 300 ms / 5 s per CodeContext); integration suite A uses a tiny `hardTimeout` to force the `pending` path.
- **Diagnostics seam (decided): protocol shim** — define `protocol DiagnosticsProviding` in FileTool (one method mirroring `diagnostics(scope:severity:includeDependents:settleWindow:hardTimeout:)`); production conformance wraps the real `CodeContext`; unit tests use a fake conformance. No dependency on CodeContext's internal test facilities.
- Diagnosable-extension gate: only extensions mapping to LSP-backed CodeContext language modules trigger a pass; others → `skipped`
- After committed write/edit: diagnostics for `.file(path)`, `severity: .warning`, `includeDependents: true`
- Map the report → `FileDiagnostics: Encodable { status (clean|errors|warnings|pending|skipped), errors, warnings, items [{file, line, column, severity, message, code?}] (capped, cap constant documented), note? }`
- Wire into `WriteResult.diagnostics` / `EditResult.diagnostics`; never a gate — mutation success is already committed; bridge failures degrade to `pending` with a note, never fail the op

## Acceptance Criteria
- [ ] With default (lazy) policy, a non-diagnosable file (`.md`, `.json`) produces `skipped` without CodeContext ever starting; with `eagerWarmup: true`, CodeContext is started at context creation
- [ ] Report with errors maps to `status: errors` with real line/column/message items; warnings-only maps to `warnings`; empty maps to `clean`
- [ ] `pending` report and bridge exceptions both surface as `pending` + note, with the mutation still committed
- [ ] Injected `settleWindow`/`hardTimeout` are honored (observable via the fake)

## Tests
- [ ] `Tests/FileToolTests/DiagnosticsBridgeTests.swift`: mapping table (clean/errors/warnings/pending) against a fake `DiagnosticsProviding`; severity floor; item cap; skipped gate per extension; lazy vs eager start behavior; disabled mode; bridge-error degradation; injected settle params
- [ ] Run `swift test --filter DiagnosticsBridgeTests` — expect: green (real-LSP behavior is covered by the integration-suite tasks)

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.