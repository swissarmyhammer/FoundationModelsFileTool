import Foundation
import Testing

@testable import FileTool

/// Tests of the ``FileContext`` session lifecycle.
@Suite struct FileContextTests {
    /// The owner tears the session down structurally through ``FileContext/stop()``.
    ///
    /// ``FileContext/stop()`` is the explicit, structured teardown a session
    /// owner calls before releasing the context — it forwards to the diagnostics
    /// bridge's ``DiagnosticsBridge/stop()``, which closes every open workspace.
    /// It replaces the previous reliance on the bridge's `deinit` firing an
    /// unstructured task. It must be safe to call when no diagnosable mutation
    /// ever started the manager, and must leave the context usable.
    @Test func stopTearsDownTheSessionSafely() async {
        let root = TestSupport.makeTemporaryDirectory(named: "FileContextTests")
        let context = FileContext(root: root)

        await context.stop()

        // Stopping never started a manager (no diagnosable mutation happened),
        // and the context is still usable: a non-diagnosable file skips cleanly.
        let result = await context.diagnostics.diagnose(
            fileAt: root.appendingPathComponent("notes.txt")
        )
        #expect(result?.status == "skipped")
    }
}
