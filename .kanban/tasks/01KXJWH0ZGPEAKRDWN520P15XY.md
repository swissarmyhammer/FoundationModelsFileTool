---
depends_on:
- 01KXJWG0E2246T5Y42D8N71Z1G
position_column: todo
position_ordinal: '8380'
title: PathGuard validation stack + FileContext
---
## What
Per plan.md §3 "PathGuard". Create `Sources/FileTool/PathGuard.swift` and `Sources/FileTool/FileContext.swift`, porting the Rust `shared_utils.rs` validation stack:
- Empty/length (≤ 4096) checks; blocked patterns (`../` traversal, null bytes, control chars)
- Relative paths resolve against the **session root** (FileContext.root), never process CWD
- Symlink rejection **before** canonicalization; `allowSymlinks` opt-in
- Optional workspace-boundary enforcement (`starts_with` after canonicalizing via deepest existing parent — handles nonexistent write targets)
- Filesystem-root walk refusal (`/`, bare `.`, empty)
- Per-operation permission checks: read (regular file + readable), write (existing not readonly / parent exists), edit (exists + writable)
- All violations return corrective messages (upstream return-don't-throw pattern), never throw

`FileContext`: session root URL, PathGuard, `readOnly` flag, lazy `DiagnosticsBridge` handle (stub until the bridge task).

## Acceptance Criteria
- [ ] Every dangerous-path exemplar from the Rust integration suite (`../../../etc/passwd` family) is rejected with a corrective message on all ops
- [ ] Symlinked path rejected by default, accepted with `allowSymlinks: true`
- [ ] A nonexistent target inside the workspace passes boundary check (write); outside fails

## Tests
- [ ] `Tests/FileToolTests/PathGuardTests.swift`: table-driven — traversal exemplars; symlink pre-canonicalize rejection + opt-in; workspace boundary incl. deepest-existing-parent; root-walk refusal (`/`, `.`, empty); length/null/control rejects; per-op permission checks (readonly file, missing parent); session-root (never CWD) relative resolution
- [ ] Run `swift test --filter PathGuardTests` — expect: green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.