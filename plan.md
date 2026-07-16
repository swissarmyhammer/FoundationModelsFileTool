# Plan: FoundationModelsFileTool — the sah `files` tool for Foundation Models, with live edit diagnostics

A Swift package that ports the swissarmyhammer **`files` MCP tool** — read / write / edit /
glob / grep with hashline anchors, atomic writes, and encoding preservation — to Apple's
[Foundation Models framework](https://developer.apple.com/videos/play/wwdc2026/241/), built on
[`FoundationModelsOperations`](https://github.com/swissarmyhammer/FoundationModelsOperationTool)
(the sah "operation" pattern: `op: "verb noun"` dispatch, flat-union fused schema, forgiving
resolver, dual-use CLI) and on
[`FoundationModelsCodeContext`](../FoundationModelsCodeContext) for **syntax checking and live
edit error detection**: every `write file` / `edit file` on a diagnosable source file is followed
by an LSP diagnostics pass, and the result — clean, or the actual compiler errors — rides back in
the tool output. One fused `OperationTool` named **`files`** carries the same five operations as
the Rust original: **`read file` / `write file` / `edit file` / `glob files` / `grep files`**.
**Target: macOS, on-device.**

---

## 1. Guiding principles

- **Same vocabulary as sah.** Op strings, parameter names and aliases, defaults, the
  `#hash:` freshness token, the `N:HH|` hashline anchor format, and the behavioral contracts
  in the Rust tool's `description.md` files all carry over
  (`swissarmyhammer-tools`, `mcp/tools/files/`), so a user moving between the Rust MCP server
  and this package sees one tool, not two dialects. Deliberate departures are few and
  recorded (§8).
- **Anchors make edits survivable.** The core idea of the sah file tools: `read file` tags
  every line with a `{line}:{hash}|` anchor and the whole file with a `#hash:` token; `edit
  file` resolves those anchors even after the file drifts (±50-line proximity search), falls
  back to literal matching, then to a recovery ladder for re-indented/renormalized text — and
  when it *can't* resolve confidently, it returns candidates instead of guessing. This is what
  makes multi-step editing by a context-constrained on-device model reliable.
- **Every mutation is checked.** This is the capability the Rust tool gets from its MCP
  chokepoint and this package gets from `FoundationModelsCodeContext`: after a successful
  `write file` or `edit file` on an LSP-backed language, we run
  `CodeContext.diagnostics(scope: .file(path))` and fold the settled errors/warnings into the
  op's typed output. The model finds out *in the same turn* that its edit broke the build —
  no separate "now run the compiler" step.
- **Operations are declarations.** The five ops are `@Generable @Operation` structs on a
  shared `FileContext`; we inherit schema fusion, the forgiving resolver, return-don't-throw
  corrective errors, the retry cap, and the CLI driver from `FoundationModelsOperations` —
  nothing op-shaped is hand-rolled here.
- **Atomic, preserving, honest.** Writes land via temp-file + `rename` in the target
  directory; edits are resolved entirely in memory and committed in one atomic rewrite;
  detected encoding, line endings (LF/CRLF/CR/Mixed), and permission bits are preserved;
  ambiguity, near-miss, already-applied, and consumed-target outcomes are reported as
  structured, retryable results — the file is left byte-identical unless every pair resolved.
- **macOS 27+ only.** `FoundationModelsCodeContext` declares macOS 27 (its FoundationModels v2
  / LSP floor) and spawns `sourcekit-lsp` subprocesses; there is no iOS story. The package
  declares macOS 27+ and nothing else.

## 2. Background: the Rust tool being ported

Reference implementation: `../swissarmyhammer` crate `swissarmyhammer-tools`, module
`mcp/tools/files/` (one op-dispatched `FilesTool`, category `Replacement { native: "Edit" }`),
with `swissarmyhammer-hashline` (anchors/tokens), `swissarmyhammer-edit-match` (recovery
ladder), and `swissarmyhammer-operations` (the pattern `FoundationModelsOperations` already
ports). Load-bearing behaviors to carry over:

- **Dispatch**: `op` selects the operation; missing `op` is **inferred** from the keys present
  (edit-ish keys → edit, checked first; `content` → write; `pattern`+`case_insensitive` →
  grep; `pattern` alone → glob; `path` alone → read; otherwise a corrective error).
- **`read file`**: `path` (req; aliases `file_path`, `absolute_path`), `offset` (1-based line,
  ≤ 1,000,000), `limit` (> 0, ≤ 100,000), `format` `hashline`|`plain` (default `hashline`).
  First line of every read is `#hash:<hex>` — an MD5 freshness token over the **full** on-disk
  bytes regardless of windowing; hashline anchors stay absolute across windows. Non-UTF-8
  (binary) files are rejected, never decoded or base64'd.
- **`write file`**: `file_path` + `content` (both req). 10 MiB content cap. Unconditional
  clobber — no freshness check by design (source control is the recovery path; lost-update
  protection is edit's job). Parent directories created. Atomic temp+rename with cleanup on
  every failure path. Success returns a mutation envelope: bytes written, mutated path, and
  the just-written content hashline-tagged so a chained edit can lift an anchor without
  re-reading.
- **`edit file`**: `file_path`, `find`, `replace` (rich aliases: `old_string`/`old`/`search`/
  `from`/`target`/`match`; `new_string`/`new`/`to`/`with`/`replacement`), `replace_all`,
  `occurrence` (1-based disambiguator), and/or `edits: [{find, replace, replace_all?}]`.
  Input shapes: scalar pair, parallel arrays (N+N zip; N finds + 1 replace broadcast), or the
  `edits` array. Per-pair **resolution cascade**: hashline anchor (`N:HH`, optional `|text`
  verifier; ±50-line drift window) → literal substring → recovery ladder (drifted /
  re-indented / line-ending-normalized matches, original bytes preserved). Competing anchor +
  literal candidates → surfaced, never guessed. Structured non-error outcomes that leave the
  file untouched: **ambiguous** (numbered candidates with context; retry with `occurrence` or
  `replace_all`), **near-miss** (line-level diff of find vs. current), **already-applied**,
  **consumed-target** (earlier pair in the batch overwrote a later pair's target). Hard error:
  `find == replace` (no-op). All pairs resolve against an in-memory working copy; one atomic
  commit; detected encoding (BOM-aware), line-ending convention, and permission bits
  preserved; mtime deliberately **not** preserved (build systems must see the change).
- **`glob files`**: `pattern` (req), `path` (default session root), `case_sensitive` (default
  false), `respect_git_ignore` (default true). Unscoped overly-broad patterns (`*`, `**/*`,
  `*.*`, bare `**/*.ext`) rejected with guidance — allowed when `path` scopes the walk.
  Results sorted by mtime (newest first), capped at 10,000, never walks the filesystem root.
- **`grep files`**: `pattern` (regex, req), `path`, `glob` filter, `type` filter,
  `case_insensitive`, `context_lines` (default 2), `output_mode`
  `content`|`files_with_matches`|`count`. `.gitignore`-aware walk (skips `target/` etc. — the
  fix for "unscoped grep hung forever"), binary files skipped on first null byte, ripgrep-style
  rendering (`:` match lines, `-` context lines, `--` hunk dividers).
- **Security/validation** (`shared_utils.rs`): path length ≤ 4096; `..` traversal rejected;
  symlinks rejected by default (checked *before* canonicalization); optional workspace-root
  boundary (`starts_with` after canonicalizing via deepest existing parent); null bytes /
  control chars rejected; filesystem-root walks refused; permission checks per operation
  (read: regular+readable; write: not readonly / parent exists; edit: exists+writable);
  relative paths resolve against the **session root**, never the process CWD.
- Not ported: MCP rate limiting, MCP log notifications, the wire-vs-full dual schema — all
  artifacts of the multi-client MCP server surface (§8).

## 3. Architecture

### Package layout

Swift package `FoundationModelsFileTool`, Swift 6.2 tools, platform **macOS 27+**
(CodeContext floor; no iOS). Mirrors the sibling packages' root-package layout — Examples are
targets of the root `Package.swift`, so one `swift build` covers everything:

```
Sources/
  FileTool/                # ops, FileContext, PathGuard (security), Hashline,
                           #   EditEngine, AtomicWriter, GlobEngine, GrepEngine,
                           #   DiagnosticsBridge, typed outputs
Examples/
  FileDemo/
    Sources/file-demo/     # thin executable: CLI / --chat / --script modes
Tests/
  FileToolTests/           # unit tier: hashline, engines, guard, dispatch, CLI
  FileToolIntegrationTests/# isolated-directory tier: real workspaces, real
                           #   sourcekit-lsp, real errors (§10)
```

Dependencies:
- `FoundationModelsOperations` (branch `main`) — `Operations` + `OperationsCLI` products;
  re-exports ArgumentParser.
- `FoundationModelsCodeContext` (branch `main`) — the diagnostics engine (`CodeContext`
  facade, `Diagnostic`/`DiagnosticSeverity`/`LSPRange`/`Position` LSP value types).
- Nothing else. Hashing is CryptoKit (`Insecure.MD5` — a freshness token, not security);
  regex is Swift `Regex`; `.gitignore` honoring shells out to the `git` CLI (the same choice
  CodeContext already made for scope resolution) rather than pulling a walker dependency.

### The operation vocabulary

One fused `OperationTool` (name `"files"`, description matching sah: *"File operations for
reading, writing, editing, and searching files."*), five `@Generable @Operation` structs
sharing a `FileContext` (session root, `PathGuard`, `DiagnosticsBridge`). Flat-union schema:
required `op` enum + all fields optional, per-op requiredness validated at dispatch with
corrective messages, never throws (upstream's pattern, including the retry cap).

| op | parameters | behavior |
|---|---|---|
| `read file` | `path` (req), `offset?` (1-based line, ≤ 1M), `limit?` (≤ 100k), `format?` (`hashline` \| `plain`, default `hashline`) | Validate path → read UTF-8 (binary → corrective) → window → tag. Output leads with the whole-file `#hash:` token; hashline anchors are absolute regardless of window. |
| `write file` | `filePath` (req), `content` (req, ≤ 10 MiB) | Validate → create parents → atomic temp+rename → **diagnostics pass** (§4) → mutation envelope: bytes written, freshness token, hashline-tagged content for chaining, diagnostics. |
| `edit file` | `filePath` (req), `find` / `replace` (scalar or parallel arrays), `replaceAll?`, `occurrence?`, `edits?` `[{find, replace, replaceAll?}]` | Normalize shapes → per-pair cascade (anchor → literal → recovery) against an in-memory copy → one atomic commit preserving encoding / line endings / permissions → **diagnostics pass** (§4). Ambiguity / near-miss / already-applied / consumed-target are structured retryable outcomes; `find == replace` is a corrective error. |
| `glob files` | `pattern` (req), `path?`, `caseSensitive?` (default false), `respectGitIgnore?` (default true) | Broad-pattern guard when unscoped → git-aware walk → mtime sort (newest first) → ≤ 10,000 paths relative to session root, with an honest `capped` flag. |
| `grep files` | `pattern` (req, regex), `path?`, `glob?`, `type?`, `caseInsensitive?`, `contextLines?` (default 2), `outputMode?` (`content` \| `filesWithMatches` \| `count`, default `content`) | Git-aware walk (or single file) → line-matched Swift `Regex` → binary skip on null byte → matches with file, line number, `isMatch` flag, and context, plus match/file totals and elapsed ms. |

- Field names are camelCase in Swift (`filePath`, `replaceAll`, `contextLines`); upstream's
  resolver normalizes snake_case payloads (`file_path`, `replace_all`, `case_insensitive`,
  `output_mode`) to them, so sah-style payloads work verbatim. The Rust tool's parameter
  aliases (`old_string`→`find`, `new_string`→`replace`, `absolute_path`→`path`, …) are
  declared as resolver aliases — the model can speak native-Edit dialect and still land here.
- Missing `op` uses the tool-level inference hook (upstream's opt-in closure) with the Rust
  key-inference order: edit-ish keys → `edit file`; `content` → `write file`;
  `pattern` + `caseInsensitive`/`contextLines`/`outputMode` → `grep files`; `pattern` →
  `glob files`; `path` alone → `read file`; nothing determinable → corrective error naming
  all five ops.

### Typed outputs

Upstream `AnyOperation.run` JSON-encodes every `Output: Encodable`; as in the Shelltool port,
each op returns a small `Encodable` struct whose keys mirror the Rust response fields:

```swift
struct ReadResult: Encodable {
    let hash: String              // whole-file freshness token (full on-disk bytes)
    let lines: [String]           // "N:HH|text" tagged (or plain) lines, windowed
    let note: String?             // "showing lines 60–120 of 843" when windowed
}

struct WriteResult: Encodable {
    let path: String
    let bytesWritten: Int
    let hash: String              // freshness token of the just-written content
    let taggedContent: [String]   // hashline-tagged, so a chained edit needs no read
    let diagnostics: FileDiagnostics?   // §4 — nil only for non-diagnosable files
}

struct EditResult: Encodable {
    let path: String
    let status: String            // applied | ambiguous | nearMiss | alreadyApplied
    let applied: Int              // pairs applied (0 unless status == applied)
    let outcomes: [EditOutcome]   // per-pair: matched-by (anchor/literal/recovered),
                                  //   line, or candidates / near-miss diff / consumed note
    let bytesWritten: Int?
    let encoding: String?         // "utf-8", "utf-8 bom", …   (preserved)
    let lineEndings: String?      // "lf" | "crlf" | "cr" | "mixed"   (preserved)
    let hash: String?             // fresh token after commit
    let taggedContent: [String]?  // tagged committed content for chaining
    let diagnostics: FileDiagnostics?
}
```

`GlobResult` (pattern, `files` newest-first, `total`, `capped`) and `GrepResult` (`matches`
as `{file, line, text, isMatch}`, `matchCount`, `fileCount`, `elapsedMs`, mode-shaped) follow
the same pattern. The `"{n}:{hh}|{text}"` anchor line format is kept verbatim — it is compact
and teaches the model the addresses `edit file` accepts.

### Hashline (module)

A direct port of `swissarmyhammer-hashline`: `tag(lines, startLine)` producing `N:HH|text`
(absolute 1-based line + 2-hex-char content hash), `wholeFileHash(bytes)` producing the
`#hash:` token (lowercase-hex MD5), and `resolveAnchor(anchor, in: lines)` — exact line, else
nearest line within the **±50-line proximity window** whose content hashes to `HH`, with the
optional `|text` suffix verifying/relocating. The hash algorithm is ported exactly so anchors
emitted by the Rust tool resolve here and vice versa — one anchor dialect across the ecosystem.

### EditEngine

The §2 cascade as a pure, testable core: `normalize(args) → [Pair]` (scalar / parallel-array /
`edits[]` shapes; N+1 broadcast; mismatch → corrective listing the unpaired remainder),
`resolve(pair, in: working)` → `.anchor(line)` / `.literal(range)` / `.recovered(range)` /
`.ambiguous([Candidate])` / `.noMatch([NearMiss])`, reclassification of no-match to
already-applied / consumed-target using batch context, and `apply` against the in-memory
working copy so later pairs see earlier results. The recovery ladder ports
`swissarmyhammer-edit-match`: whitespace-flexible and indentation-shifted matching that
preserves the original surrounding bytes. `AtomicWriter` owns encoding detection (BOM +
detection, UTF-8 fallback), line-ending detection, temp-file naming (`{path}.tmp.{uuid}` in
the same directory), permission re-application, `rename`, and single-path cleanup on failure.

### PathGuard

The port of `shared_utils`' validation stack, one type: empty/length (≤ 4096) checks, blocked
patterns (`../`, null bytes, control chars), relative-path resolution against the **session
root** (never the process CWD), symlink rejection before canonicalization (off by default,
opt-in `allowSymlinks`), optional workspace-boundary enforcement via deepest-existing-parent
canonicalization, filesystem-root walk refusal, and per-operation permission checks. All
violations are returned as corrective messages, not thrown — the model can correct the path
within the turn.

## 4. Live edit error detection — the CodeContext bridge

The reason this package is more than a port. **Multi-project by design** (rescoped
2026-07-15): `FileContext.root` may sit *above* several git projects, so `DiagnosticsBridge`
wraps one lazily-created `CodeContextManager<ProcessLanguageServerConnection>` — not a single
`CodeContext` — and resolves the covering context *per mutated file*. The manager is created
on the first mutation of a diagnosable file (a `.disabled` bridge never creates it; an
`eagerWarmup: true` bridge warms the project enclosing the session root at creation instead)
 and shut down — closing every open context — on the explicit async `stop()`
  (forwarded from `FileContext.stop()`, which the session owner calls before releasing
  the context). Teardown is deliberately explicit, not tied to `deinit`: a synchronous
  `deinit` cannot `await` the async shutdown without leaking an unstructured task.

- After a committed `write file` / `edit file` of a diagnosable file (extension mapped to an
  LSP-backed `Languages.all` module — Swift via `sourcekit-lsp`, Rust, Python, TypeScript, Go,
  … — minus the LSP-less formats), the bridge resolves the file's context via
  `manager.context(containing: path, openIfNeeded: true)` (longest-prefix match on open roots,
  else git-root discovery + open/start) and calls
  `context.diagnostics(scope: .file(path), severity: .warning, includeDependents: true,
  settleWindow:, hardTimeout:, perReportCap:)`, waiting for the settle engine (300 ms
  quiescence, 5 s hard timeout by default; all three injectable on the bridge).
- The result is folded into the op output as:

```swift
struct FileDiagnostics: Encodable {
    let status: String            // clean | errors | warnings | pending | skipped
    let errors: Int
    let warnings: Int
    let items: [DiagnosticItem]   // {file, line, column, severity, message, code?}, capped
    let note: String?             // "the language server is still warming up — re-check…"
}
```

- `clean` is stated explicitly (an *edit-was-OK* signal the model can trust), `errors`
  carries the actual compiler messages with one-based line/column so the model can fix them
  with the very next `edit file`, `pending` is honest about a not-yet-settled server (never
  blocks the mutation — the write/edit has already succeeded), and `skipped` marks a file
  that ran no diagnostics pass at all.
- `includeDependents: true` means an edit that breaks *another* file (changed a signature its
  caller uses) surfaces that breakage too — CodeContext folds broken one-hop dependents in.

**Gates, before any resolution or manager creation.** A non-diagnosable extension (Markdown,
JSON, YAML, …) is `skipped` without the manager ever being created. A filename containing a
glob metacharacter (`*`, `?`, `[`) is `skipped` with a note — upstream treats a `.file` scope
containing one as a glob, which can silently resolve to zero targets and read as a false
`clean`. A file inside no git workspace (`context(containing:)` returns `nil`) is `skipped`
with "not inside a git workspace — no diagnostics pass".

**Path rebase.** A `DiagnosticRecord.path` is relative to the *resolved context's* root; the
bridge joins it onto `context.rootDirectory` (public `nonisolated` upstream) to recover the
absolute path, then relativizes against `FileContext.root`, so every `items[].file` is
session-root-relative and can be fed straight back into `edit file`.

**True counts under a cap.** Upstream truncates a report's `records` to `perReportCap` *before*
deriving its `counts`, so the bridge passes a deliberately large `perReportCap` (10_000) and
applies its own smaller documented item cap only when building `items` — `errors` / `warnings`
stay true even when `items` is truncated. (A run above 10_000 records is a residual upstream
limit, far above any realistic single-file count.)

**Error degradation never gates.** The mutation is already committed. A manager/open failure
(including `CodeContextError.overlappingRoot`), a `start()` failure, or any diagnostics error
degrades to `status: "pending"` + note; the op never fails because of the bridge.

**Nested-repo semantics (documented behavior).** Nearest-open-ancestor wins: once an outer
repository's context is open, files in a nested repository or submodule route to the outer
context by longest-prefix match. Conversely, if an inner repository opened first, a later
attempt to open the outer root throws `overlappingRoot` and degrades to `pending`.

**Diagnostics seam (test hermeticity).** The bridge dispatches against an internal
`protocol DiagnosticsResolving: Sendable`, whose one resolve-then-diagnose method returns a
FileTool-owned value type (records + true counts + resolved context root) or `nil` for "no
covering workspace". The production conformance owns the real `CodeContextManager` and maps
the upstream `DiagnosticsReport` into that value type; unit tests inject a fake keyed by path
prefix, so `DiagnosticsBridgeTests` never spawns a language server, never creates a manager,
and never touches the filesystem. Real-LSP / real-manager behavior lives in the
isolated-directory integration suites. The seam returns a FileTool-owned type deliberately: a
plain-import sibling cannot construct a `DiagnosticsReport` (its initializer is `internal` and
the dependency is not built for testing), so a fake could not otherwise produce one.

**Upstream prerequisites (now satisfied, pinned at `91e2b00`):** `DiagnosticsReport`'s
`records` / `counts` / `pending` members, the `DiagnosticRecord` type, and
`CodeContext.rootDirectory` (`public nonisolated`) are public, and `CodeContextManager` is
available — all reachable from a sibling package with a plain `import`.

**Embedding, non-blocking:** `CodeContext.init` requires a `TextEmbedding` and `start()`
reconciles the full search index — heavier than a diagnostics-only consumer needs. We start
with a `NullEmbedder` (dimension 1, zero vectors; the seam is the public `TextEmbedding`
protocol) and a diagnostics-only start mode remains a proposed upstream follow-up. Neither
blocks this package.

## 5. How it reaches a session

```swift
let context = FileContext(
    root: URL(filePath: workspacePath),        // session root; PathGuard boundary
    diagnostics: .enabled                      // .disabled for a pure file tool
)
let filesTool = try FileTool.make(context: context)   // OperationTool<FileContext>

let session = LanguageModelSession(
    tools: [filesTool],
    instructions: "…use files for all file work; after write/edit, check the diagnostics field and fix any errors before moving on…"
)
```

Five ops sits comfortably inside upstream's 5–15 op guidance for one fused tool. The `--chat`
example measures the rendered schema with `tokenCount(for:)` and exercises the canonical
loops: *read (anchors) → edit by anchor → diagnostics clean*, and *edit → diagnostics report a
type error → model reads the message → follow-up edit fixes it* — the workflow the tool
exists for. A `readOnly` factory variant (`FileTool.makeReadOnly`) fuses only
read/glob/grep, porting the Rust `FileOperationSubset::ReadOnly` surface for
validator/inspector sessions.

## 6. Resolved decisions

1. **Build on `FoundationModelsOperations`** — inherit schema fusion, resolver,
   return-don't-throw + retry cap, `includesSchemaInInstructions`, CLI driver. Five
   `@Operation` structs; no manual path.
2. **Op strings match sah exactly** (`read file`, `write file`, `edit file`, `glob files`,
   `grep files`); missing `op` uses the key-inference hook with the Rust precedence order.
3. **Typed `Encodable` outputs, not preformatted text** (§8.1) — but the `#hash:` token and
   `N:HH|` anchor strings survive inside the JSON verbatim.
4. **Hashline ported exactly** (format *and* hash algorithm) — anchors are one dialect across
   Rust and Swift.
5. **Diagnostics are output enrichment, never a gate** — a mutation that commits always
   reports success; errors ride alongside. Matches the Rust chokepoint semantics and keeps
   the tool honest when the LSP is cold (`pending`).
6. **Upstream visibility PR** for `DiagnosticsReport` members (§4); live-state fallback
   recorded.
7. **macOS 27+ only** — the CodeContext floor wins over Shelltool's 26.
8. **`.gitignore` via the `git` CLI** (`git ls-files --cached --others --exclude-standard`)
   when a repo is present, plain walk otherwise — CodeContext set the precedent; no walker
   dependency.
9. **No rate limiting, no MCP log notifications, single (wire-equivalent) schema** — MCP
   multi-client artifacts with no analogue in an on-device single-session tool (§8.3).
10. **No tolerant string-int parsing** — guided generation constrains the model to declared
    integer types; ArgumentParser types the CLI path (same rationale as Shelltool §8.2).
11. **Write stays an unconditional clobber** — parity; lost-update protection lives in
    anchored edits, and the write envelope's tagged content keeps chains read-free.
12. **mtime not preserved on edit** — parity, and load-bearing: sourcekit-lsp/watchers must
    see the change for §4 to work at all.
13. **10 MiB write cap, 10k glob cap, 1M/100k offset/limit bounds, ±50 anchor window, 2-line
    grep context** — the Rust numbers, unchanged.

## 7. Examples (`./Examples`)

Mirrors the sibling `shell-demo` shape: one thin executable target (`file-demo`) in the root
`Package.swift`, three modes:

- **default — CLI** (`file-demo file read --path … --offset 60`, `file-demo files glob
  --pattern 'Sources/**/*.swift'`, …) over a real workspace; grammar `<noun> <verb>` from the
  stock `OperationCLIDriver`.
- **`--chat`** — a `LanguageModelSession` with the fused tool (availability-gated). Scripted
  prompts drive the full loops: read a file → edit by anchor → see `diagnostics: clean`;
  deliberately ask for an edit that breaks a type → model sees the compiler error in the tool
  result → prompts nudge it to fix it. Reports op-call accuracy, rendered schema size via
  `tokenCount(for:)`, and retry-cap behavior on a denied path (`../../etc/passwd` →
  corrective → model corrects).
- **`--script`** — reads op lines from stdin and executes them sequentially in one process;
  doubles as the human-driven twin of the integration tests.

## 8. Departures from the Rust design (recorded, DESIGN_NOTES-style)

1. **Typed JSON outputs instead of text blocks + structured-content envelope.** Upstream
   `AnyOperation` JSON-encodes every output; the Rust tool's dual surface (text block +
   `structured_content.mutation`) collapses into one typed struct carrying the same fields
   (`bytesWritten`, `taggedContent`, `hash`, …).
2. **Diagnostics via direct CodeContext calls, not a mutated-paths side-channel.** Rust
   records mutated paths in `ToolContext` and a chokepoint folds diagnostics in later; here
   the op awaits the diagnostics pass itself and embeds the result. Same contract
   (mutation-then-check, never a gate), simpler topology — there is no multi-tool chokepoint
   to share.
3. **No rate limiting.** The Rust limiter (per-client buckets, expensive-op classes) guards a
   multi-client MCP server; this package has exactly one caller — the session. Dropped whole.
4. **No MCP log notifications; one schema.** No MCP layer; the wire-vs-full schema split
   (slim for models, annotated for CLI) is superseded by upstream's single fused schema +
   ArgumentParser help.
5. **No tolerant string-number parsing** — guided generation + typed CLI make the
   stringified-int client class impossible here.
6. **`type` filter as a plain string enum-ish parameter** (`rust`, `py`, `swift`, `ts`, …)
   with the mapping table ported; unknown types → corrective listing known ones (Rust
   silently matched nothing).
7. **Windows path-attack patterns not ported** (`..\\`, drive-letter checks) — macOS-only
   package; the Unix traversal/symlink/boundary suite ports whole.
8. **Free upgrades from upstream, absent in Rust `files`:** op/verb aliases and key-case
   normalization for *every* parameter, corrective-message retry cap, and
   `includesSchemaInInstructions` control.

## 9. Risks & verification points

1. **`DiagnosticsReport` visibility upstream** (§4) — the only external blocker. Verified
   first (task 2 is tiny and lands before the bridge); the public
   `CodeContextState.diagnostics` fallback keeps the package unblocked regardless.
2. **sourcekit-lsp latency vs. the 5 s hard timeout** — first diagnostics on a cold workspace
   can exceed it, surfacing `pending`. Mitigations: the bridge starts CodeContext at
   `FileContext` creation (warm-up overlaps the model's first turns), and `pending` results
   carry a re-check note. Pinned by an integration test that polls to `settled` on a real
   package.
3. **Anchor-algorithm fidelity** — the 2-hex line hash must match the Rust crate bit-for-bit
   or cross-tool anchors die silently. Pinned by golden-vector tests generated from the Rust
   implementation (checked-in fixtures).
4. **Recovery-ladder scope creep** — `swissarmyhammer-edit-match` is subtle; port the rungs
   with table-driven parity fixtures (drift, re-indent, CRLF-normalized) rather than
   reinventing heuristics.
5. **Diagnostics on big real repos** — full CodeContext `start()` indexes the workspace
   (embedder + tree-sitter). `NullEmbedder` keeps it cheap; if start cost still dominates,
   the diagnostics-only upstream mode (§4) is the escape hatch. Measured in the integration
   tier.
6. **Toolchain** — Xcode 27 / macOS 27 SDK; live-model runs need Apple Intelligence, and the
   integration tier needs `sourcekit-lsp` on PATH (any Xcode). CI: build + unit tier + LSP
   integration tier on macOS 27 runners; live-model runs manual (same split as the siblings).

## 10. Tasks

Ordering is a dependency graph; each task is independently verifiable with `swift test`.

### 1. Package scaffolding
**What:** `git init`; `Package.swift` (tools 6.2, macOS 27, deps: `FoundationModelsOperationTool`
branch `main`, `FoundationModelsCodeContext` branch `main`), targets per §3 layout, CI
workflow (`swift build && swift test`, macOS 27 runner), `.gitignore`.
**Accept:** builds; placeholder test passes in both test targets.

### 2. Upstream: `DiagnosticsReport` visibility PR
**What:** In `../FoundationModelsCodeContext`: make `DiagnosticsReport.records/counts/pending`,
`DiagnosticRecord`, and `Counts` public (public init not required); DocC note that the report
is a sibling-consumable value.
**Accept:** its own test suite green; a scratch downstream target can read
`report.records.map(\.message)` without `@testable`.
**Depends on:** nothing (can run first; unblocks 8).

### 3. `Hashline` module
**What:** `tag`, `wholeFileHash`, `resolveAnchor` (±50 proximity, `|text` verify/relocate),
anchor parsing — algorithm-exact port.
**Tests:** golden vectors generated from the Rust crate (fixture file checked in); drift
resolution at ±1/±50/±51; stale-anchor fall-through; `|text` relocation; token stability.
**Depends on:** 1.

### 4. `PathGuard` + `FileContext`
**What:** the §3 validation stack; `FileContext` (session root, guard, lazy
`DiagnosticsBridge` handle, `readOnly` flag).
**Tests:** table-driven — traversal exemplars (`../../../etc/passwd` and friends), symlink
rejection before canonicalize + `allowSymlinks` opt-in, workspace boundary incl. nonexistent
targets via deepest-existing-parent, root-walk refusal (`/`, `.`, empty), length/null/control
rejects, per-op permission checks, session-root (never CWD) relative resolution.
**Depends on:** 1.

### 5. `read file` + `AtomicWriter` + `write file`
**What:** read pipeline (validate → UTF-8-or-reject → window → tag → `#hash:` token);
`AtomicWriter` (temp+rename same-dir, cleanup-on-any-failure, parent creation, permission
re-application); write pipeline (10 MiB cap, envelope with tagged content), no diagnostics
wiring yet (bridge lands in 8).
**Tests:** offset/limit/both/bounds; anchors absolute under windowing; binary rejection both
formats; token = full-file regardless of window; new/overwrite/parents; readonly failure;
cleanup on write- and rename-failure (target-is-dir); no temp files remain; write-envelope
anchor resolves in a chained edit with no intervening read (once 6 lands).
**Depends on:** 3, 4.

### 6. `EditEngine` + `edit file`
**What:** shape normalization (scalar / arrays / `edits[]`, N+1 broadcast, mismatch
corrective), the cascade (anchor → literal → recovery ladder), ambiguity/near-miss/
already-applied/consumed-target outcomes + reclassification, `occurrence`, `replaceAll`
global-literal path, no-op rejection, in-memory batch + single atomic commit via
`AtomicWriter` with encoding (BOM-aware) and line-ending (LF/CRLF/CR/Mixed) preservation.
**Tests:** parity fixtures per rung; competing anchor+literal → candidates; ambiguity lists
1-based occurrences with ±2 context; near-miss carries a line diff; already-applied and
consumed-target in batches; broadcast delete; CRLF and BOM byte-identical round-trips
(except the edited range); executable bit preserved; failure leaves the file byte-identical.
**Depends on:** 3, 4, 5.

### 7. `GlobEngine` / `GrepEngine` + their ops
**What:** git-CLI-backed ignore-aware walk (fallback plain walk), broad-pattern guard
(unscoped `*`/`**/*`/`*.*`/bare `**/*.ext` → corrective; allowed when `path` given), mtime
sort + 10k cap + `capped` flag; grep line matcher (Swift `Regex`, `(?i)` for
`caseInsensitive`, invalid pattern → corrective), `glob`/`type` filters, null-byte binary
skip, context assembly with hunk dividers, three output modes.
**Tests:** gitignored files excluded (real `.gitignore` in temp repo) and included with
`respectGitIgnore: false`; non-repo fallback; broad-pattern matrix; mtime order; cap honesty;
regex/count/files modes; context 0/2/N; type/glob filters; single-file path; nonexistent path
corrective.
**Depends on:** 4.

### 8. `DiagnosticsBridge`
**What:** lazy CodeContext lifecycle (`NullEmbedder`, start on first diagnosable mutation,
stop with context), diagnosable-extension gate, `diagnostics(scope: .file)` call with
defaults, `FileDiagnostics` mapping (clean/errors/warnings/pending/skipped, item cap, notes),
wiring into `WriteResult`/`EditResult`.
**Tests:** unit tier against a fake (mapping, severity floor, cap, pending, skipped for
`.md`); the real-LSP behavior is task 10's job.
**Depends on:** 2, 5, 6.

### 9. Fusion, inference hook, CLI
**What:** `FileTool.make()` / `.makeReadOnly()` (read/glob/grep only; write/edit → corrective
"read-only"), the missing-`op` key-inference hook with Rust precedence, alias declarations
(`old_string` et al.), `OperationCLIDriver` wiring in the example executable.
**Tests:** dispatch through `AnyOperation` for each op; snake_case payload parity
(`file_path`, `replace_all`, `case_insensitive`); native-Edit-dialect payload
(`old_string`/`new_string`) lands as an edit; inference matrix (every branch + undeterminable
→ corrective naming five ops); read-only rejections; argv → payload equals model-path payload
for every op (upstream's convergence contract); help snapshots.
**Depends on:** 5, 6, 7, 8.

### 10. Isolated-directory integration tests (the package's proof)
**What:** `FileToolIntegrationTests` — every test in a fresh temp workspace
(`withIsolatedWorkspace`), the diagnostics suites in a scaffolded *compiling* Swift package
(`withIsolatedSwiftPackage`: generated `Package.swift` + sources, `git init` + commit) over a
**real CodeContext with a real `sourcekit-lsp`**, gated on `xcrun --find sourcekit-lsp`
(skip with a clear message otherwise). Real edits, real errors, through full op dispatch:
- **Error-detection paths:** edit introduces a syntax error (unbalanced brace) → `errors` with
  the real message+line; edit introduces a type error (`let x: Int = "s"`) → detected; write
  a new file with an unresolved identifier → detected; warning-only edit (unused variable) →
  `warnings`, zero errors; severity floor honored; edit breaks a *dependent* file (change a
  signature its caller uses) → dependent's error folded in; cold-start `pending` path (tiny
  `hardTimeout`) → honest `pending` + note, mutation still committed; item cap on an
  error-storm file.
- **Edit-was-OK paths:** clean write → `clean`; anchor edit, literal edit, recovered
  (drifted) edit, `replaceAll`, `occurrence`-disambiguated edit, multi-pair batch — each
  committing and reporting `clean`; error-then-fix round trip (edit breaks → diagnostics show
  it → second edit repairs → `clean`); non-diagnosable file (`README.md`, `.json`) →
  `skipped`, no LSP touched; read-only tool never triggers the bridge.
- **Cross-op flows in isolation:** write → read (anchors) → edit-by-anchor → diagnostics;
  glob → grep → edit; gitignore end-to-end (ignored file invisible to glob/grep but readable
  by path); concurrency smoke (parallel reads during an edit; edits to distinct files).
**Accept:** suite green locally and on the macOS 27 CI runner; wall-clock budget documented
(one shared warm CodeContext per suite, not per test).
**Depends on:** 9.

### 11. Example: `file-demo` (CLI / `--chat` / `--script`)
**What:** the §7 executable; scripted chat harness (availability-gated) validating the
read→anchor-edit→clean loop, the break→see-error→fix loop, the denied-path corrective, and
schema token cost; `--script` sequential mode.
**Tests:** integration tests driving every op through `AnyOperation` and the CLI; the
live-model path is manual-run but scripted (`swift run file-demo --chat`).
**Depends on:** 9, 10.

### 12. Docs
**What:** README (declare → fuse → session → CLI, library-style with a runnable example,
diagnostics loop front and center), DocC comments on public API, §8's departures
cross-referenced, upstream-PR note.
**Accept:** README snippets doc-snippet-tested against the example source (the siblings'
mechanism).
**Depends on:** 11.

## 11. Testing

Three tiers, mirroring the siblings but with the middle tier promoted — it is this package's
reason to exist:

- **Unit tier** — hermetic and GPU-free: hashline golden vectors, EditEngine parity fixtures,
  PathGuard tables, AtomicWriter failure-path cleanup, engines against temp dirs, dispatch
  through the real fused tool with a temp-dir context, bridge mapping against a fake. No
  mocks of our own layers; the only faked boundary is the LSP connection (CodeContext's own
  test seam).
- **Isolated-directory integration tier** (task 10) — real temp workspaces and a real
  scaffolded Swift package with a live `sourcekit-lsp`: every diagnostics path (syntax error,
  type error, unresolved identifier, warning-only, dependent breakage, pending, skipped,
  error-storm cap) and every edits-OK path (each cascade rung, batch, fix-after-break,
  non-diagnosable, read-only) exercised end to end through op dispatch, with byte-level
  assertions on encoding/line-ending/permission preservation. Availability-gated on
  `sourcekit-lsp`; runs in CI.
- **Live-model tier** (manual, availability-gated) — the `--chat` harness (§7): does the
  model actually read the `diagnostics` field, quote the compiler error, and fix it? Same
  pattern as the siblings' chat validation harnesses.

---

### Sources
- Rust reference: `../swissarmyhammer` — `crates/swissarmyhammer-tools/src/mcp/tools/files/`
  (ops, dispatch, shared_utils security stack, per-op `description.md` contracts),
  `swissarmyhammer-hashline`, `swissarmyhammer-edit-match`,
  `tests/integration/file_tools_integrations.rs` (isolated-env test patterns)
- FoundationModelsCodeContext — `Sources/FoundationModelsCodeContext/CodeContext.swift`
  (`diagnostics(scope:)`), `Diagnostics/` (scope, records, settle engine),
  `LSP/LSPTypes.swift` (public `Diagnostic`/`DiagnosticSeverity`/`LSPRange`/`Position`),
  `CodeContextState.swift` (public live diagnostics), plan.md (conventions: os.Logger,
  actor topology, `Codable & Sendable` results, no-extra-deps policy)
- FoundationModelsShelltool plan (structure + Operations-pattern conventions this plan
  mirrors) — ../FoundationModelsShelltool/plan.md
- FoundationModelsOperationTool (upstream pattern: schema fusion, resolver, corrective
  errors, CLI driver) — https://github.com/swissarmyhammer/FoundationModelsOperationTool
- What's new in Foundation Models (WWDC26) — https://developer.apple.com/videos/play/wwdc2026/241/
