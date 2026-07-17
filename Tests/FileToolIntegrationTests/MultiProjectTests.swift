import Foundation
import FoundationModels
import Operations
import Testing

@testable import FileTool

// The CI gate that turns a missing `sourcekit-lsp` into a hard failure under `CI`
// lives once in ``SourceKitLSPGateTests`` (alongside suite A); it is a global,
// always-enabled guard, so this suite reuses it rather than re-declaring it and
// only carries the local-skip half of the gate via its `.enabled(if:)` trait.

/// The real-`sourcekit-lsp` multi-project routing matrix: one ``FileContext``
/// rooted *above* two independent git repositories, proving the
/// `CodeContextManager`-backed bridge resolves diagnostics per project and keeps
/// projects isolated.
///
/// Where suite A (``ErrorDetectionTests``) roots the session *at* a single
/// package, this suite roots it at a parent directory holding two packages plus
/// files that belong to no repository. Every row drives real mutations through
/// full `AnyOperation` dispatch against one ``FileContext`` (real
/// ``DiagnosticsBridge`` + real `CodeContextManager` + real `sourcekit-lsp`) and
/// asserts on the *actual* compiler message, the session-root-relative path into
/// the *correct* package, and — for the negatives — the bridge's
/// `@testable`-reachable open-roots accessor
/// (``DiagnosticsBridge/openRootDirectories()``), because a reported path can
/// prove a context *was* used but never that another was *not* opened.
///
/// Structure and robustness (matching suites A and B):
///
/// - **One fresh session root and context per row.** The exact-open-roots row
///   asserts the open set grows from empty → `[PackageA]` → `[PackageA, PackageB]`,
///   which is only meaningful from a clean start, so every row scaffolds its own
///   ``MultiProjectWorkspace/withMultiProjectRoot(named:_:)`` and owns one
///   ``FileContext`` whose ``FileContext/stop()`` runs on every exit path — the
///   real language server is never leaked. Eager warm-up is pointless here (the
///   session root is above the repositories and encloses no `git` root of its
///   own), so each package opens lazily on its first mutation.
/// - **No timing assertions.** A real language server settles on its own
///   wall-clock, so every settled expectation and every open-roots expectation
///   converges via bounded polling under a generous deadline.
/// - **Per-row isolation and `.serialized`.** Each row owns its session root, and
///   the suite runs one heavy language server at a time.
@Suite(.serialized, .enabled(if: LSPGate.isSourceKitLSPAvailable, Comment(rawValue: LSPGate.skipMessage)))
struct MultiProjectTests {
    // MARK: - Tuning

    /// The generous overall deadline the dependent-breakage row polls within.
    ///
    /// The slowest row: the caller's error is folded in via the LSP call-edge
    /// index, which on a cold package is only reliably built once sourcekit-lsp's
    /// semantic index is ready, so it warrants a larger budget than single-file
    /// rows — mirroring suite A's dependent-breakage tuning.
    private static let dependentDeadline: Duration = .seconds(240)

    /// How long to wait between caller-nudge/poll iterations in the
    /// dependent-breakage row, giving the file watcher and LSP index worker time
    /// to re-index the nudged caller before the next diagnostics pass.
    private static let dependentNudgeInterval: Duration = .seconds(3)

    /// The generous deadline an open-roots expectation converges within.
    private static let openRootsDeadline: Duration = .seconds(60)

    /// The interval between open-roots polls.
    private static let openRootsPollInterval: Duration = .milliseconds(250)

    // MARK: - Cross-project error isolation

    /// A type error in PackageA surfaces as an `errors` report naming PackageA's
    /// file by a session-root-relative path, and a subsequent clean edit in
    /// PackageB reports `clean` — PackageA's pre-existing error never bleeds into
    /// PackageB's report, and neither report names the other package.
    @Test func typeErrorInPackageAStaysIsolatedFromCleanEditInPackageB() async throws {
        try await MultiProjectWorkspace.withMultiProjectRoot(named: "MultiProjectTypeError") { root in
            try await withSession(root: root) { tool, context in
                let packageAOutput = try await DiagnosticsProbe.callTool(
                    tool,
                    arguments: editIntroducingTypeError(at: root.packageA.typeRow)
                )
                expectDispatchedDiagnostics(packageAOutput, label: "PackageA type error")

                let packageASettled = await DiagnosticsProbe.awaitDiagnostics(
                    from: context.diagnostics,
                    fileAt: root.packageA.typeRow
                ) { diagnostics in
                    diagnostics.status == IntegrationWire.errors
                        && diagnostics.items.contains { $0.message.localizedCaseInsensitiveContains("cannot convert") }
                }
                requireErrorItem(
                    packageASettled,
                    packageDirectory: MultiProjectWorkspace.packageADirectoryName,
                    fileSuffix: "TypeRow.swift",
                    messageContains: ["cannot convert", "Int"],
                    label: "PackageA type error"
                )
                expectNoPath(
                    packageASettled,
                    intoPackageDirectory: MultiProjectWorkspace.packageBDirectoryName,
                    label: "PackageA type-error report"
                )

                let packageBOutput = try await DiagnosticsProbe.callTool(
                    tool,
                    arguments: DiagnosticsProbe.payload([
                        ("op", "edit file"),
                        ("filePath", root.packageB.typeRow.path),
                        ("find", ["let value = 1"]),
                        ("replace", ["let value = 2"]),
                    ])
                )
                expectDispatchedDiagnostics(packageBOutput, label: "PackageB clean edit")

                let packageBSettled = await DiagnosticsProbe.awaitDiagnostics(
                    from: context.diagnostics,
                    fileAt: root.packageB.typeRow
                ) { diagnostics in diagnostics.status == IntegrationWire.clean }

                guard let packageBSettled else {
                    Issue.record("PackageB clean edit never settled to clean within deadline")
                    return
                }
                #expect(
                    packageBSettled.status == IntegrationWire.clean,
                    "PackageB clean edit expected clean, got \(packageBSettled.status) (note: \(packageBSettled.note ?? "nil"))"
                )
                expectNoPath(
                    packageBSettled,
                    intoPackageDirectory: MultiProjectWorkspace.packageADirectoryName,
                    label: "PackageB clean report"
                )
            }
        }
    }

    // MARK: - Project-scoped dependents

    /// A signature break in PackageA's provider folds in its caller's error — in
    /// the *other* PackageA file — via `includeDependents`; the dependents stay
    /// project-scoped, so no PackageB path ever appears in a PackageA report.
    @Test func signatureBreakFoldsPackageACallerAndNeverNamesPackageB() async throws {
        try await MultiProjectWorkspace.withMultiProjectRoot(named: "MultiProjectDependents") { root in
            try await withSession(root: root) { tool, context in
                let output = try await DiagnosticsProbe.callTool(
                    tool,
                    arguments: DiagnosticsProbe.payload([
                        ("op", "edit file"),
                        ("filePath", root.packageA.dependentProvider.path),
                        ("find", ["public func compute() -> Int {"]),
                        ("replace", ["public func compute(_ operand: Int) -> Int {"]),
                    ])
                )
                expectDispatchedDiagnostics(output, label: "PackageA signature break")

                // The caller's error is folded in via the LSP call-edge index,
                // which on a cold package is only reliably built once the semantic
                // index is ready. Re-writing the caller (its call to the provider
                // unchanged; only a trailing comment differs) marks it dirty so the
                // watcher re-records the call edge. We nudge-and-poll under a
                // generous deadline — no timing assertion — mirroring suite A.
                let settled = await awaitFoldedCallerError(context: context, package: root.packageA)

                guard let settled else {
                    Issue.record("signature break: the caller's error was never folded in within deadline")
                    return
                }
                #expect(
                    settled.status == IntegrationWire.errors,
                    "signature break: expected errors, got \(settled.status) (note: \(settled.note ?? "nil"))"
                )
                guard let callerItem = settled.items.first(where: { $0.file.hasSuffix("Caller.swift") }) else {
                    Issue.record(
                        "signature break: no caller diagnostic was folded in; items were \(settled.items.map(\.file))"
                    )
                    return
                }
                #expect(
                    callerItem.file.hasPrefix(MultiProjectWorkspace.packageADirectoryName + "/"),
                    "signature break: caller path '\(callerItem.file)' is not a session-root-relative path into PackageA"
                )
                #expect(
                    callerItem.message.localizedCaseInsensitiveContains("argument"),
                    "signature break: caller message '\(callerItem.message)' did not mention the missing argument"
                )
                expectNoPath(
                    settled,
                    intoPackageDirectory: MultiProjectWorkspace.packageBDirectoryName,
                    label: "PackageA signature-break report"
                )
            }
        }
    }

    // MARK: - Which contexts opened

    /// The first mutation in PackageA opens exactly PackageA's context; the first
    /// mutation in PackageB then adds exactly PackageB's — proven through the
    /// open-roots accessor, not inferred from result paths.
    @Test func firstMutationInEachPackageOpensExactlyThatPackagesContext() async throws {
        try await MultiProjectWorkspace.withMultiProjectRoot(named: "MultiProjectOpenRoots") { root in
            try await withSession(root: root) { tool, context in
                let initial = await context.diagnostics.openRootDirectories()
                #expect(
                    initial.isEmpty,
                    "no context should be open before the first mutation, got \(initial.map(\.path))"
                )

                _ = try await DiagnosticsProbe.callTool(tool, arguments: editIntroducingTypeError(at: root.packageA.typeRow))
                let afterPackageA = await awaitOpenRoots(
                    from: context,
                    including: [normalizedPath(root.packageA.root)]
                )
                #expect(
                    normalizedPaths(afterPackageA) == [normalizedPath(root.packageA.root)],
                    "the first PackageA mutation should open exactly [PackageA], got \(afterPackageA.map(\.path))"
                )

                _ = try await DiagnosticsProbe.callTool(tool, arguments: editIntroducingTypeError(at: root.packageB.typeRow))
                let afterPackageB = await awaitOpenRoots(
                    from: context,
                    including: [normalizedPath(root.packageB.root)]
                )
                #expect(
                    normalizedPaths(afterPackageB)
                        == [normalizedPath(root.packageA.root), normalizedPath(root.packageB.root)],
                    "the first PackageB mutation should open exactly [PackageA, PackageB], got \(afterPackageB.map(\.path))"
                )
            }
        }
    }

    // MARK: - Nested repository routing

    /// With a git-initialized sub-package nested inside PackageA, once PackageA's
    /// context is open an edit inside the nested repository routes to PackageA's
    /// (outer) context — nearest-open-ancestor wins — and opens no context for the
    /// nested root, proven through the open-roots accessor.
    @Test func editInsideNestedRepositoryRoutesToOuterPackageAndOpensNoNestedContext() async throws {
        try await MultiProjectWorkspace.withMultiProjectRoot(named: "MultiProjectNested") { root in
            let nested = try MultiProjectWorkspace.scaffoldNestedRepository(inside: root.packageA)
            try await withSession(root: root) { tool, context in
                _ = try await DiagnosticsProbe.callTool(tool, arguments: editIntroducingTypeError(at: root.packageA.typeRow))
                let afterPackageA = await awaitOpenRoots(
                    from: context,
                    including: [normalizedPath(root.packageA.root)]
                )
                #expect(
                    normalizedPaths(afterPackageA) == [normalizedPath(root.packageA.root)],
                    "PackageA should be the only open root before the nested edit, got \(afterPackageA.map(\.path))"
                )

                _ = try await DiagnosticsProbe.callTool(
                    tool,
                    arguments: DiagnosticsProbe.payload([
                        ("op", "edit file"),
                        ("filePath", nested.swiftFile.path),
                        ("find", ["return 1"]),
                        ("replace", ["return 2"]),
                    ])
                )

                // Nearest-open-ancestor wins: the nested file routes to the already
                // open PackageA context, so the open set is unchanged and the nested
                // repository root is never opened. The op has already awaited the
                // full diagnose, so the open set is final — read it once.
                let afterNested = await context.diagnostics.openRootDirectories()
                #expect(
                    normalizedPaths(afterNested) == [normalizedPath(root.packageA.root)],
                    "the nested edit must route to PackageA and open no nested context, got \(afterNested.map(\.path))"
                )
                #expect(
                    !normalizedPaths(afterNested).contains(normalizedPath(nested.root)),
                    "the nested repository root must never be opened"
                )
            }
        }
    }

    // MARK: - Files outside any repository

    /// Editing the stray `Loose.swift` (diagnosable by extension, enclosed by no
    /// git repository) commits the mutation and reports `skipped` with the
    /// not-in-a-git-workspace note, opening no context.
    @Test func editingLooseSwiftCommitsAndSkipsWithNotInWorkspaceNote() async throws {
        try await MultiProjectWorkspace.withMultiProjectRoot(named: "MultiProjectLoose") { root in
            try await withSession(root: root) { tool, context in
                let output = try await DiagnosticsProbe.callTool(
                    tool,
                    arguments: editIntroducingTypeError(at: root.looseSwift)
                )
                let decoded = DiagnosticsProbe.diagnostics(fromToolOutput: output)
                #expect(
                    decoded?.status == IntegrationWire.skipped,
                    "Loose.swift should be skipped, got \(String(describing: decoded?.status))"
                )
                #expect(
                    decoded?.note == DiagnosticsBridge.notInWorkspaceNote,
                    "Loose.swift should carry the not-in-a-git-workspace note, got \(String(describing: decoded?.note))"
                )

                let onDisk = try String(contentsOf: root.looseSwift, encoding: .utf8)
                #expect(
                    onDisk.contains("let value: Int = \"s\""),
                    "the Loose.swift mutation must be committed even though diagnostics are skipped"
                )

                let openRoots = await context.diagnostics.openRootDirectories()
                #expect(
                    openRoots.isEmpty,
                    "a loose file outside any repository must open no context, got \(openRoots.map(\.path))"
                )
            }
        }
    }

    /// Editing the stray `notes.md` (no language server handles the extension)
    /// commits the mutation and reports `skipped` with the non-diagnosable note,
    /// opening no context — the bridge gates before ever touching the manager.
    @Test func editingNotesMarkdownSkipsAndOpensNoContext() async throws {
        try await MultiProjectWorkspace.withMultiProjectRoot(named: "MultiProjectNotes") { root in
            try await withSession(root: root) { tool, context in
                let output = try await DiagnosticsProbe.callTool(
                    tool,
                    arguments: DiagnosticsProbe.payload([
                        ("op", "edit file"),
                        ("filePath", root.notesMarkdown.path),
                        ("find", ["# Notes"]),
                        ("replace", ["# Notes (updated)"]),
                    ])
                )
                let decoded = DiagnosticsProbe.diagnostics(fromToolOutput: output)
                #expect(
                    decoded?.status == IntegrationWire.skipped,
                    "notes.md should be skipped, got \(String(describing: decoded?.status))"
                )
                #expect(
                    decoded?.note == DiagnosticsBridge.nonDiagnosableNote,
                    "notes.md should carry the non-diagnosable note, got \(String(describing: decoded?.note))"
                )

                let onDisk = try String(contentsOf: root.notesMarkdown, encoding: .utf8)
                #expect(onDisk.contains("# Notes (updated)"), "the notes.md mutation must be committed")

                let openRoots = await context.diagnostics.openRootDirectories()
                #expect(
                    openRoots.isEmpty,
                    "a non-diagnosable file must open no context, got \(openRoots.map(\.path))"
                )
            }
        }
    }

    // MARK: - Session lifecycle

    /// Runs `body` against a fused `files` tool over a fresh ``FileContext`` rooted
    /// at the multi-project session root, tearing the context down on every exit
    /// path so the real language server is never leaked.
    ///
    /// - Parameters:
    ///   - root: the multi-project session root the context is rooted at.
    ///   - body: the work to run against the fused tool and its context.
    /// - Throws: rethrows whatever tool construction or `body` throws.
    private func withSession(
        root: MultiProjectRoot,
        _ body: (FusedFilesTool, FileContext) async throws -> Void
    ) async throws {
        let context = FileContext(root: root.sessionRoot)
        do {
            let tool = try FileTool.make(context: context)
            try await body(tool, context)
        } catch {
            await context.stop()
            throw error
        }
        await context.stop()
    }

    // MARK: - Polling

    /// Polls the bridge's open roots until they include every path in `target`, or
    /// the deadline elapses, returning the last observed set.
    ///
    /// A real manager records an opened root as its context comes up; this bounds
    /// the wait on that with a generous deadline rather than a timing assertion,
    /// so a slow real server still converges deterministically. It waits only for
    /// `target` to be *included*; the caller then asserts the exact set, so a
    /// spurious extra root still fails the row rather than being polled away.
    ///
    /// - Parameters:
    ///   - context: the session context whose bridge open roots to poll.
    ///   - target: the normalized paths that must all be open before returning.
    ///   - deadline: the overall time budget before giving up.
    ///   - pollInterval: how long to sleep between polls.
    /// - Returns: the last observed open roots.
    private func awaitOpenRoots(
        from context: FileContext,
        including target: Set<String>,
        deadline: Duration = MultiProjectTests.openRootsDeadline,
        pollInterval: Duration = MultiProjectTests.openRootsPollInterval
    ) async -> [URL] {
        let clock = ContinuousClock()
        let end = clock.now.advanced(by: deadline)
        var last = await context.diagnostics.openRootDirectories()
        while true {
            if normalizedPaths(last).isSuperset(of: target) {
                return last
            }
            guard clock.now < end else {
                return last
            }
            try? await Task.sleep(for: pollInterval)
            last = await context.diagnostics.openRootDirectories()
        }
    }

    /// Nudges the PackageA caller into re-indexing and polls until its folded
    /// error settles, or returns the last observed result at the deadline.
    ///
    /// Each iteration re-writes the caller with only a trailing comment changed
    /// (its call to the provider untouched, so its error is entirely a consequence
    /// of the provider's changed signature), marking it dirty so the watcher
    /// re-records its call edge once the semantic index is ready. It then
    /// diagnoses the provider with `includeDependents`, returning as soon as the
    /// caller's real "missing argument" error is folded in. No timing is asserted.
    ///
    /// - Parameters:
    ///   - context: the session context whose bridge folds in dependents.
    ///   - package: the package whose provider/caller pair is under test.
    /// - Returns: the settled diagnostics with the folded caller error, or the
    ///   last observed result if it never converged within the deadline.
    private func awaitFoldedCallerError(
        context: FileContext,
        package: ScaffoldedSwiftPackage
    ) async -> FileDiagnostics? {
        let clock = ContinuousClock()
        let end = clock.now.advanced(by: Self.dependentDeadline)
        var lastResult: FileDiagnostics?
        var nudge = 0
        while true {
            nudge += 1
            try? IsolatedWorkspace.write(
                PackageSources.dependentCallerSource + "\n// index refresh \(nudge)\n",
                to: package.dependentCaller
            )
            if let result = await context.diagnostics.diagnose(fileAt: package.dependentProvider) {
                lastResult = result
                if result.status == IntegrationWire.errors,
                    result.items.contains(where: { item in
                        item.file.hasSuffix("Caller.swift")
                            && item.message.localizedCaseInsensitiveContains("argument")
                    }) {
                    return result
                }
            }
            guard clock.now < end else {
                return lastResult
            }
            try? await Task.sleep(for: Self.dependentNudgeInterval)
        }
    }

    // MARK: - Assertions

    /// Asserts a dispatched operation's JSON output carried a diagnostics object,
    /// proving live diagnostics ride back through the fused tool.
    ///
    /// - Parameters:
    ///   - output: the operation's JSON-encoded output.
    ///   - label: the row label for diagnostic messages.
    private func expectDispatchedDiagnostics(_ output: String, label: String) {
        #expect(
            DiagnosticsProbe.diagnostics(fromToolOutput: output) != nil,
            "\(label): the operation output carried no diagnostics object"
        )
    }

    /// Asserts a settled result is an `errors` report with an error item under the
    /// given package directory, ending in the given file, and carrying every
    /// expected message fragment.
    ///
    /// The item path must be a session-root-relative path *into the correct
    /// package* (`<packageDirectory>/…`), which is exactly what proves the bridge
    /// rebased the record path against the session root rather than the package.
    ///
    /// - Parameters:
    ///   - diagnostics: the settled diagnostics to assert on.
    ///   - packageDirectory: the session-root child directory the item must sit under.
    ///   - fileSuffix: the file name the item's path must end with.
    ///   - messageContains: message fragments the item must carry (case-insensitive).
    ///   - label: the row label for diagnostic messages.
    private func requireErrorItem(
        _ diagnostics: FileDiagnostics?,
        packageDirectory: String,
        fileSuffix: String,
        messageContains: [String],
        label: String
    ) {
        guard let diagnostics else {
            Issue.record("\(label): diagnostics never settled to the expected errors within deadline")
            return
        }
        #expect(
            diagnostics.status == IntegrationWire.errors,
            "\(label): expected errors, got \(diagnostics.status) (note: \(diagnostics.note ?? "nil"))"
        )
        let match = diagnostics.items.first { item in
            item.file.hasPrefix(packageDirectory + "/")
                && item.file.hasSuffix(fileSuffix)
                && messageContains.allSatisfy { item.message.localizedCaseInsensitiveContains($0) }
        }
        guard let match else {
            let summary = diagnostics.items.map { "\($0.file): \($0.message)" }
            Issue.record(
                "\(label): no error item under \(packageDirectory)/ ending \(fileSuffix) carried all of \(messageContains); items were \(summary)"
            )
            return
        }
        #expect(match.line >= 1, "\(label): expected a one-based line, got \(match.line)")
        #expect(match.column >= 1, "\(label): expected a one-based column, got \(match.column)")
    }

    /// Asserts no diagnostic item in a report references the given package
    /// directory — the cross-project isolation guarantee.
    ///
    /// - Parameters:
    ///   - diagnostics: the report to check (a `nil`/absent report trivially holds).
    ///   - packageDirectory: the session-root child directory that must not appear.
    ///   - label: the row label for diagnostic messages.
    private func expectNoPath(
        _ diagnostics: FileDiagnostics?,
        intoPackageDirectory packageDirectory: String,
        label: String
    ) {
        guard let diagnostics else {
            return
        }
        let leaked = diagnostics.items.filter { $0.file.hasPrefix(packageDirectory + "/") }
        #expect(
            leaked.isEmpty,
            "\(label): cross-project leak — items referenced \(packageDirectory): \(leaked.map(\.file))"
        )
    }

    // MARK: - Payload and path helpers

    /// A `let value: Int = "s"` type-error `edit file` payload for a seeded
    /// ``PackageSources/typeRowSource``-shaped file.
    ///
    /// - Parameter fileURL: the file to introduce the type error into.
    /// - Returns: the `edit file` payload.
    private func editIntroducingTypeError(at fileURL: URL) -> GeneratedContent {
        DiagnosticsProbe.payload([
            ("op", "edit file"),
            ("filePath", fileURL.path),
            ("find", ["let value = 1"]),
            ("replace", ["let value: Int = \"s\""]),
        ])
    }

    /// The `realpath`-consistent, trailing-slash-free path string of a URL, for
    /// order-independent open-roots comparison.
    ///
    /// The session root is canonicalized up front and the manager records roots by
    /// their resolved on-disk path, so normalizing both sides this way compares
    /// them as sets without depending on URL trailing-slash or symlink form.
    ///
    /// - Parameter url: the URL to normalize.
    /// - Returns: the normalized path string.
    private func normalizedPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// The set of ``normalizedPath(_:)`` strings of a URL list.
    ///
    /// - Parameter urls: the URLs to normalize.
    /// - Returns: the set of normalized path strings.
    private func normalizedPaths(_ urls: [URL]) -> Set<String> {
        Set(urls.map(normalizedPath))
    }
}

/// The fused `files` tool type the matrix rows dispatch against.
///
/// A one-name alias for the concrete `OperationTool<FileContext>` the rows share,
/// matching suite A's ``ErrorDetectionTests`` convention.
private typealias FusedFilesTool = Operations.OperationTool<FileContext>
