---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kxqqt0c30z61ydh9z50z93px
  text: 'Picked up. Research done. Plan: (1) extract the shared EditEngine.Resolution -> wire projection (statusName/outcome/candidate/nearMiss/appliedStatus) out of EditFile.swift into an internal `EditOutcomeProjection` so patch reuses edit''s exact mapping (no duplicated statusName table); (2) add Sources/FileTool/Operations/PatchFiles.swift: @Generable @Operation(verb:patch, noun:files) with single `patch: String` param (alias `input`), PatchResult/PatchFileResult/PatchOutput envelope projecting PatchEngine.FileOutcome, corrective for ParseFailure (message + line) and PatchEngine.Failure.corrective, content+unresolved status (nearMiss/ambiguous/...) reusing EditOutcome; format-teaching multi-line @Operation description (Begin/End/Add/Update/Delete/Move + Find/Replace bodies + worked example); (3) register in FileTool.make/makeReadOnly (+ ReadOnlyPatchFiles stub matching write/edit read-only convention), fileVerbSelfAliases, and a `patch`-key inference rule; (4) update the existing "exactly five ops" dispatch/schema tests to six. Verified via macro source that @Operation description takes verbatim source text so a multiline literal is safe. TDD.'
  timestamp: 2026-07-17T09:51:31.203910+00:00
- actor: claude-code
  id: 01kxqrtznmtmvya2xcjdkaw6ad
  text: |-
    Implementation landed, green, left in doing for review.

    What shipped:
    - Sources/FileTool/Operations/PatchFiles.swift — @Generable @Operation(verb: patch, noun: files). Single `patch: String` param (alias `input`). execute(): PatchParser.parse (ParseFailure -> corrective via .description, carrying the line number) then PatchEngine.apply(_:using: context.pathGuard); PatchEngine.Failure.corrective -> corrective, .unresolved -> content PatchResult (status/EditOutcome via EditOutcomeProjection). Envelope: PatchResult{status, files:[PatchFileResult{path,action,movedTo?,applied,bytesWritten?,hash?}], path?, outcome?} + PatchOutput: CorrectiveEncodable. No taggedContent (deliberate, documented). Format-teaching contract in top-level `private let patchFilesFormatTeaching` referenced by @Operation description.
    - Sources/FileTool/EditOutcomeProjection.swift (new) — extracted the shared EditEngine.Resolution -> wire mapping (statusName/outcome/candidate/nearMiss/appliedStatus) out of EditFile.swift so edit+patch use ONE mapping (no duplicated statusName table). EditFile.swift now calls it.
    - Sources/FileTool/FileTool.swift — registered PatchFiles in make(), ReadOnlyPatchFiles stub in makeReadOnly() (structural read-only rejection before parse/mutation, matching write/edit), PatchFiles.verb in fileVerbSelfAliases, a `patch`-key inference rule, five->six docs.
    - Tests/FileToolTests/PatchFilesTests.swift (new, 10 tests) + FileToolDispatchTests.swift updated 5->6 ops.

    Non-obvious discoveries:
    - @Operation(description:) emits the argument's SOURCE TEXT verbatim, so a multi-line string literal works there BUT (a) it breaks the line-based DocCCoverageTests scanner (unindented literal lines reset the pending-doc state before `public struct`), and (b) referencing a member `PatchFiles.formatTeaching` in the attribute is a "circular reference resolving attached macro" error. Fix: a top-level file-private constant referenced from the attribute — readable multiline, no cycle, scanner-safe.
    - Existing files' reported paths are guard-canonicalized through the /var -> /private/var symlink (as edit file does), so tests match by suffix.

    really-done: full `swift test` green (342 unit + 26 integration, 0 failures/0 warnings). double-check verdict REVISE with two low-severity doc-drift findings (FileContext.swift and FileToolCLI.swift "five"->"six") — both fixed, re-ran suite green. Ready for /review.
  timestamp: 2026-07-17T10:09:31.828081+00:00
depends_on:
- 01KXPCH7YPSHMNM7GA1ZPABM1W
position_column: done
position_ordinal: '9880'
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