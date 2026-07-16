---
assignees:
- claude-code
depends_on:
- 01KXPCH7YPSHMNM7GA1ZPABM1W
position_column: todo
position_ordinal: '9780'
title: '`patch files` operation: @Operation wiring, result envelope, and format-teaching description'
---
## What

Create `Sources/FileTool/Operations/PatchFiles.swift`: the sixth `@Generable @Operation` struct, `verb: "patch", noun: "files"` — the first mutating plural-noun op, wiring `PatchParser` (`^9davh0r`) and `PatchEngine` (`^zpabm1w`) into the model-facing surface, following `EditFile.swift`'s structure throughout.

**Parameters:** a single `patch: String` (the whole envelope rides in one scalar — this is the shape that sidesteps the `@Operation` macro's primitives-only limit). No other parameters in v1.

**Description teaches the format.** Unlike codex-family models, FoundationModels have zero training exposure to this envelope, so the `@Operation` description string carries the whole contract: the marker lines, `+`-prefixed Add bodies, `*** Find:` / `*** Replace:` update bodies (noting a Find may be hashline-tagged lines copied from a `read file` result, or bare text), `*** Move to:`, and one compact worked multi-file example — the same role grok's 70-line `DESCRIPTION` constant plays for `apply_patch`.

**Execution** (`execute(in context: FileContext) async throws -> PatchOutput`):
1. Reject when `context.readOnly`, as the other mutating operations do.
2. `PatchParser.parse` — a `ParseFailure` becomes a `corrective` carrying its message and line number (the runtime tutor: written for the model to self-correct in-turn).
3. `PatchEngine` phase 1 + 2. A path violation, add-exists, binary-file, or stage failure → `corrective`. An unresolved update pair → a `content` result with the failing file's path and status `ambiguous`/`nearMiss`/`alreadyApplied`/`consumedTarget`, reusing the existing `EditOutcome`/`EditCandidate`/`EditNearMiss` projections from `Sources/FileTool/Operations/EditFile.swift` (extract the shared `Resolution` → wire-name mapping rather than duplicating `statusName(for:)`).

**Result envelope** (`PatchResult: Encodable`, `PatchOutput: CorrectiveEncodable` mirroring `EditOutput`):
- `status`: `applied` or the structured unresolved status.
- `files: [PatchFileResult]` — per file: `path`, `action` (`added`/`modified`/`deleted`/`moved`), `movedTo?`, `applied` pair count, `bytesWritten?`, `hash?`.
- **No `taggedContent`** in v1 — a deliberate divergence from `EditResult`, documented in the type's doc comment: echoing every touched file's tagged lines into a small on-device context is too expensive; a chained edit re-anchors with `read file`.
- The unresolved case carries the single failing `EditOutcome` plus the failing file's path; every file byte-identical (asserted by the engine).

## Acceptance Criteria
- [ ] `{"op": "patch files", "patch": "*** Begin Patch…"}` dispatches through the `Operations` runtime and applies a multi-file patch; the result lists every touched file with action, applied count, bytes written, and hash.
- [ ] A missing `op` with a `patch` key present infers `patch files` (plan.md key-inference rule).
- [ ] A malformed envelope returns a `corrective` naming the offending line; the filesystem is untouched.
- [ ] An unresolved update pair returns `status: "nearMiss"` (or `ambiguous`/…) with the failing file's path and the same candidates/near-miss diffs `edit file` produces; all files byte-identical.
- [ ] A read-only context rejects the operation with a corrective before parsing.
- [ ] The wire status/`matchedBy` names are produced by the same single mapping `edit file` uses (no duplicated `statusName` table).

## Tests
- [ ] `Tests/FileToolTests/PatchFilesTests.swift` (new): end-to-end through op dispatch against a temp directory — multi-file apply, parse-error corrective, unresolved-pair structured result, read-only rejection, op-inference from the `patch` key; snake_case payload parity with the other ops' encoding tests.
- [ ] `swift test` — full suite green.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.