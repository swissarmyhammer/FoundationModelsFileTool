import Foundation
import Testing

// Plain import — the fake resolver never touches upstream internals. Only
// `DiagnosticSeverity` (a public enum) is referenced, to assert the severity
// floor the bridge passes down.
import FoundationModelsCodeContext

@testable import FileTool

/// Hermetic, fast tests of ``DiagnosticsBridge`` driven entirely through a fake
/// ``DiagnosticsResolving`` conformance.
///
/// The whole point of the ``DiagnosticsResolving`` seam is that these tests
/// never spawn a real language server, never create a `CodeContextManager`, and
/// never touch the filesystem: the fake is keyed by path prefix and returns
/// ``ResolvedDiagnostics`` values the test constructs directly (the upstream
/// `DiagnosticsReport` is unconstructable across the package boundary — its
/// initializer is `internal` and the dependency is not built for testing, which
/// is exactly why the seam returns a FileTool-owned value type). Real-manager
/// and real-LSP behavior is covered by the separate integration-suite tasks.
@Suite struct DiagnosticsBridgeTests {
    // MARK: Fixtures

    /// A synthetic session root used as the ``FileContext`` root every bridge
    /// under test rebases its item paths against. No directory is created on
    /// disk — the bridge only reads the URL's path components.
    private static let sessionRoot = URL(fileURLWithPath: "/session")

    /// A synthetic per-project git root nested one level under ``sessionRoot``,
    /// modelling the multi-project layout where the session root sits above the
    /// enclosing git repositories.
    private static let projectRoot = URL(fileURLWithPath: "/session/projectA")

    /// A synthetic second project root, for the per-file routing test.
    private static let otherProjectRoot = URL(fileURLWithPath: "/session/projectB")

    /// A diagnosable (`.swift`) file inside ``projectRoot``.
    private static let swiftFileInProjectA =
        URL(fileURLWithPath: "/session/projectA/Sources/Alpha.swift")

    /// A diagnosable (`.swift`) file inside ``otherProjectRoot``.
    private static let swiftFileInProjectB =
        URL(fileURLWithPath: "/session/projectB/Sources/Beta.swift")

    /// A trivial error used to exercise the resolver-exception degradation path.
    private enum FakeError: Error {
        /// The single failure the fake can be configured to throw.
        case boom
    }

    // MARK: Resolved-value builders

    /// Build a one-record ``ResolvedDiagnostics`` at ``projectRoot``.
    ///
    /// - Parameters:
    ///   - severity: the single record's severity.
    ///   - relativePath: the record's path, relative to `contextRoot`.
    ///   - message: the record's message.
    ///   - code: the record's optional diagnostic code.
    ///   - line: the record's zero-based line.
    ///   - column: the record's zero-based column.
    ///   - contextRoot: the resolved context root the record path is relative to.
    /// - Returns: the single-record resolved value.
    private static func oneRecord(
        severity: ResolvedSeverity,
        relativePath: String = "Sources/Alpha.swift",
        message: String = "something is wrong",
        code: String? = nil,
        line: Int = 0,
        column: Int = 0,
        contextRoot: URL = DiagnosticsBridgeTests.projectRoot
    ) -> ResolvedDiagnostics {
        let record = ResolvedDiagnosticRecord(
            relativePath: relativePath,
            line: line,
            column: column,
            severity: severity,
            message: message,
            code: code
        )
        return ResolvedDiagnostics(
            records: [record],
            errorCount: severity == .error ? 1 : 0,
            warningCount: severity == .warning ? 1 : 0,
            pending: false,
            contextRoot: contextRoot
        )
    }

    /// Build an empty (clean) ``ResolvedDiagnostics`` at ``projectRoot``.
    ///
    /// - Parameter contextRoot: the resolved context root.
    /// - Returns: a record-free, non-pending resolved value.
    private static func clean(contextRoot: URL = DiagnosticsBridgeTests.projectRoot) -> ResolvedDiagnostics {
        ResolvedDiagnostics(records: [], errorCount: 0, warningCount: 0, pending: false, contextRoot: contextRoot)
    }

    // MARK: Bridge builder

    /// Build a bridge wired to `resolver`, rooted at ``sessionRoot``.
    ///
    /// - Parameters:
    ///   - resolver: the fake resolver to inject.
    ///   - mode: the bridge mode; defaults to `.enabled`.
    ///   - eagerWarmup: whether to warm the enclosing project at creation.
    ///   - settleWindow: the injected settle window.
    ///   - hardTimeout: the injected hard timeout.
    ///   - perReportCap: the injected upstream per-report cap.
    /// - Returns: the configured bridge.
    private static func makeBridge(
        resolver: any DiagnosticsResolving,
        mode: DiagnosticsBridge.Mode = .enabled,
        eagerWarmup: Bool = false,
        settleWindow: Duration = DiagnosticsBridge.defaultSettleWindow,
        hardTimeout: Duration = DiagnosticsBridge.defaultHardTimeout,
        perReportCap: Int = DiagnosticsBridge.defaultCountingPerReportCap
    ) -> DiagnosticsBridge {
        DiagnosticsBridge(
            root: sessionRoot,
            mode: mode,
            eagerWarmup: eagerWarmup,
            resolver: resolver,
            settleWindow: settleWindow,
            hardTimeout: hardTimeout,
            perReportCap: perReportCap
        )
    }

    // MARK: Mode / gate behavior (no manager, no resolution)

    @Test func disabledModeReturnsNilWithoutTouchingTheResolver() async {
        let fake = FakeResolver(workspaces: [(Self.projectRoot, Self.oneRecord(severity: .error))])
        let bridge = Self.makeBridge(resolver: fake, mode: .disabled)

        let result = await bridge.diagnose(fileAt: Self.swiftFileInProjectA)

        #expect(result == nil)
        #expect(await fake.diagnoseCallCount == 0)
    }

    @Test func nonDiagnosableExtensionIsSkippedWithoutResolving() async {
        let fake = FakeResolver(workspaces: [(Self.projectRoot, Self.oneRecord(severity: .error))])
        let bridge = Self.makeBridge(resolver: fake)

        // A non-canonical, uppercase `.MD` spelling exercises the extension
        // normalization on the skip path: `isDiagnosableExtension` lowercases
        // before its set check, so `.MD` normalizes to `.md` and is skipped.
        let result = await bridge.diagnose(fileAt: URL(fileURLWithPath: "/session/projectA/README.MD"))

        #expect(result?.status == "skipped")
        #expect(result?.note == DiagnosticsBridge.nonDiagnosableNote)
        #expect(await fake.diagnoseCallCount == 0)
    }

    @Test func uppercaseDiagnosableExtensionIsNormalizedAndResolved() async {
        // An uppercase `.SWIFT` must normalize to `.swift` and be admitted on
        // the diagnosable path — if the gate did not lowercase, `.SWIFT` would
        // miss the set and be skipped without ever resolving. Proving it
        // resolves (callCount 1, non-skipped status) proves normalization runs.
        let fake = FakeResolver(workspaces: [(Self.projectRoot, Self.clean())])
        let bridge = Self.makeBridge(resolver: fake)

        let result = await bridge.diagnose(fileAt: URL(fileURLWithPath: "/session/projectA/Sources/Alpha.SWIFT"))

        #expect(result?.status == "clean")
        #expect(await fake.diagnoseCallCount == 1)
    }

    @Test(arguments: ["Glob*.swift", "Query?.swift", "Array[0].swift"])
    func globMetacharacterFilenameIsSkippedBeforeResolution(_ name: String) async {
        let fake = FakeResolver(workspaces: [(Self.projectRoot, Self.oneRecord(severity: .error))])
        let bridge = Self.makeBridge(resolver: fake)

        let result = await bridge.diagnose(fileAt: URL(fileURLWithPath: "/session/projectA/\(name)"))

        #expect(result?.status == "skipped")
        #expect(result?.note == DiagnosticsBridge.globMetacharacterNote)
        #expect(await fake.diagnoseCallCount == 0)
    }

    @Test func globMetacharacterInAncestorDirectoryIsSkippedBeforeResolution() async {
        // The bridge hands upstream the full absolute path, whose glob detection
        // scans the *entire* string — so a metacharacter in any ancestor
        // directory (not just the filename) must skip before resolution, or it
        // would trip upstream's glob and read as a false `clean`.
        let ancestorRoot = URL(fileURLWithPath: "/session/proj[a]")
        let fake = FakeResolver(workspaces: [(ancestorRoot, Self.clean(contextRoot: ancestorRoot))])
        let bridge = Self.makeBridge(resolver: fake)

        let result = await bridge.diagnose(fileAt: URL(fileURLWithPath: "/session/proj[a]/Sources/Alpha.swift"))

        #expect(result?.status == "skipped")
        #expect(result?.note == DiagnosticsBridge.globMetacharacterNote)
        #expect(await fake.diagnoseCallCount == 0)
    }

    // MARK: Resolution outcomes

    @Test func fileOutsideAnyWorkspaceIsSkippedWithNotInWorkspaceNote() async {
        // No workspace covers the file → the resolver returns nil.
        let fake = FakeResolver(workspaces: [])
        let bridge = Self.makeBridge(resolver: fake)

        let result = await bridge.diagnose(fileAt: Self.swiftFileInProjectA)

        #expect(result?.status == "skipped")
        #expect(result?.note == DiagnosticsBridge.notInWorkspaceNote)
        #expect(await fake.diagnoseCallCount == 1)
    }

    @Test func reportWithErrorsMapsToErrorsStatus() async {
        let resolved = Self.oneRecord(
            severity: .error,
            message: "cannot find 'foo' in scope",
            code: "E0425",
            line: 11,
            column: 4
        )
        let fake = FakeResolver(workspaces: [(Self.projectRoot, resolved)])
        let bridge = Self.makeBridge(resolver: fake)

        let result = await bridge.diagnose(fileAt: Self.swiftFileInProjectA)

        #expect(result?.status == "errors")
        #expect(result?.errors == 1)
        #expect(result?.warnings == 0)
        #expect(result?.items.count == 1)
        let item = try! #require(result?.items.first)
        #expect(item.severity == "error")
        #expect(item.message == "cannot find 'foo' in scope")
        #expect(item.code == "E0425")
        // Zero-based LSP line/column surface as one-based, matching the tool's
        // one-based hashline convention.
        #expect(item.line == 12)
        #expect(item.column == 5)
    }

    @Test func reportWithWarningsOnlyMapsToWarningsStatus() async {
        let fake = FakeResolver(workspaces: [(Self.projectRoot, Self.oneRecord(severity: .warning))])
        let bridge = Self.makeBridge(resolver: fake)

        let result = await bridge.diagnose(fileAt: Self.swiftFileInProjectA)

        #expect(result?.status == "warnings")
        #expect(result?.errors == 0)
        #expect(result?.warnings == 1)
    }

    @Test func emptyReportMapsToCleanStatus() async {
        let fake = FakeResolver(workspaces: [(Self.projectRoot, Self.clean())])
        let bridge = Self.makeBridge(resolver: fake)

        let result = await bridge.diagnose(fileAt: Self.swiftFileInProjectA)

        #expect(result?.status == "clean")
        #expect(result?.errors == 0)
        #expect(result?.warnings == 0)
        #expect(result?.items.isEmpty == true)
    }

    @Test func pendingReportMapsToPendingStatus() async {
        let resolved = ResolvedDiagnostics(
            records: [],
            errorCount: 0,
            warningCount: 0,
            pending: true,
            contextRoot: Self.projectRoot
        )
        let fake = FakeResolver(workspaces: [(Self.projectRoot, resolved)])
        let bridge = Self.makeBridge(resolver: fake)

        let result = await bridge.diagnose(fileAt: Self.swiftFileInProjectA)

        #expect(result?.status == "pending")
        #expect(result?.note == DiagnosticsBridge.pendingReportNote)
    }

    @Test func resolverExceptionDegradesToPending() async {
        let fake = FakeResolver(workspaces: [], failure: FakeError.boom)
        let bridge = Self.makeBridge(resolver: fake)

        let result = await bridge.diagnose(fileAt: Self.swiftFileInProjectA)

        #expect(result?.status == "pending")
        #expect(result?.note != nil)
    }

    // MARK: Item cap with true counts

    @Test func itemsAreCappedButCountsAreTrue() async {
        let overCap = DiagnosticsBridge.maximumReportedItemCount + 50
        let records = (0 ..< overCap).map { index in
            ResolvedDiagnosticRecord(
                relativePath: "Sources/File\(index).swift",
                line: index,
                column: 0,
                severity: .error,
                message: "error \(index)",
                code: nil
            )
        }
        let resolved = ResolvedDiagnostics(
            records: records,
            errorCount: overCap,
            warningCount: 0,
            pending: false,
            contextRoot: Self.projectRoot
        )
        let fake = FakeResolver(workspaces: [(Self.projectRoot, resolved)])
        let bridge = Self.makeBridge(resolver: fake)

        let result = await bridge.diagnose(fileAt: Self.swiftFileInProjectA)

        #expect(result?.items.count == DiagnosticsBridge.maximumReportedItemCount)
        #expect(result?.errors == overCap)
    }

    // MARK: Path rebase

    @Test func itemPathsAreRebasedToSessionRoot() async {
        // Record path is relative to the RESOLVED context root (projectA), which
        // sits one level under the session root; the item path must be
        // session-root-relative.
        let resolved = Self.oneRecord(
            severity: .error,
            relativePath: "Sources/Alpha.swift",
            contextRoot: Self.projectRoot
        )
        let fake = FakeResolver(workspaces: [(Self.projectRoot, resolved)])
        let bridge = Self.makeBridge(resolver: fake)

        let result = await bridge.diagnose(fileAt: Self.swiftFileInProjectA)

        #expect(result?.items.first?.file == "projectA/Sources/Alpha.swift")
    }

    // MARK: Per-file routing across two roots

    @Test func filesRouteToTheirRespectiveWorkspaces() async {
        let fake = FakeResolver(workspaces: [
            (Self.projectRoot, Self.oneRecord(severity: .error, contextRoot: Self.projectRoot)),
            (Self.otherProjectRoot, Self.clean(contextRoot: Self.otherProjectRoot)),
        ])
        let bridge = Self.makeBridge(resolver: fake)

        let inA = await bridge.diagnose(fileAt: Self.swiftFileInProjectA)
        let inB = await bridge.diagnose(fileAt: Self.swiftFileInProjectB)

        #expect(inA?.status == "errors")
        #expect(inB?.status == "clean")
        let openRoots = await bridge.openRootDirectories()
        #expect(Set(openRoots) == Set([Self.projectRoot, Self.otherProjectRoot]))
    }

    // MARK: Severity floor + injected settle parameters

    @Test func severityFloorAndSettleParametersArePassedThrough() async {
        let fake = FakeResolver(workspaces: [(Self.projectRoot, Self.clean())])
        let bridge = Self.makeBridge(
            resolver: fake,
            settleWindow: .milliseconds(42),
            hardTimeout: .seconds(1),
            perReportCap: 7
        )

        _ = await bridge.diagnose(fileAt: Self.swiftFileInProjectA)

        #expect(await fake.recordedSeverity == .warning)
        #expect(await fake.recordedIncludeDependents == true)
        #expect(await fake.recordedSettleWindow == .milliseconds(42))
        #expect(await fake.recordedHardTimeout == .seconds(1))
        #expect(await fake.recordedPerReportCap == 7)
    }

    // MARK: Lazy vs eager warmup

    @Test func lazyModeDoesNotWarmUpUntilFirstMutation() async {
        let fake = FakeResolver(workspaces: [(Self.projectRoot, Self.clean())])
        let bridge = Self.makeBridge(resolver: fake, eagerWarmup: false)

        #expect(bridge.warmUpTask == nil)
        #expect(await fake.warmUpCallCount == 0)

        _ = await bridge.diagnose(fileAt: Self.swiftFileInProjectA)
        #expect(await fake.diagnoseCallCount == 1)
    }

    @Test func eagerWarmupWarmsTheEnclosingProjectAtCreation() async {
        let fake = FakeResolver(workspaces: [(Self.projectRoot, Self.clean())])
        let bridge = Self.makeBridge(resolver: fake, eagerWarmup: true)

        await bridge.warmUpTask?.value

        #expect(await fake.warmUpCallCount == 1)
        #expect(await fake.warmedUpRoots == [Self.sessionRoot])
    }

    @Test func disabledModeNeverWarmsUpEvenWhenEager() async {
        let fake = FakeResolver(workspaces: [(Self.projectRoot, Self.clean())])
        let bridge = Self.makeBridge(resolver: fake, mode: .disabled, eagerWarmup: true)

        #expect(bridge.warmUpTask == nil)
        #expect(await fake.warmUpCallCount == 0)
    }
}

/// A fake ``DiagnosticsResolving`` keyed by path prefix, recording the
/// parameters it was called with.
///
/// Purely in-memory: it constructs no `CodeContextManager`, spawns no language
/// server, and touches no filesystem. It resolves a file to the longest-prefix
/// workspace it was configured with (mirroring the manager's longest-prefix
/// routing), returns that workspace's canned ``ResolvedDiagnostics``, or `nil`
/// when no workspace covers the file. Configured with a `failure` it throws
/// instead, to exercise the bridge's error-degradation path.
private actor FakeResolver: DiagnosticsResolving {
    /// The configured workspaces, each a `(root prefix, canned result)` pair.
    private let workspaces: [(root: URL, result: ResolvedDiagnostics)]

    /// The error to throw from ``diagnostics(forFileAt:severity:includeDependents:settleWindow:hardTimeout:perReportCap:)``, or `nil` to resolve normally.
    private let failure: (any Error)?

    /// The severity the bridge last passed down.
    private(set) var recordedSeverity: DiagnosticSeverity?

    /// The `includeDependents` flag the bridge last passed down.
    private(set) var recordedIncludeDependents: Bool?

    /// The settle window the bridge last passed down.
    private(set) var recordedSettleWindow: Duration?

    /// The hard timeout the bridge last passed down.
    private(set) var recordedHardTimeout: Duration?

    /// The per-report cap the bridge last passed down.
    private(set) var recordedPerReportCap: Int?

    /// The number of ``diagnostics(forFileAt:severity:includeDependents:settleWindow:hardTimeout:perReportCap:)`` calls.
    private(set) var diagnoseCallCount = 0

    /// The number of ``warmUp(root:)`` calls.
    private(set) var warmUpCallCount = 0

    /// The roots ``warmUp(root:)`` was called with, in order.
    private(set) var warmedUpRoots: [URL] = []

    /// The roots successfully resolved, in order.
    private(set) var resolvedRoots: [URL] = []

    /// Creates a fake resolver.
    ///
    /// - Parameters:
    ///   - workspaces: the `(root prefix, canned result)` pairs to route against.
    ///   - failure: an error to throw instead of resolving, or `nil`.
    init(workspaces: [(root: URL, result: ResolvedDiagnostics)] = [], failure: (any Error)? = nil) {
        self.workspaces = workspaces
        self.failure = failure
    }

    func diagnostics(
        forFileAt fileURL: URL,
        severity: DiagnosticSeverity,
        includeDependents: Bool,
        settleWindow: Duration,
        hardTimeout: Duration,
        perReportCap: Int
    ) async throws -> ResolvedDiagnostics? {
        diagnoseCallCount += 1
        recordedSeverity = severity
        recordedIncludeDependents = includeDependents
        recordedSettleWindow = settleWindow
        recordedHardTimeout = hardTimeout
        recordedPerReportCap = perReportCap

        if let failure {
            throw failure
        }

        let match = workspaces
            .filter { fileURL.path.hasPrefix($0.root.path) }
            .max { $0.root.path.count < $1.root.path.count }
        guard let match else {
            return nil
        }
        resolvedRoots.append(match.root)
        return match.result
    }

    func warmUp(root: URL) async {
        warmUpCallCount += 1
        warmedUpRoots.append(root)
    }

    func openRootDirectories() async -> [URL] {
        resolvedRoots
    }

    func shutdown() async {}
}
