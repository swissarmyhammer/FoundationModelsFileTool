# FoundationModelsFileTool

[![CI](https://github.com/swissarmyhammer/FoundationModelsFileTool/actions/workflows/ci.yml/badge.svg)](https://github.com/swissarmyhammer/FoundationModelsFileTool/actions/workflows/ci.yml)
[![Swift 6.2](https://img.shields.io/badge/Swift-6.2-orange.svg)](https://swift.org)
[![platform macOS 27](https://img.shields.io/badge/platform-macOS%2027-blue.svg)](https://developer.apple.com/macos/)

A single `files` tool for Apple `FoundationModels` sessions: read, write, edit,
glob, and grep, fused into one operation with **live compiler diagnostics folded
into every write and edit**. The model edits a file, sees the compiler's errors
in the same tool result, and fixes them on the next turn — the diagnostics loop a
coding agent lives in, without leaving the session.

It is a Swift port of the Rust `swissarmyhammer` `files` tool, built on the
sibling [`FoundationModelsOperationTool`](https://github.com/swissarmyhammer/FoundationModelsOperationTool)
(the `@Operation` macro, schema fusion, and the ArgumentParser CLI driver) and
[`FoundationModelsCodeContext`](https://github.com/swissarmyhammer/FoundationModelsCodeContext)
(the `sourcekit-lsp`-backed diagnostics engine).

## Usage

Declare a session context, fuse the five operations into one tool, register it on
a `LanguageModelSession`, and tear it down when the session ends:

<!-- doc-snippet source="Examples/FileDemo/Sources/file-demo/ReadmeExample.swift" -->
```swift
static func fuseAndServe(sessionRoot: URL) async throws {
    // Declare a session context rooted at the workspace. PathGuard bounds
    // every operation to `root`; `eagerWarmup` starts the diagnostics engine
    // for the enclosing project now, so the first edit's errors come back
    // without a cold-start wait.
    let context = FileContext(root: sessionRoot, eagerWarmup: true)

    // Fuse the five operations (read / write / edit / glob / grep) into one
    // `files` tool.
    let tool = try FileTool.make(context: context)

    // Register the fused tool on a session. The instructions turn on the
    // diagnostics loop: after every write or edit the model reads the
    // result's `diagnostics` field and fixes any errors before moving on.
    let session = LanguageModelSession(
        tools: [tool],
        instructions: """
            Use the files tool for all file work. After a write or edit, read \
            the diagnostics field and fix any reported errors before continuing.
            """
    )
    _ = try await session.respond(to: "Read Sources/App/main.swift and show its hashline anchors.")

    // Tear the session down: close every language server the diagnostics
    // bridge opened. A session owner calls this before releasing the context.
    await context.stop()
}
```
<!-- /doc-snippet -->

That is the whole integration: `FileContext(root:)` builds the session state (the
`root`, its `PathGuard` boundary, and the diagnostics bridge handle), and
`FileTool.make(context:)` returns an `OperationTool` you register like any other
`FoundationModels` tool. `FileContext.stop()` is the session's explicit teardown
— it closes every language server the diagnostics bridge opened, and is a no-op
if none was ever started.

## The diagnostics loop (edit → see compiler errors → fix)

This is why the package exists. After a *committed* `write file` or `edit file`
of a source file, the tool asks the covering `CodeContext` for the file's
diagnostics — waiting briefly for the language server to settle — and folds the
result into the op's output as a `diagnostics` field:

<!-- doc-snippet source="Sources/FileTool/FileDiagnostics.swift" -->
```swift
public struct FileDiagnostics: Encodable, Sendable {
    /// The whole-result status: `clean`, `errors`, `warnings`, `pending`, or `skipped`.
    public let status: String

    /// The number of error-severity diagnostics across the resolved records.
    public let errors: Int

    /// The number of warning-severity diagnostics across the resolved records.
    public let warnings: Int

    /// The per-diagnostic detail, capped to the bridge's item limit.
    public let items: [DiagnosticItem]

    /// A human-readable note explaining a `pending` or `skipped` status, or `nil` for `clean` / `errors` / `warnings`.
    public let note: String?
```
<!-- /doc-snippet -->

The mutation is *never gated* on diagnostics — the write or edit has already
committed. `status` names the outcome:

- **`clean`** — the file (and its one-hop dependents) compiled with no errors or
  warnings. An *edit-was-OK* signal the model can trust.
- **`errors`** / **`warnings`** — the mutation left problems. Each `items` entry
  carries `file` (relative to the session root), one-based `line` / `column`,
  `severity`, `message`, and an optional `code`, so the model can feed them
  straight into the next `edit file` with no intervening read.
- **`pending`** — the language server had not settled before the hard timeout (5 s
  by default). The `note` says to re-check; the mutation still committed.
- **`skipped`** — no diagnostics pass ran: a non-source extension (Markdown, JSON,
  …), a path with a glob metacharacter, or a file outside any git workspace.

So a type-breaking edit comes back like this, and the model fixes it on the next
turn:

```json
{
  "bytesWritten": 42,
  "diagnostics": {
    "status": "errors",
    "errors": 1,
    "warnings": 0,
    "items": [
      { "file": "Sources/App/Value.swift", "line": 2, "column": 12,
        "severity": "error", "message": "cannot convert return expression of type 'String' to return type 'Int'" }
    ],
    "note": null
  }
}
```

An edit that breaks a *different* file (changing a signature its caller depends
on) surfaces that breakage too — broken one-hop dependents are folded in.

### Multi-project workspaces

The session `root` may sit *above* several independent git repositories. The
diagnostics bridge resolves the covering repository per mutated file, so one
session spans a whole multi-project tree with no per-repo wiring:

<!-- doc-snippet source="Examples/FileDemo/Sources/file-demo/ReadmeExample.swift" -->
```swift
static func multiProjectSession(workspaceAboveRepos: URL) -> FileContext {
    // `root` sits above several independent git repositories. The diagnostics
    // bridge resolves the covering repository per mutated file — an edit in
    // repo-a is checked by repo-a's language server, an edit in repo-b by
    // repo-b's — automatically, by nearest-open-ancestor: no per-repo wiring.
    FileContext(root: workspaceAboveRepos)
}
```
<!-- /doc-snippet -->

Routing is **nearest-open-ancestor-wins**: once a repository's context is open,
files in a nested repository or submodule route to the nearest open ancestor by
longest-prefix match. The overlap edge case (an inner repository opening before
its outer root) degrades that file to `pending` rather than failing the edit. See
[`DESIGN_NOTES.md`](DESIGN_NOTES.md) for the full nested-repo semantics.

## The five operations

| Op | What it does |
|----|--------------|
| `read file` | Read a window of a file, tagged with two-hex **hashline anchors** per line. |
| `write file` | Write a file atomically, preserving encoding and line endings; returns hashline-tagged content. |
| `edit file` | Rewrite by a batch of find/replace pairs, committed atomically. |
| `glob files` | Find files matching a glob, newest first, git-aware. |
| `grep files` | Search file contents by regular expression, git-aware, shaped by output mode. |

### Write → edit anchor chaining

`read file` and `write file` return each line prefixed with a stable
two-hex-digit hashline anchor. An `edit file` can then target a line by that
anchor instead of re-quoting its text — the write's output feeds the next edit
directly. `edit file` takes parallel `find` / `replace` arrays (one pair, or a
batch), with `replacesAll` to rewrite every occurrence and `occurrence` to
disambiguate among literal matches. Driven through `--script` mode as JSON op
lines:

```json
{"op": "write file", "filePath": "notes.txt", "content": "alpha\nbeta\ngamma\n"}
{"op": "edit file", "filePath": "notes.txt", "find": ["beta"], "replace": ["BETA"]}
{"op": "read file", "filePath": "notes.txt", "format": "plain"}
```

### Read-only sessions

For a validator or inspector session, `FileTool.makeReadOnly(context:)` fuses
read / glob / grep for real and stubs write / edit to return a corrective without
touching disk — the Rust `FileOperationSubset::ReadOnly` surface:

<!-- doc-snippet source="Examples/FileDemo/Sources/file-demo/ReadmeExample.swift" -->
```swift
static func readOnlyTool(sessionRoot: URL) throws -> OperationTool<FileContext> {
    let context = FileContext(root: sessionRoot)
    return try FileTool.makeReadOnly(context: context)
}
```
<!-- /doc-snippet -->

## The `file-demo` CLI

The `file-demo` example executable exercises the fused tool in three modes,
selected by the first argument:

<!-- doc-snippet source="Examples/FileDemo/Sources/file-demo/main.swift" -->
```swift
let arguments = Array(CommandLine.arguments.dropFirst())
let context = FileContext(root: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))

switch arguments.first {
case FileToolCLI.scriptModeFlag:
    await runScriptMode(context: context)
case FileToolCLI.chatModeFlag:
    // Chat mode scaffolds its own throwaway workspace, so it never mutates the
    // caller's working directory (unlike the CLI/script modes, which act on it).
    await ChatValidationHarness.run()
default:
    await runCLIMode(arguments: arguments, context: context)
}
```
<!-- /doc-snippet -->

**Default — CLI.** The stock `<noun> <verb>` grammar over the current directory.
`read` uses `--path`; `write` and `edit` use `--file-path`; `glob` and `grep`
take `--pattern`:

```sh
file-demo file read  --path Sources/App/main.swift --offset 2
file-demo file write --file-path notes.txt --content "hello\n"
file-demo file edit  --file-path notes.txt --find hello --replace goodbye
file-demo files glob --pattern 'Sources/**/*.swift'
file-demo files grep --pattern 'TODO' --path Sources
```

**`--script`.** Reads JSON op lines from stdin and executes them sequentially in
one process against the working directory — the human-driven twin of the
integration tests:

```sh
printf '%s\n' \
  '{"op":"read file","filePath":"notes.txt","format":"plain"}' \
  '{"op":"edit file","filePath":"notes.txt","find":["beta"],"replace":["BETA"]}' \
  | file-demo --script
```

**`--chat`.** A live `LanguageModelSession` with the fused tool
(availability-gated: it skips cleanly on a machine without Apple Intelligence).
It scaffolds a throwaway Swift package and walks the real read → edit-by-anchor →
`clean` loop, then a deliberate type-breaking edit → see the compiler error → fix
loop, reporting op-call accuracy and the rendered schema's token cost.

```sh
swift run file-demo --chat
```

## Install

Add the package to your `Package.swift` dependencies and depend on the `FileTool`
product:

```swift
.package(url: "https://github.com/swissarmyhammer/FoundationModelsFileTool.git", branch: "main"),
```

```swift
.target(name: "YourTool", dependencies: [
    .product(name: "FileTool", package: "FoundationModelsFileTool"),
]),
```

macOS 27 only: the diagnostics engine needs the FoundationModels v2 / LSP level
and spawns `sourcekit-lsp`, so there is no iOS story.

## Design notes

[`DESIGN_NOTES.md`](DESIGN_NOTES.md) records this package's departures from the
Rust design (cross-referenced to `plan.md` §8), the nested-repo diagnostics
semantics, and the upstream `FoundationModelsCodeContext` changes it builds on.

## License

No license file is currently present in this repository.
