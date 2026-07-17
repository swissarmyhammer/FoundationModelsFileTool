# Design notes

This package is a Swift port of the Rust `swissarmyhammer` `files` tool, rebuilt
on Apple `FoundationModels` and the sibling `FoundationModelsOperationTool` /
`FoundationModelsCodeContext` packages. Where it diverges from the Rust design,
where its diagnostics routing has non-obvious semantics, and what it needed from
upstream are all recorded here.

## Departures from the Rust design

These cross-reference `plan.md` §8 ("Departures from the Rust design"), items
1–8. Each heading below is the corresponding numbered item.

1. **Typed JSON outputs instead of text blocks + a structured-content envelope**
   (`plan.md` §8.1). Upstream `AnyOperation` JSON-encodes every output, so the
   Rust tool's dual surface (a text block plus `structured_content.mutation`)
   collapses into one typed struct carrying the same fields — `bytesWritten`,
   `taggedContent`, `hash`, and, for a mutation, the folded-in `diagnostics`.

2. **Diagnostics via direct `CodeContext` calls, not a mutated-paths
   side-channel** (`plan.md` §8.2). Rust records mutated paths in a `ToolContext`
   and a later chokepoint folds diagnostics in; here the op awaits the
   diagnostics pass itself and embeds the result (`DiagnosticsBridge.diagnose`).
   Same contract — mutation-then-check, never a gate — with a simpler topology,
   since there is no multi-tool chokepoint to share.

3. **No rate limiting** (`plan.md` §8.3). The Rust limiter (per-client buckets,
   expensive-op classes) guards a multi-client MCP server; this package has
   exactly one caller — the session — so the whole mechanism is dropped.

4. **No MCP log notifications; one schema** (`plan.md` §8.4). There is no MCP
   layer, so the Rust wire-vs-full schema split (slim for models, annotated for
   the CLI) is superseded by upstream's single fused schema plus ArgumentParser
   help.

5. **No tolerant string-number parsing** (`plan.md` §8.5). Guided generation and
   the typed CLI make the stringified-integer client class impossible here, so
   the Rust tolerance code has no counterpart.

6. **`type` filter as a plain string parameter** (`plan.md` §8.6). `grep files`
   takes `type` as a string (`rust`, `py`, `swift`, `ts`, …) with the Rust
   mapping table ported; an unknown type produces a corrective listing the known
   types, where Rust silently matched nothing.

7. **Windows path-attack patterns not ported** (`plan.md` §8.7). This is a
   macOS-only package, so `PathGuard` ports the whole Unix traversal / symlink /
   boundary suite but drops the Rust `..\` and drive-letter checks.

8. **Free upgrades inherited from upstream** (`plan.md` §8.8), absent in the Rust
   `files`: op/verb aliases and key-case normalization for *every* parameter, the
   corrective-message retry cap, and `includesSchemaInInstructions` control — all
   supplied by the `Operations` runtime rather than reimplemented.

## Nested-repo diagnostics semantics

The package is multi-project by design: a `FileContext.root` may sit *above*
several independent git repositories, so `DiagnosticsBridge` wraps one lazily
created `CodeContextManager` (not a single `CodeContext`) and resolves the
covering context *per mutated file* via `manager.context(containing:openIfNeeded:)`.
Two behaviors follow, and are documented here because they are observable:

- **Nearest-open-ancestor-wins.** Resolution is a longest-prefix match over the
  currently open roots. Once an outer repository's context is open, a file in a
  *nested* repository or submodule routes to that outer context — the nearest
  open ancestor — rather than opening the inner repository separately.

- **Overlapping-root degradation to `pending`.** If, conversely, an inner
  repository opened first, a later attempt to open an outer root that encloses it
  throws `CodeContextError.overlappingRoot`. The bridge never fails the op for
  this: the mutation has already committed, so an overlap (like any manager,
  `start()`, or diagnostics error) degrades that file's result to
  `status: "pending"` with a re-check note. Diagnostics are always advisory;
  routing trouble never blocks a write or an edit.

Two gates run *before* any resolution or manager creation, so they cost nothing:
a non-diagnosable extension (Markdown, JSON, YAML, …) is `skipped` without the
manager ever existing, and a path containing a glob metacharacter (`*`, `?`, `[`)
is `skipped` with a note, because upstream would treat such a `.file` scope as a
glob and could silently resolve to zero targets — a false `clean`. A file inside
no git workspace is `skipped` with "not inside a git workspace".

## Upstream changes this package builds on

The diagnostics bridge consumes `FoundationModelsCodeContext` as a plain
(non-`@testable`) sibling import, which required upstream to make the following
surface public. Reachability is pinned by `Tests/FileToolTests/UpstreamVisibilityTests.swift`,
a compile-only probe that fails to build if any of it regresses.

- **`CodeContextManager`** — the multi-project manager the bridge wraps, with a
  public initializer taking only a `TextEmbedding`, and public `context(for:)` /
  `context(containing:openIfNeeded:)` resolution. The manager, not a single
  `CodeContext`, is what makes one session span several repositories.

- **`CodeContext.rootDirectory`** — made `public nonisolated`. The bridge reads
  it synchronously to rebase each `DiagnosticRecord.path` (relative to the
  *resolved* context's root) first to an absolute path and then to a
  session-root-relative one, so every `items[].file` can be fed straight back
  into `edit file`.

- **`DiagnosticsReport` / `DiagnosticRecord` / `Counts`** — their `records`,
  `counts`, and `pending` members are public, so a plain-import consumer can read
  a report obtained from a running context (the initializers remain `internal`,
  which is why the bridge's `DiagnosticsResolving` seam trades in FileTool-owned
  value types a fake can construct).

The bridge starts each context with a `NullEmbedder` (dimension 1, zero vectors)
because `CodeContext.init` requires a `TextEmbedding` and a diagnostics-only
consumer needs no real search index; a diagnostics-only start mode remains a
proposed upstream follow-up that would let the bridge skip index reconciliation
entirely. Neither blocks this package today.
