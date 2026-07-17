import FileTool
import Foundation
import FoundationModels
import Operations

/// A compiled, citable companion to the repository `README.md`.
///
/// Every Swift code fence in the README is a contiguous excerpt of one of the
/// functions below, so `ReadmeSnippetTests` can prove the README's declare →
/// fuse → session walkthrough genuinely compiles and never rots: change the
/// public API and these functions stop compiling; change them without updating
/// the README and the snippet test fails on the stale fence.
///
/// None of these functions is invoked at runtime — they exist to be compiled
/// against the real `FileTool` surface and quoted by the README. Constructing a
/// `LanguageModelSession` compiles everywhere on the macOS 27 SDK; only its
/// `respond(to:)` needs Apple Intelligence, and nothing here is ever called.
enum ReadmeExample {
    /// Declare a session context, fuse the five file operations into one tool,
    /// register it on a `LanguageModelSession`, and tear it down — the library
    /// walkthrough the README's "Usage" section quotes.
    ///
    /// - Parameter sessionRoot: the session working directory; the `PathGuard`
    ///   boundary and relative-path base for every operation.
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

    /// Build the read-only variant for a validator or inspector session.
    ///
    /// - Parameter sessionRoot: the session working directory.
    /// - Returns: a `files` tool whose read / glob / grep are fused for real and
    ///   whose write / edit return a corrective without touching disk.
    static func readOnlyTool(sessionRoot: URL) throws -> OperationTool<FileContext> {
        let context = FileContext(root: sessionRoot)
        return try FileTool.makeReadOnly(context: context)
    }

    /// Build a session context rooted *above* several independent git
    /// repositories, so one session spans a whole multi-project workspace.
    ///
    /// - Parameter workspaceAboveRepos: a directory that contains several git
    ///   repositories as children.
    /// - Returns: a context whose diagnostics bridge resolves the covering
    ///   repository per mutated file.
    static func multiProjectSession(workspaceAboveRepos: URL) -> FileContext {
        // `root` sits above several independent git repositories. The diagnostics
        // bridge resolves the covering repository per mutated file — an edit in
        // repo-a is checked by repo-a's language server, an edit in repo-b by
        // repo-b's — automatically, by nearest-open-ancestor: no per-repo wiring.
        FileContext(root: workspaceAboveRepos)
    }
}
