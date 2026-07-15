---
depends_on:
- 01KXJWMBD3KHJRTDMAVE1V3F9R
position_column: todo
position_ordinal: 8d80
title: 'Integration suite A: isolated workspaces + real-LSP error detection paths'
---
## What
Per plan.md §10 task 10 (first half) — the package's proof. In `Tests/FileToolIntegrationTests/`:
- Helpers in `Support/IsolatedWorkspace.swift`: `withIsolatedWorkspace { root in … }` (fresh temp dir, auto-cleanup) and `withIsolatedSwiftPackage { pkg in … }` (scaffold a minimal COMPILING Swift package — generated `Package.swift` + `Sources/` with two files where B calls A — plus `git init` + initial commit). One shared warm `FileContext` (bridge + `CodeContextManager`) per suite, not per test (wall-clock budget); the session root here IS the package root, so the manager resolves every mutation to that one project — the multi-project routing paths are suite C's job (^thrnwzt).
- Gating: locally, skip with a clear message when `xcrun --find sourcekit-lsp` fails; **in CI (`CI` env var set), a missing sourcekit-lsp is a test FAILURE, not a skip** — the CI workflow additionally asserts `xcrun --find sourcekit-lsp` before running tests, so the LSP tier can never silently vanish from CI (plan §9.6).
- Error-detection matrix, each through full `AnyOperation` dispatch with a real CodeContextManager + real sourcekit-lsp:
  - [ ] edit introduces a syntax error (unbalanced brace) → `status: errors` with real message + line
  - [ ] edit introduces a type error (`let x: Int = "s"`) → detected
  - [ ] write a new file with an unresolved identifier → detected
  - [ ] warning-only edit (unused variable) → `status: warnings`, zero errors; severity floor honored
  - [ ] edit changes a function signature in file A → caller error in file B folded in (includeDependents)
- Additional paths: cold-start `pending` (bridge with injected tiny `hardTimeout`) → honest `pending` + note, mutation still committed; **pending-then-settled** (plan §9.2 pin): after a `pending` result, re-run diagnostics with default timeouts and poll until `settled` errors arrive on the real cold workspace; item cap on an error-storm file (many errors → capped items, true counts).

## Acceptance Criteria
- [ ] Every matrix row asserts on the actual compiler message content (not just status), proving real LSP data flows through
- [ ] Suite green on the macOS 27 CI runner, where missing sourcekit-lsp fails the job (no silent skip); local runs without sourcekit-lsp skip with a clear message

## Tests
- [ ] `Tests/FileToolIntegrationTests/ErrorDetectionTests.swift` — the matrix above IS the test list
- [ ] Run `swift test --filter ErrorDetectionTests` — expect: green (or explicit local skip without sourcekit-lsp; CI never skips)

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.