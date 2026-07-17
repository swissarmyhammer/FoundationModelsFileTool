---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kxqjd4wf88twekvyb7bebjhs
  text: 'Implemented TDD. PathGuard: added FileOperation.delete + checkDeletePermission (existing regular file, parent dir writable via parent mode & 0o222; messages "Cannot delete non-existent file:", "Cannot delete non-regular file:", "Parent directory is not writable:"), wired into checkPermission switch. AtomicWriter: added StagedWrite struct (temporaryURL/destinationURL/permissionBits) with commit() (rename) and idempotent non-throwing discard() (unlink); added static stage(_:to:) that writes sibling temp + applies dest permission bits without renaming, cleaning up temp on failure; refactored write(_:to:) to stage + commit (discard-on-commit-failure) so there is one temp+rename impl. Behavior-preserving. Tests added to PathGuardTests (delete happy/nonexistent/directory/read-only-parent) and AtomicWriterTests (stage/commit/discard lifecycle, two-file independent commit, discard-after-commit no-op, permission preservation, temp cleanup on failed stage). Filtered: 48 tests green across both suites. Full `swift test` exits 0. Did not touch Package.resolved. Task stays in doing pending review.'
  timestamp: 2026-07-17T08:17:06.959945+00:00
- actor: claude-code
  id: 01kxqk8hh6w9n06k9yksv2yqwm
  text: |-
    Worked the 2 review findings (both duplication in production source; line numbers in findings were stale from the original implementation).

    1. AtomicWriter.swift: the two if-else branches of `decode(_:)` differed only by the data variable and the encoding. Extracted `private static func decodeAsUTF8(from data: Data, encoding: TextEncoding) -> DecodedText?` (the guard-decode-return pattern) and call it from both branches — BOM branch passes `data.dropFirst(utf8ByteOrderMark.count)` with `.utf8WithByteOrderMark`, the fallthrough passes `data` with `.utf8`. Behavior byte-identical.

    2. PathGuard.swift: `checkEditPermission` and `checkDeletePermission` built the same "Cannot <op> non-existent file: <path>" message. Extracted `private static func nonexistentFileViolation(operation:path:)` (placed with the other static violation constructors) and call it from both with operation "edit"/"delete". Exact strings unchanged.

    Both refactors behavior-preserving; existing tests are the regression guard (decode round-trip cases; PathGuard `.contains("non-existent")` for both edit and delete). Filtered `swift test --filter "PathGuardTests|AtomicWriterTests"`: 48 tests, 2 suites, green. Full `swift test`: 317 tests/20 suites + 26 tests/7 suites, exit 0 (only warning is the pre-existing mlx-swift bundle warning, unrelated). Both findings flipped to [x]. Task left in doing for review. Package.resolved untouched.
  timestamp: 2026-07-17T08:32:04.646015+00:00
position_column: doing
position_ordinal: '80'
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

## Review Findings (2026-07-17 03:19)

- [x] `Sources/FileTool/AtomicWriter.swift:260` — Near-verbatim code block repeats at line 263 — identical pattern differing only by a data variable and an encoding parameter. This is one function with two arguments, not two implementations. Extract a private helper function `decodeAsUTF8(from data: Data, encoding: TextEncoding) -> DecodedText?` that encapsulates the guard-decode-return pattern, then call it from both branches of the if-else.
- [x] `Sources/FileTool/PathGuard.swift:506` — Near-verbatim error message repeats at line 541 — identical pattern differing only by operation name (edit vs delete). Both check file existence and return a nearly identical failure message. Extract a private helper function that constructs the 'cannot-operate-on-nonexistent-file' violation message parameterized by operation name, then call it from both `checkEditPermission` and `checkDeletePermission`.