---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kxqhq3e4dxe2c1yqy0fak2kw
  text: 'Note from PatchParser (^9davh0r) implementation: the parser deliberately does NOT detect an in-patch conflict between a `*** Move to:` destination and another section''s path (e.g. rename a→b in one section + Add/Update/Delete b in another). Its duplicate-path rule is scoped to header paths only, because rejecting move-destination collisions at parse time would falsely reject legal filename swaps/rotations (a→b, c→a). Cross-path conflict detection needs apply-order semantics — consider handling it here in PatchEngine''s phase-1 compute (where paths are validated and the all-or-nothing set is built), so two operations targeting the same final path abort the patch cleanly.'
  timestamp: 2026-07-17T08:05:04.580155+00:00
depends_on:
- 01KXPCFY4KQEEB9TSF99DAVH0R
- 01KXPCGDK4JRSW7H2GPK17MSBM
position_column: todo
position_ordinal: '9680'
title: 'PatchEngine: two-phase compute-all-then-write multi-file patch application over EditEngine'
---
## What

Create `Sources/FileTool/PatchEngine.swift`: the orchestration layer that turns parsed `PatchParser.Hunk` values (from the PatchParser card, `^9davh0r`) into an all-or-nothing multi-file mutation, modeled on grok's `compute_all_changes` (`xai-org/grok-build`, `codex/apply_patch/tool.rs`) but stronger on both fidelity and write atomicity.

**Phase 1 — compute every change in memory, no writes:**
For each hunk, validate the path via the context's `PathGuard` and build a `FileChange`, aborting the whole patch on the first failure:
- `addFile`: validate with `.write`; corrective if the file already exists (overwrite is `write file`'s job, an Add in a patch means "new file").
- `deleteFile`: validate with `.delete` (from the substrate card, `^k17msbm`); read the original bytes.
- `updateFile`: validate with `.edit` (and the move destination, if any, with `.write`); read and decode via `AtomicWriter.decode` (binary → corrective), record `detectLineEnding`, then resolve the pairs with the existing `EditEngine.apply(_:to:)` — updates get **exactly** `edit file`'s semantics: anchor → literal → recovery-ladder cascade, unique-or-ambiguous discipline, already-applied/consumed-target reclassification. Any unresolved pair aborts the whole patch, carrying the failing file's path plus the `EditEngine.Resolution` so the caller can surface candidates/near-misses.
- A pure rename (move with zero pairs) re-encodes the original content unchanged for the destination.

Result of phase 1: `[FileChange]` (cases `add`, `update`, `delete`, `move` — each mutating case carrying original content, new content, and the detected encoding to re-encode with) or a structured failure. Nothing on disk has changed.

**Phase 2 — staged apply:**
- `AtomicWriter.stage` every add/update/move-destination write (re-encoding with each file's detected encoding, as `EditFile.commit` does today); on any stage failure, `discard` all staged temps and return a corrective — destinations untouched.
- Only when every stage succeeded: `commit()` each staged write, then unlink deletes and move sources (deletes last, so an interrupted patch errs on the side of extra files, never lost ones).
- Report per-file outcomes: path, action (`added`/`modified`/`deleted`/`moved` + moved-to path), applied pair count, bytes written, and `Hashline.wholeFileHash` over the committed bytes.

Keep the engine free of `@Operation`/wire types — it returns engine-level values; the `patch files` operation card projects them. Mirrors how `EditEngine` stays pure of `EditFile`'s `Encodable` layer.

## Acceptance Criteria
- [ ] A patch combining add + update + delete + move lands all four in one call, with per-file outcomes carrying action, applied count, bytes written, and hash.
- [ ] An update body whose pair fails to resolve (near-miss or ambiguous) aborts the **entire** patch: every file byte-identical, failure carries the path and the `EditEngine.Resolution`.
- [ ] An add targeting an existing file, a delete of a nonexistent file, and a binary update target each abort the whole patch with a corrective before any write.
- [ ] Update preserves encoding and line endings per file (a CRLF/BOM file patched alongside an LF file keeps each convention — reusing the `AtomicWriter` decode/encode path).
- [ ] A stage failure (e.g. unwritable directory for one of three files) leaves all three destinations untouched and no temp files behind.
- [ ] A pure rename moves the file with byte-identical content.

## Tests
- [ ] `Tests/FileToolTests/PatchEngineTests.swift` (new): each acceptance criterion as a case against a temp directory, following the `EditFileTests` temp-dir fixture pattern; the abort-all case asserts byte-identical originals via before/after reads.
- [ ] `swift test` — full suite green.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.