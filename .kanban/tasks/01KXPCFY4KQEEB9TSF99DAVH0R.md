---
assignees:
- claude-code
position_column: todo
position_ordinal: '9480'
title: 'PatchParser: parse the `patch files` envelope (Add/Delete/Update/Move with Find/Replace bodies)'
---
## What

Create `Sources/FileTool/PatchParser.swift`: a pure, IO-free parser for the `patch files` envelope. The format keeps the codex apply_patch file-op headers (see `xai-org/grok-build`, `codex/apply_patch/parser.rs`) but **replaces `@@` hunks with hashline-style Find/Replace bodies** — an update section is a way to send many find/replace pairs (the same pairs `edit file` takes) for one file, and the envelope batches many files.

**Format (v1 spec — this card is its home):**

```
*** Begin Patch
*** Add File: <path>
+<content line>            ← every Add content line is `+`-prefixed (codex semantics)
*** Update File: <path>
*** Move to: <new path>    ← optional, immediately after Update header
*** Find:
<verbatim lines — hashline-tagged (`12:a7|text`) or bare text>
*** Replace:
<verbatim replacement lines>
*** Delete File: <path>
*** End Patch
```

Rules:
- Envelope: first non-blank line must be `*** Begin Patch`, last must be `*** End Patch`; whitespace around markers is tolerated (trim before compare). **No heredoc leniency** — grok strips `<<EOF` wrappers as a fossil of codex's shell-invocation era; our models never emit heredocs, so an unrecognized first line is a plain parse error (document this deliberate divergence).
- `*** Add File:` — zero or more `+`-prefixed lines; the `+` is stripped and lines are joined with `\n` plus a trailing newline (codex contents semantics).
- `*** Update File:` — optional `*** Move to:` line, then zero or more Find/Replace pairs. `*** Find:` and `*** Replace:` bodies are verbatim, unprefixed lines running to the next `*** ` marker. Zero pairs is legal **only** when `*** Move to:` is present (pure rename). The parser passes find/replace strings through untouched — resolving hashline anchors vs. bare text is `EditEngine`'s job downstream.
- Errors (all with 1-based line numbers, return-don't-throw): unknown `*** ` marker; `*** Replace:` without a preceding `*** Find:`; `*** Find:` with an empty body or without a following `*** Replace:`; update section with neither pairs nor a move; the same path appearing in two sections; missing/misplaced envelope markers.

Types (mirror the shape of `EditEngine`'s pure API):
- `PatchParser.Hunk`: `addFile(path: String, contents: String)`, `deleteFile(path: String)`, `updateFile(path: String, movePath: String?, pairs: [Pair])` with `Pair = (find: String, replace: String)`.
- `PatchParser.parse(_ patch: String) -> Result<[Hunk], ParseFailure>` where `ParseFailure` carries `message: String` and `line: Int` — corrective-ready, conforming to `Error` only to sit in `Result` (same convention as `PathViolation` in `Sources/FileTool/PathGuard.swift`).

Pure function, no filesystem access, no dependency on `FileContext`/`PathGuard`.

## Acceptance Criteria
- [ ] The worked example above (all four section kinds in one patch) parses into the expected `[Hunk]` values.
- [ ] Add contents round-trip: `+` stripped, `\n`-joined, trailing newline appended; an Add with zero `+` lines yields empty contents.
- [ ] An Update with `*** Move to:` and zero pairs parses (pure rename); an Update with neither pairs nor move is a `ParseFailure` naming its line.
- [ ] Find bodies containing hashline-tagged lines (`12:a7|…`) pass through byte-identical.
- [ ] Every error rule above produces a `ParseFailure` with the correct 1-based line number; nothing throws.
- [ ] A `<<EOF`-wrapped patch fails with the envelope error (documented divergence from grok).

## Tests
- [ ] `Tests/FileToolTests/PatchParserTests.swift` (new): the worked multi-section example; each section kind alone; whitespace-tolerant markers; each error rule as its own case asserting message content and line number; hashline pass-through; duplicate-path rejection; empty-envelope patch (zero hunks).
- [ ] `swift test` — full suite green.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.