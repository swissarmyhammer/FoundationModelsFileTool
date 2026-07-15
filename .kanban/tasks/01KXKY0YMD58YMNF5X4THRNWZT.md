---
assignees:
- claude-code
depends_on:
- 01KXJWKVHSPFD5TYG8B1CRX7KF
- 01KXJWN2G2Z6MV4N7RSD96HKPG
position_column: todo
position_ordinal: '9280'
title: 'Integration suite C: multi-project session root — per-project diagnostics routing with real LSP'
---
## What
Prove the CodeContextManager-based bridge spans projects: a session root ABOVE git repos still yields correct, project-scoped diagnostics. In `Tests/FileToolIntegrationTests/MultiProjectTests.swift`, reusing suite A's `Support/IsolatedWorkspace.swift` helpers:
- Scaffold helper `withMultiProjectRoot { root, pkgA, pkgB in … }`: one fresh temp dir as session root containing TWO independent scaffolded compiling Swift packages (each its own `git init` + commit, via `withIsolatedSwiftPackage`'s scaffolding), plus one stray `Loose.swift` and one `notes.md` directly under the session root (outside any repo)
- `FileContext(root: sessionRoot)` — one context, one bridge, PathGuard bounded at the parent — all ops dispatched through full `AnyOperation` dispatch with a real `CodeContextManager` + real sourcekit-lsp
- Which-contexts-opened assertions use the bridge's `@testable`-reachable open-roots accessor (defined in the bridge task ^1crx7kf) — reported paths alone can prove a context WAS used but not that another was NOT opened
- Same sourcekit-lsp gating as suite A: local skip with message; in CI missing LSP is a FAILURE

Scenario matrix:
- [ ] edit introduces a type error in pkgA → `status: errors` naming pkgA's file (session-root-relative path); a subsequent clean edit in pkgB → `clean` (pkgA's pre-existing error does NOT bleed into pkgB's report)
- [ ] signature break in pkgA file A1 → caller error in pkgA file A2 folded in (dependents stay project-scoped); pkgB files never appear in pkgA reports
- [ ] first mutation in pkgA opens only pkgA's context (open-roots accessor shows exactly `[pkgA]`); first mutation in pkgB adds pkgB's (exactly `[pkgA, pkgB]`)
- [ ] nested repo: scaffold a git-initialized sub-package INSIDE pkgA; after pkgA's context is open, an edit inside the nested repo routes to pkgA's (outer) context — nearest-open-ancestor-wins, no context opened for the nested root (documented semantics per bridge task)
- [ ] edit `Loose.swift` (diagnosable extension, no enclosing repo) → committed mutation + `status: skipped` with not-in-a-git-workspace note
- [ ] edit `notes.md` → `skipped`, no context opened for it

## Acceptance Criteria
- [ ] Error items assert on actual compiler message content AND on session-root-relative paths pointing into the correct package
- [ ] Cross-project isolation is asserted (no pkgB paths in pkgA reports and vice versa)
- [ ] Context-opening assertions go through the open-roots accessor, not inference from paths
- [ ] Suite green on the macOS 27 CI runner (no silent skip); local runs without sourcekit-lsp skip with a clear message

## Tests
- [ ] `Tests/FileToolIntegrationTests/MultiProjectTests.swift` — the matrix above IS the test list
- [ ] Run `swift test --filter MultiProjectTests` — expect: green (or explicit local skip; CI never skips)

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.