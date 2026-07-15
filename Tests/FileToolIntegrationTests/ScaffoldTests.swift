import Testing

@testable import FileTool

/// Scaffolding smoke test for the isolated-directory integration tier.
///
/// The `@testable import FileTool` above is the real assertion: it only
/// compiles and links if the `FileTool` library target builds and exposes an
/// importable module to the integration target. Reaching and running this
/// `@Test` under `swift test` therefore proves the second test target compiles
/// and executes — no tautological runtime assertion is needed.
///
/// The real integration suites — every path exercised in a fresh temp
/// workspace, the diagnostics paths against a live `sourcekit-lsp` in a
/// scaffolded compiling Swift package — replace this smoke test in the
/// integration task.
@Suite struct FileToolIntegrationScaffoldTests {
    @Test func integrationTargetCompilesAndRuns() {}
}
