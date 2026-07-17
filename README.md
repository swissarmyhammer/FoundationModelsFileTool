# FoundationModelsFileTool

[![CI](https://github.com/swissarmyhammer/FoundationModelsFileTool/actions/workflows/ci.yml/badge.svg)](https://github.com/swissarmyhammer/FoundationModelsFileTool/actions/workflows/ci.yml)
[![Swift 6.2](https://img.shields.io/badge/Swift-6.2-orange.svg)](https://swift.org)
[![platform macOS 27](https://img.shields.io/badge/platform-macOS%2027-blue.svg)](https://developer.apple.com/macos/)

A single `files` tool for Apple FoundationModels sessions: read, write, edit,
glob, and grep, fused into one operation with **live compiler diagnostics folded
into every write and edit**. The model edits a file, sees the compiler's errors
in the same tool result, and fixes them on the next turn — the diagnostics loop a
coding agent lives in, without leaving the session.

```swift
import FileTool
import FoundationModels

// Root the session at a workspace. PathGuard bounds every op to `root`;
// eagerWarmup starts the diagnostics engine so the first edit's errors
// come back without a cold-start wait.
let context = FileContext(root: sessionRoot, eagerWarmup: true)

// Fuse read / write / edit / glob / grep into one `files` tool.
let tool = try FileTool.make(context: context)

// Register it on a session. After each write or edit the model reads the
// result's `diagnostics` field and fixes any errors before moving on.
let session = LanguageModelSession(
    tools: [tool],
    instructions: "Use the files tool for all file work. After a write or \
        edit, read the diagnostics field and fix any reported errors."
)
_ = try await session.respond(to: "Read Sources/App/main.swift and show its anchors.")

await context.stop()  // close every language server the diagnostics bridge opened
```

`FileContext(root:)` builds the session state (the `root`, its `PathGuard`
boundary, and the diagnostics bridge); `FileTool.make(context:)` returns an
`OperationTool` you register like any other FoundationModels tool. After a
committed write or edit, the tool folds the covering compiler's diagnostics into
the op's output as a `diagnostics` field (`clean` / `errors` / `warnings` /
`pending` / `skipped`) — including breakage in one-hop dependents — so a model can
feed errors straight into its next edit. The session `root` may sit above several
independent git repositories; diagnostics resolve the covering repository per
mutated file, so one session spans a whole multi-project tree.

It is a Swift port of the Rust `swissarmyhammer` `files` tool, built on
[`FoundationModelsOperationTool`](https://github.com/swissarmyhammer/FoundationModelsOperationTool)
(the `@Operation` macro, schema fusion, and the ArgumentParser CLI driver) and
[`FoundationModelsCodeContext`](https://github.com/swissarmyhammer/FoundationModelsCodeContext)
(the `sourcekit-lsp`-backed diagnostics engine).

## Install

Add the package and depend on the `FileTool` product. macOS 27 only — the
diagnostics engine needs the FoundationModels v2 / LSP level and spawns
`sourcekit-lsp`, so there is no iOS story.

```swift
.package(url: "https://github.com/swissarmyhammer/FoundationModelsFileTool.git", branch: "main"),
```

```swift
.target(name: "YourTool", dependencies: [
    .product(name: "FileTool", package: "FoundationModelsFileTool"),
]),
```

## Documentation

- [Guide](docs/GUIDE.md) — the diagnostics loop in depth, the five operations,
  write→edit anchor chaining, read-only sessions, and the `file-demo` CLI.
- [Design notes](DESIGN_NOTES.md) — departures from the Rust design and the
  nested-repo diagnostics semantics.

## License

No license file is currently present in this repository.
