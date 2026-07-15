import Testing

@testable import FileTool

/// Scaffolding smoke test for the `FileTool` module.
///
/// The `@testable import FileTool` above is the real assertion: it only
/// compiles and links if the `FileTool` library target builds and exposes an
/// importable module. Reaching and running this `@Test` under `swift test`
/// therefore proves both that the module imports cleanly and that the package's
/// unit test target executes — no tautological runtime assertion is needed.
///
/// Real behavioral tests for the file operations (Hashline, PathGuard,
/// EditEngine, the glob/grep engines, dispatch) replace this smoke test
/// alongside the implementation in the subsequent tasks.
@Suite struct FileToolScaffoldTests {
    @Test func moduleImportsCleanlyAndTestTargetRuns() {}
}
