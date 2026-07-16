---
assignees:
- claude-code
position_column: todo
position_ordinal: '9580'
title: 'Patch substrate: PathGuard `.delete` access kind + AtomicWriter staged multi-file commit'
---
## What

The `patch files` operation (follow-up card) needs two substrate capabilities that don't exist yet. One concern: the filesystem primitives for multi-file patching.

**1. `Sources/FileTool/PathGuard.swift` — a `.delete` access kind**

`FileOperation` currently has `read`/`write`/`edit`/`directory`. Add `case delete` plus a `checkDeletePermission(_:)` following the existing private-check pattern (`checkEditPermission` et al.):
- the path must exist and be a regular file (`S_IFREG` via the existing `fileMode` helper);
- its parent directory must be writable (POSIX deletion permission lives on the directory: parent `mode & 0o222 != 0`, reusing `parentPath` and `fileMode`);
- corrective messages in the established style ("Cannot delete non-existent file: …", "Parent directory is not writable: …").

A move/rename needs no new kind: the caller validates source with `.delete` and destination with `.write` (nonexistent-target-with-existing-parent is already `.write`'s rule).

**2. `Sources/FileTool/AtomicWriter.swift` — staged writes for all-or-nothing multi-file commits**

`write(_:to:)` is single-shot temp+rename. A multi-file patch must reduce the partial-write window: stage every file's temp first, then rename all. Add:
- `struct StagedWrite`: holds the temp URL (same-directory, as `write` does today), the destination URL, and the captured permission bits.
- `static func stage(_ data: Data, to url: URL) throws -> StagedWrite` — creates the temp file next to the destination, writes bytes, applies the destination's existing permission bits (same logic `write` uses), but does **not** rename.
- `commit()` on `StagedWrite` — the rename.
- `discard()` on `StagedWrite` — unlink the temp; idempotent, never throws.
- Refactor the existing `write(_:to:)` to be `stage` + immediate `commit` so there is one temp+rename implementation (its observable behavior — including cleanup on failure and permission preservation — must not change; `Tests/FileToolTests/AtomicWriterTests.swift` and the byte-identical round-trip cases must pass untouched).

## Acceptance Criteria
- [ ] `PathGuard.validate(_:for: .delete)` succeeds for an existing regular file in a writable directory; fails with a corrective for a nonexistent path, a directory, and a file whose parent directory has no write bits.
- [ ] `stage` creates a temp in the destination's directory without touching the destination; `commit` makes the destination's bytes equal the staged data; `discard` removes the temp and leaves the destination untouched.
- [ ] Two staged writes to different files can both be staged, then both committed — neither destination changes until its `commit`.
- [ ] `discard` after `commit` (or called twice) is a no-op that does not throw.
- [ ] All existing `AtomicWriterTests` and `PathGuardTests` pass unchanged (refactor is behavior-preserving).

## Tests
- [ ] `Tests/FileToolTests/PathGuardTests.swift`: `.delete` cases — happy path, nonexistent file, path-is-directory, read-only parent directory (chmod in a temp dir, restore in teardown).
- [ ] `Tests/FileToolTests/AtomicWriterTests.swift`: stage/commit/discard lifecycle cases above, plus permission-bit preservation through stage+commit, plus temp-file cleanup when `stage` fails (unwritable directory).
- [ ] `swift test` — full suite green.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.