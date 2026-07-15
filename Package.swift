// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "FoundationModelsFileTool",
    // macOS 27 only: `FoundationModelsCodeContext` (the live edit-diagnostics
    // engine) declares macOS 27 as its floor — the FoundationModels v2 / LSP
    // level it needs — and spawns `sourcekit-lsp` subprocesses. There is no iOS
    // story, so macOS 27 is the sole platform.
    platforms: [
        .macOS("27.0"),
    ],
    products: [
        // Core library: the five file operations, `FileContext`, `PathGuard`,
        // `Hashline`, `EditEngine`, `AtomicWriter`, the glob/grep engines, the
        // `DiagnosticsBridge`, and the typed outputs. Exposed so downstream
        // tools (and the `file-demo` example) can embed the operations
        // directly, mirroring how the upstream package exposes `Operations`.
        .library(name: "FileTool", targets: ["FileTool"]),
    ],
    dependencies: [
        // The `@Operation` macro, schema fusion, `OperationTool` dispatch, and
        // the ArgumentParser CLI driver (`Operations` + `OperationsCLI`
        // products). Private repo, pinned to `main`.
        .package(
            url: "git@github.com:swissarmyhammer/FoundationModelsOperationTool.git",
            branch: "main"
        ),
        // The live diagnostics engine: the `CodeContext` facade and its LSP
        // value types (`Diagnostic`, `DiagnosticSeverity`, `LSPRange`,
        // `Position`), used by the `DiagnosticsBridge` to fold compiler
        // errors/warnings into `write file` / `edit file` output. Pinned to
        // `main`.
        .package(
            url: "git@github.com:swissarmyhammer/FoundationModelsCodeContext.git",
            branch: "main"
        ),
    ],
    targets: [
        // Core library target: the file operations and their supporting
        // runtime. Applying `@Operation` pulls in `Operations`; the
        // `DiagnosticsBridge` consumes `FoundationModelsCodeContext`.
        .target(
            name: "FileTool",
            dependencies: [
                .product(name: "Operations", package: "FoundationModelsOperationTool"),
                .product(name: "FoundationModelsCodeContext", package: "FoundationModelsCodeContext"),
            ]
        ),

        // Example: a `file-demo` executable exercising the file operations
        // through the CLI driver end to end. Kept as a target of the root
        // package (not a nested package), mirroring the sibling packages'
        // layout where the example tools live under `Examples/`.
        .executableTarget(
            name: "file-demo",
            dependencies: [
                "FileTool",
                .product(name: "Operations", package: "FoundationModelsOperationTool"),
                .product(name: "OperationsCLI", package: "FoundationModelsOperationTool"),
            ],
            path: "Examples/FileDemo/Sources/file-demo"
        ),

        // Unit tier: hermetic tests of the library internals. `@testable` so the
        // tests can reach the package-internal runtime types directly.
        .testTarget(
            name: "FileToolTests",
            dependencies: ["FileTool"]
        ),

        // Isolated-directory integration tier: real temp workspaces and a real
        // scaffolded Swift package with a live `sourcekit-lsp`. `@testable` for
        // the same reach into internals.
        .testTarget(
            name: "FileToolIntegrationTests",
            dependencies: ["FileTool"]
        ),
    ]
)
