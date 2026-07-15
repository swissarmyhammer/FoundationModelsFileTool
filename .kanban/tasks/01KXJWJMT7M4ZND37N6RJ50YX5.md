---
depends_on:
- 01KXJWH0ZGPEAKRDWN520P15XY
position_column: todo
position_ordinal: '8880'
title: GrepEngine + grep files operation
---
## What
Per plan.md §3 op table row 5. Create `Sources/FileTool/GrepEngine.swift` and `Sources/FileTool/Operations/GrepFiles.swift`:
- Params: `pattern` (req, regex), `path?` (file or dir), `glob?` filename filter, `type?` file-type filter (ported mapping: `rust`/`py`/`js`/`ts`/`swift`/`json`/`yaml`/`toml`/`md`/…; unknown type → corrective listing known ones), `caseInsensitive?` (prepend `(?i)`), `contextLines?` (default 2; 0 = match lines only), `outputMode?` (`content` | `filesWithMatches` | `count`, default `content`)
- Walk shared with GlobEngine (git-aware ignore, fallback plain); single-file path short-circuits; binary skip on null byte in first 8 KiB
- Swift `Regex` line matcher; invalid pattern → corrective
- Context assembly: match lines flagged `isMatch: true`, context lines false, hunk boundaries between non-adjacent groups; only match lines count toward totals
- Output `GrepResult: Encodable` shaped by mode: `matches [{file, line, text, isMatch}]`, `matchCount`, `fileCount`, `elapsedMs`; files list for filesWithMatches; counts for count

## Acceptance Criteria
- [ ] Unscoped grep in a repo with an ignored `build/` dir never touches it (the "hung grep" fix)
- [ ] Context lines correct at 0/2/N incl. hunk separation and file-boundary edges
- [ ] All three output modes return their documented shapes

## Tests
- [ ] `Tests/FileToolTests/GrepFilesTests.swift`: basic match; invalid regex corrective; case insensitive; type filter (match + unknown-type corrective); glob filter; three modes; context 0/2/N + hunk boundaries; binary file skipped; single-file path; nonexistent path corrective; gitignore exclusion
- [ ] Run `swift test --filter GrepFilesTests` — expect: green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.