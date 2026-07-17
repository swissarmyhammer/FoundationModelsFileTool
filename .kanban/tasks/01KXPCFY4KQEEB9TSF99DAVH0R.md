---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kxqha72v47z98v11fgy2v5sx
  text: |-
    Implemented `Sources/FileTool/PatchParser.swift` (pure, IO-free) + `Tests/FileToolTests/PatchParserTests.swift` (21 cases), TDD red→green.

    Design:
    - `PatchParser` enum with `public typealias Pair = (find: String, replace: String)` (tuple, per spec) and `public enum Hunk { addFile/deleteFile/updateFile }`. `Hunk: Sendable` + hand-written `Equatable` (tuple pairs compared positionally, since tuples can't synthesize Equatable).
    - `ParseFailure` is a top-level `Error, Equatable, Sendable, CustomStringConvertible` struct carrying `message`+`line`, mirroring the top-level `PathViolation` return-don't-throw convention (NOT nested in PatchParser).
    - Data-driven markers: `exactMarkers` table (Begin/End/Find/Replace) + `pathMarkers` table (Add/Update/Delete/Move → path). One `classify(_:)` trims then classifies as `.marker/.unknownMarker/.content`. `@Sendable` on the pathMarkers closure to satisfy Swift 6.2 strict concurrency.
    - Private `Parser` struct cursor (lines, exclusive `end`=End index, seenPaths, index); `parseSections`→`parseSection`→`parseUpdate`→`parsePair`→`consumeBody`. Bodies run verbatim to the next marker; Add strips one leading `+` and joins with `\n`+trailing newline (empty body ⇒ "" not "\n"); Find/Replace joined with `\n`, no trailing newline (hashline passes through byte-identical).
    - All 6 error rules produce ParseFailure with 1-based line numbers; distinctive substrings ("preceded" vs "followed") keep the two Find/Replace errors assertable.

    Verification: `swift test` full suite green — 306 unit tests / 20 suites + 26 integration / 7 suites, zero failures, no new warnings. Left in doing for review.
  timestamp: 2026-07-17T07:58:02.331241+00:00
- actor: claude-code
  id: 01kxqhpyrrge0gg2jd1c944kcw
  text: |-
    Adversarial double-check ran (advisory gate). Verdict REVISE with 3 edge-case findings; it confirmed the written spec + all 6 Acceptance Criteria are fully satisfied and the suite is green. Proceeding past all three with justification (really-done permits fix-or-justify), because each proposed fix regresses correctness:

    1. Move destination exempt from duplicate-path detection — INTENTIONAL. Spec scopes the rule to "the same path appearing in two sections" (section = header path); the parser is "deliberately dumb". Recording move destinations in seenPaths would falsely reject legal filename swaps/rotations (rename a→b AND c→a — both legal since a is freed before reuse). Cross-path conflict analysis needs apply-order semantics, which live in PatchEngine (^zpabm1w), not the parser. Left a note on that card.

    2. Add body absorbs blank/non-`+` lines — INTENTIONAL (forgiving). The greedy "run to next marker" model produces the likely-intended file when a model forgets a leading `+` on an interior blank line (empty content line). The suggested "consume only `+`-lines" fix would REJECT such reasonable model output (e.g. `+l1`\n\n`+l3`), contradicting the tools' forgiving/return-don't-throw philosophy and the exhaustively-enumerated error list ("Errors (all ...)"). The only downside — a trailing blank separator adds one spurious `\n` — is a minor cosmetic edge not worth the brittleness.

    3. Single-blank-line Find body rejected as empty; the emptiness test is on the joined string. INTENTIONAL and safer: a find joining to "" is genuinely empty and useless (never reaches EditEngine), matching the "empty body" criterion; a find of "\n" (two blank lines) is a real pattern and is accepted. Basing the check on line count instead would let an empty find string through to EditEngine, which is worse.

    No code change; behavior matches spec exactly, suite green (306 unit + 26 integration).
  timestamp: 2026-07-17T08:04:59.800533+00:00
position_column: done
position_ordinal: '9580'
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