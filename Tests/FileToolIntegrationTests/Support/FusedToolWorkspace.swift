import Foundation
import Operations

@testable import FileTool

/// Owns the fused-`files`-tool-over-an-isolated-workspace lifecycle both tier-B
/// suites share.
///
/// Every isolated-directory flow that is *not* the warm-context matrix follows
/// the identical scaffolding: stand up a fresh temporary workspace, build a
/// ``FileContext`` over it, construct the fused tool, run the flow, and tear the
/// context down on every exit path (so the real language server is never
/// leaked). That block was hand-rolled once per flow in each suite; it lives
/// here so ``EditsOKTests`` and ``CrossOpFlowTests`` reuse a single
/// implementation instead of re-deriving the same setup/teardown.
///
/// - Note: The fused-tool type stays the fully-qualified
///   `Operations.OperationTool<FileContext>` here rather than the per-file
///   `private typealias FusedFilesTool` each suite keeps (matching suite A's
///   ``ErrorDetectionTests`` convention); the two name the same type, so a
///   suite's own dispatch helpers still accept the tool this yields.
enum FusedToolWorkspace {
    /// Runs `body` against a fused tool over a fresh isolated workspace, tearing
    /// the context down on every exit path.
    ///
    /// - Parameters:
    ///   - name: a human-readable prefix identifying the workspace on disk.
    ///   - readOnly: whether the session forbids mutating operations; a read-only
    ///     session pairs a read-only ``FileContext`` with
    ///     ``FileTool/makeReadOnly(context:)``, otherwise a mutating context with
    ///     ``FileTool/make(context:)``. Defaults to `false`.
    ///   - body: the work to run against the fused tool, its context, and the
    ///     workspace root.
    /// - Throws: rethrows whatever scaffolding, tool construction, or `body` throws.
    static func withFusedTool(
        named name: String,
        readOnly: Bool = false,
        _ body: (OperationTool<FileContext>, FileContext, URL) async throws -> Void
    ) async throws {
        try await IsolatedWorkspace.withIsolatedWorkspace(named: name) { root in
            let context = FileContext(root: root, readOnly: readOnly)
            do {
                let tool = try readOnly
                    ? FileTool.makeReadOnly(context: context)
                    : FileTool.make(context: context)
                try await body(tool, context, root)
            } catch {
                await context.stop()
                throw error
            }
            await context.stop()
        }
    }
}
