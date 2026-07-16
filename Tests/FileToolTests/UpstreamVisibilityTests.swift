import Foundation
import Testing

// Plain import — deliberately NOT `@testable`. The whole point of this probe is
// to prove the upstream `FoundationModelsCodeContext` surface the diagnostics
// bridge depends on is reachable across the package boundary as ordinary public
// API, without reaching into module internals.
import FoundationModelsCodeContext

/// A throwaway ``TextEmbedding`` conformance local to the test target.
///
/// `CodeContextManager.init` requires a ``TextEmbedding``. The production
/// `NullEmbedder` lands only in the later diagnostics-bridge task, so this probe
/// supplies its own trivial, GPU-free double: a fixed one-dimensional zero
/// vector per input. It exists purely to satisfy the initializer's signature —
/// the probe never runs an embedding pass.
private struct ProbeEmbedder: TextEmbedding {
    /// The length of every embedding vector this embedder produces.
    let dimension: Int = 1

    /// Returns one zero vector of length ``dimension`` per input string.
    /// - Parameter texts: The strings to (nominally) embed.
    /// - Returns: One `dimension`-length zero vector per input, in order.
    /// - Throws: Nothing; the signature carries `throws` to satisfy the `TextEmbedding` protocol requirement.
    func embed(_ texts: [String]) async throws -> [[Float]] {
        texts.map { _ in [Float](repeating: 0, count: dimension) }
    }
}

/// Compile-only reach into the public ``DiagnosticsReport`` surface.
///
/// `DiagnosticsReport`, `DiagnosticRecord`, and `Counts` all have internal
/// initializers, so a plain-import consumer cannot construct one — a report is
/// only ever obtained from a running context. This function therefore takes a
/// report as a parameter and reads the members the bridge needs. It is
/// type-checked and visibility-checked at compile time but never invoked, so no
/// report is constructed and no language server spawns.
/// - Parameter report: A report supplied by the (uncalled) caller.
/// - Returns: The record list, the `.errors` count, and the `pending` flag.
private func readReportSurface(
    _ report: DiagnosticsReport
) -> (records: [DiagnosticRecord], errorCount: Int, pending: Bool) {
    let records: [DiagnosticRecord] = report.records
    let counts: Counts = report.counts
    // Touch a `DiagnosticRecord` member too, proving its fields are public.
    _ = records.first?.path
    return (records, counts.errors, report.pending)
}

/// Compile-only proof that ``CodeContext/rootDirectory`` is `public nonisolated`.
///
/// This function reads `rootDirectory` from a plain synchronous context — no
/// `await`. That only compiles if the property is both `public` (reachable
/// without `@testable`) and `nonisolated` (readable without hopping onto the
/// actor). Like `readReportSurface`, it is compiled but never invoked, so it
/// constructs no context and spawns no language server.
/// - Parameter context: A context supplied by the (uncalled) caller.
/// - Returns: The context's workspace root URL.
private func readRootDirectorySynchronously(
    of context: CodeContext<ProcessLanguageServerConnection>
) -> URL {
    context.rootDirectory
}

/// Compile-visibility probe for the now-public `FoundationModelsCodeContext`
/// surface the diagnostics bridge consumes as a sibling package.
///
/// These tests assert reachability at *compile* time via a plain
/// `import FoundationModelsCodeContext` (no `@testable`): if `rootDirectory`
/// were still `private`, or the report members non-public, or `@testable` were
/// required, this file would fail to build. No test here spawns a language
/// server or requires a real index or model.
@Suite struct UpstreamVisibilityTests {
    /// `CodeContextManager` is constructible through its public initializer with
    /// only a `TextEmbedding`, without `@testable` and without spawning a server.
    ///
    /// The public initializer merely stores its pieces and awaits
    /// `ManagerState()`; a root is opened and a language server started only when
    /// `context(for:)` / `context(containing:)` is later called. Constructing the
    /// manager therefore proves the public init and the `TextEmbedding` seam are
    /// reachable across the package boundary while spawning nothing.
    @Test func managerIsConstructibleWithPlainImport() async {
        let manager: CodeContextManager<ProcessLanguageServerConnection> =
            await CodeContextManager(embedder: ProbeEmbedder())
        // `state` is a public nonisolated member — reading it synchronously here
        // confirms the constructed manager is a usable public value.
        _ = manager.state
    }

    /// The public report and context read paths are reachable without `@testable`.
    ///
    /// Referencing the compiled read helpers forces the compiler to have already
    /// visibility-checked every member they touch — `report.records`,
    /// `report.counts.errors`, `report.pending`, `DiagnosticRecord.path`, and the
    /// synchronous `context.rootDirectory` read. The helpers are never called, so
    /// this exercises visibility only, never a live context.
    @Test func publicReadPathsAreReachableWithoutTestable() {
        let reportReader: (DiagnosticsReport) -> (
            records: [DiagnosticRecord], errorCount: Int, pending: Bool
        ) = readReportSurface
        let rootReader: (CodeContext<ProcessLanguageServerConnection>) -> URL =
            readRootDirectorySynchronously
        _ = reportReader
        _ = rootReader
    }
}
