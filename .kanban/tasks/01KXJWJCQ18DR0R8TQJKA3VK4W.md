---
depends_on:
- 01KXJWH0ZGPEAKRDWN520P15XY
position_column: todo
position_ordinal: '8780'
title: GlobEngine + glob files operation
---
## What
Per plan.md §3 op table row 4. Create `Sources/FileTool/GlobEngine.swift` and `Sources/FileTool/Operations/GlobFiles.swift`:
- Params: `pattern` (req), `path?` (default session root), `caseSensitive?` (default false), `respectGitIgnore?` (default true)
- Broad-pattern guard: when NO `path` given, reject `*`, `**/*`, `*.*`, bare `**/*.ext` with guidance to scope; allowed when `path` scopes the walk; pattern > 1000 chars rejected; invalid syntax → corrective
- Walk: `respectGitIgnore` + repo present → `git ls-files --cached --others --exclude-standard` (plan decision §6.8); otherwise `FileManager` enumerator; never walk filesystem root (PathGuard)
- Match filename-only for non-`/` non-`**` patterns, relative-path for `**`/dir patterns (Rust parity)
- Sort by mtime newest-first; result cap via `GlobEngine.init(maxResults: Int = 10_000)` — the injectable seam tests use with a small value; honest `capped` flag; paths relative to session root
- Output `GlobResult: Encodable { pattern, files, total, capped }`

## Acceptance Criteria
- [ ] Gitignored file absent with default, present with `respectGitIgnore: false`
- [ ] Broad-pattern matrix behaves exactly per Rust (rejected unscoped, allowed scoped)
- [ ] Result order strictly mtime-descending; `capped: true` with `files.count == maxResults` when over cap

## Tests
- [ ] `Tests/FileToolTests/GlobFilesTests.swift`: temp git repo with real `.gitignore`; non-repo fallback walk; broad-pattern matrix; case sensitivity both ways; mtime order (set file dates explicitly); cap + `capped` flag via injected small `maxResults`; nonexistent dir corrective; pattern-too-long
- [ ] Run `swift test --filter GlobFilesTests` — expect: green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.