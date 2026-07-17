import Foundation
import Operations
import Testing

@testable import FileTool

/// The `sourcekit-lsp` CI gate, kept in a suite of its own so it runs whether or
/// not the language server is present.
///
/// The real-LSP matrix (``ErrorDetectionTests``) is gated with an `.enabled(if:)`
/// trait, so it *skips* when `sourcekit-lsp` is missing. That is the right local
/// behavior, but a skip is invisible in CI — so this always-enabled test turns a
/// missing `sourcekit-lsp` into a hard failure whenever `CI` is set, ensuring the
/// LSP tier can never quietly vanish from a CI run (plan §9.6).
@Suite struct SourceKitLSPGateTests {
    @Test func continuousIntegrationFailsWhenSourceKitLSPIsMissing() {
        guard LSPGate.isRunningInContinuousIntegration, !LSPGate.isSourceKitLSPAvailable else {
            // Either not in CI (local skip is fine) or sourcekit-lsp is present
            // (the matrix runs). Nothing to fail.
            return
        }
        Issue.record(
            "CI requires sourcekit-lsp, but `xcrun --find sourcekit-lsp` failed; the real-LSP integration tier must never silently skip in CI"
        )
    }
}

/// The real-`sourcekit-lsp` error-detection matrix: every row drives a real
/// mutation through full `AnyOperation` dispatch against one warm
/// ``FileContext`` (real ``DiagnosticsBridge`` + real `CodeContextManager`) and
/// asserts on the *actual* compiler message the language server reports, proving
/// live diagnostics flow all the way back through the fused `files` tool.
///
/// Structure and robustness:
///
/// - **One warm context per suite, not per test.** The six warm rows share a
///   single eagerly-warmed context inside ``errorDetectionMatrix()`` (wall-clock
///   budget); its ``FileContext/stop()`` runs on every exit path, so the real
///   language server is never leaked. The two cold-start rows deliberately spin
///   up their own cold contexts — a cold workspace is exactly what a `pending`
///   result needs — and each tears its own context down.
/// - **No timing assertions.** A real language server settles on its own
///   wall-clock, so every settled expectation converges via bounded polling
///   (``DiagnosticsProbe/awaitDiagnostics(from:fileAt:deadline:pollInterval:until:)``)
///   under a generous deadline; the only injected tiny hard timeout is the
///   cold-start `pending` row's, and it asserts `pending`, never a duration.
/// - **Per-row isolation.** Each row mutates its own target's file (the scaffold
///   is one library target per row), so a broken file never leaks errors into
///   another row and the `.serialized` suite is order-independent.
@Suite(.serialized, .enabled(if: LSPGate.isSourceKitLSPAvailable, Comment(rawValue: LSPGate.skipMessage)))
struct ErrorDetectionTests {
    // MARK: - Tuning

    /// A deliberately tiny hard timeout that forces an honest `pending` on a cold
    /// workspace: no real settle can complete inside it, so the settle engine
    /// times out and the report is flagged pending (the mutation still commits).
    private static let tinyHardTimeout: Duration = .milliseconds(1)

    /// The generous overall deadline the dependent-breakage row polls within.
    ///
    /// This row is the slowest: the caller's error is folded in via the LSP
    /// call-edge index, which on a cold package is only reliably built once
    /// sourcekit-lsp's semantic index is ready, so it warrants a larger budget
    /// than the single-file rows.
    private static let dependentDeadline: Duration = .seconds(240)

    /// How long to wait between caller-nudge/poll iterations in the
    /// dependent-breakage row, giving the file watcher and LSP index worker time
    /// to re-index the nudged caller before the next diagnostics pass.
    private static let dependentNudgeInterval: Duration = .seconds(3)

    // MARK: - Warm matrix

    @Test func errorDetectionMatrix() async throws {
        let package = try IsolatedWorkspace.scaffoldSwiftPackage(named: "ErrorDetectionWarm")
        defer { IsolatedWorkspace.remove(package.root) }

        // One warm context, shared by every row below; stopped on every exit path.
        let context = FileContext(root: package.root, eagerWarmup: true)
        do {
            try await warmUp(context: context, package: package)
            let tool = try FileTool.make(context: context)

            await runSyntaxErrorRow(tool: tool, context: context, package: package)
            await runTypeErrorRow(tool: tool, context: context, package: package)
            await runUnresolvedIdentifierWriteRow(tool: tool, context: context, package: package)
            await runWarningOnlyRow(tool: tool, context: context, package: package)
            await runDependentBreakageRow(tool: tool, context: context, package: package)
            await runItemCapRow(tool: tool, context: context, package: package)
        } catch {
            await context.stop()
            throw error
        }
        await context.stop()
    }

    /// Awaits the eager warm-up and polls a known-clean file until the workspace
    /// settles, so the matrix rows run against a ready language server.
    private func warmUp(context: FileContext, package: ScaffoldedSwiftPackage) async throws {
        await context.diagnostics.warmUpTask?.value
        let settled = await DiagnosticsProbe.awaitDiagnostics(
            from: context.diagnostics,
            fileAt: package.dependentProvider,
            deadline: .seconds(180)
        ) { diagnostics in diagnostics.status != "pending" }
        #expect(settled != nil, "warm-up never produced a diagnostics result within budget")
        #expect(settled?.status != "pending", "warm-up never settled the workspace within budget")
    }

    // MARK: - Rows

    /// Edit introduces a syntax error (an unbalanced brace) → `errors` with a
    /// real parser message and a real line.
    private func runSyntaxErrorRow(
        tool: FusedFilesTool,
        context: FileContext,
        package: ScaffoldedSwiftPackage
    ) async {
        let output = try? await DiagnosticsProbe.callTool(
            tool,
            arguments: DiagnosticsProbe.payload([
                ("op", "edit file"),
                ("filePath", package.syntaxRow.path),
                ("find", ["func syntaxRowValue() -> Int {"]),
                ("replace", ["func syntaxRowValue() -> Int { {"]),
            ])
        )
        expectDispatchedDiagnostics(output, label: "syntax error")

        let settled = await DiagnosticsProbe.awaitDiagnostics(
            from: context.diagnostics,
            fileAt: package.syntaxRow
        ) { diagnostics in diagnostics.status == "errors" && !diagnostics.items.isEmpty }

        assertRealErrors(
            settled,
            expectedFileSuffix: "SyntaxRow.swift",
            messageContains: ["expected"],
            label: "syntax error"
        )
    }

    /// Edit introduces a type error (`let x: Int = "s"`) → detected, with the
    /// real "cannot convert" message.
    private func runTypeErrorRow(
        tool: FusedFilesTool,
        context: FileContext,
        package: ScaffoldedSwiftPackage
    ) async {
        let output = try? await DiagnosticsProbe.callTool(
            tool,
            arguments: DiagnosticsProbe.payload([
                ("op", "edit file"),
                ("filePath", package.typeRow.path),
                ("find", ["let value = 1"]),
                ("replace", ["let value: Int = \"s\""]),
            ])
        )
        expectDispatchedDiagnostics(output, label: "type error")

        let settled = await DiagnosticsProbe.awaitDiagnostics(
            from: context.diagnostics,
            fileAt: package.typeRow
        ) { diagnostics in
            diagnostics.status == "errors"
                && diagnostics.items.contains { $0.message.localizedCaseInsensitiveContains("cannot convert") }
        }

        assertRealErrors(
            settled,
            expectedFileSuffix: "TypeRow.swift",
            messageContains: ["cannot convert", "Int"],
            label: "type error"
        )
    }

    /// Write a brand-new file with an unresolved identifier → detected, with the
    /// real "cannot find … in scope" message.
    private func runUnresolvedIdentifierWriteRow(
        tool: FusedFilesTool,
        context: FileContext,
        package: ScaffoldedSwiftPackage
    ) async {
        let output = try? await DiagnosticsProbe.callTool(
            tool,
            arguments: DiagnosticsProbe.payload([
                ("op", "write file"),
                ("filePath", package.writeRowFile.path),
                ("content", "let orphanValue = undefinedOrphanSymbol\n"),
            ])
        )
        expectDispatchedDiagnostics(output, label: "unresolved-identifier write")

        let settled = await DiagnosticsProbe.awaitDiagnostics(
            from: context.diagnostics,
            fileAt: package.writeRowFile
        ) { diagnostics in
            diagnostics.status == "errors"
                && diagnostics.items.contains { $0.message.localizedCaseInsensitiveContains("cannot find") }
        }

        assertRealErrors(
            settled,
            expectedFileSuffix: "Orphan.swift",
            messageContains: ["cannot find", "undefinedOrphanSymbol"],
            label: "unresolved-identifier write"
        )
    }

    /// Warning-only edit (an unused immutable value) → `warnings`, zero errors;
    /// the severity floor surfaces the warning.
    private func runWarningOnlyRow(
        tool: FusedFilesTool,
        context: FileContext,
        package: ScaffoldedSwiftPackage
    ) async {
        let output = try? await DiagnosticsProbe.callTool(
            tool,
            arguments: DiagnosticsProbe.payload([
                ("op", "edit file"),
                ("filePath", package.warningRow.path),
                ("find", ["    performWork()"]),
                ("replace", ["    let unusedWarningValue = 5\n    performWork()"]),
            ])
        )
        expectDispatchedDiagnostics(output, label: "warning-only")

        let settled = await DiagnosticsProbe.awaitDiagnostics(
            from: context.diagnostics,
            fileAt: package.warningRow
        ) { diagnostics in
            diagnostics.status == "warnings"
                && diagnostics.items.contains { $0.message.localizedCaseInsensitiveContains("never used") }
        }

        guard let settled else {
            Issue.record("warning-only: diagnostics never settled to warnings within deadline")
            return
        }
        #expect(settled.status == "warnings", "warning-only: expected warnings, got \(settled.status)")
        #expect(settled.errors == 0, "warning-only: expected zero errors, got \(settled.errors)")
        #expect(settled.warnings > 0, "warning-only: expected a positive warning count")
        let warningItem = settled.items.first { $0.message.localizedCaseInsensitiveContains("never used") }
        #expect(warningItem?.severity == "warning", "warning-only: item was not warning severity")
        #expect(warningItem != nil, "warning-only: no 'never used' warning present")
    }

    /// Edit changes a function's signature in the provider → the caller's error
    /// in the *other* file is folded in via `includeDependents`.
    private func runDependentBreakageRow(
        tool: FusedFilesTool,
        context: FileContext,
        package: ScaffoldedSwiftPackage
    ) async {
        let output = try? await DiagnosticsProbe.callTool(
            tool,
            arguments: DiagnosticsProbe.payload([
                ("op", "edit file"),
                ("filePath", package.dependentProvider.path),
                ("find", ["public func compute() -> Int {"]),
                ("replace", ["public func compute(_ operand: Int) -> Int {"]),
            ])
        )
        expectDispatchedDiagnostics(output, label: "dependent breakage")

        // The caller's error is folded in via `includeDependents`, which resolves
        // dependents from the LSP call-edge index. On a cold package, `start()`'s
        // initial call-edge drain can run before sourcekit-lsp's semantic index is
        // ready, recording no edge for the caller and never retrying it — so the
        // fold-in would never happen no matter how long we poll. Re-writing the
        // caller (its code unchanged; only a trailing comment differs, so its
        // error stays entirely a consequence of the provider's signature change)
        // marks it dirty, so the watcher re-indexes it once the semantic index is
        // ready and the call edge is finally recorded. We nudge-and-poll under a
        // generous deadline — no timing assertion — until the real caller error is
        // folded in.
        let settled = await awaitFoldedCallerError(context: context, package: package)

        guard let settled else {
            Issue.record("dependent breakage: diagnostics never folded in the caller's error within deadline")
            return
        }
        #expect(settled.status == "errors", "dependent breakage: expected errors, got \(settled.status)")
        let callerItem = settled.items.first { $0.file.hasSuffix("Caller.swift") }
        guard let callerItem else {
            Issue.record(
                "dependent breakage: no diagnostic for the caller file was folded in; items were \(settled.items.map(\.file))"
            )
            return
        }
        #expect(
            callerItem.message.localizedCaseInsensitiveContains("argument"),
            "dependent breakage: caller message '\(callerItem.message)' did not mention the missing argument"
        )
        #expect(callerItem.line >= 1, "dependent breakage: expected a one-based caller line")
    }

    /// Nudges the caller into re-indexing and polls until its folded error settles.
    ///
    /// Each iteration re-writes the caller with only a trailing comment changed
    /// (its call to the provider is untouched, so its error is entirely a
    /// consequence of the provider's changed signature), which marks it dirty so
    /// the file watcher and LSP index worker re-record its call edge once
    /// sourcekit-lsp's semantic index is ready. It then diagnoses the provider
    /// with `includeDependents`, returning as soon as the caller's real
    /// "missing argument" error is folded in, or the last observed result at the
    /// deadline. No timing is asserted — only bounded convergence.
    ///
    /// - Parameters:
    ///   - context: the warm session context whose bridge folds in dependents.
    ///   - package: the scaffolded package whose provider/caller pair is under test.
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
                if result.status == "errors",
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

    /// Write an error-storm file (many unresolved identifiers) → the item list is
    /// capped while the true error count exceeds the cap.
    private func runItemCapRow(
        tool: FusedFilesTool,
        context: FileContext,
        package: ScaffoldedSwiftPackage
    ) async {
        let output = try? await DiagnosticsProbe.callTool(
            tool,
            arguments: DiagnosticsProbe.payload([
                ("op", "write file"),
                ("filePath", package.stormRow.path),
                ("content", PackageSources.errorStormSource),
            ])
        )
        expectDispatchedDiagnostics(output, label: "item cap")

        let cap = DiagnosticsBridge.maximumReportedItemCount
        let settled = await DiagnosticsProbe.awaitDiagnostics(
            from: context.diagnostics,
            fileAt: package.stormRow
        ) { diagnostics in diagnostics.status == "errors" && diagnostics.errors > cap }

        guard let settled else {
            Issue.record("item cap: diagnostics never reported more than \(cap) errors within deadline")
            return
        }
        #expect(settled.status == "errors", "item cap: expected errors, got \(settled.status)")
        #expect(settled.errors > cap, "item cap: expected more than \(cap) true errors, got \(settled.errors)")
        #expect(
            settled.items.count == cap,
            "item cap: item list should be capped at \(cap), got \(settled.items.count)"
        )
        #expect(
            settled.items.contains { $0.message.localizedCaseInsensitiveContains("cannot find") },
            "item cap: capped items carried no real 'cannot find' message"
        )
    }

    // MARK: - Cold-start pending

    /// Cold-start `pending`: a bridge with an injected tiny hard timeout yields an
    /// honest `pending` result (with a note), and the mutation is still committed.
    @Test func coldStartYieldsPendingWithCommittedMutation() async throws {
        let package = try IsolatedWorkspace.scaffoldSwiftPackage(named: "ColdStartPending")
        defer { IsolatedWorkspace.remove(package.root) }

        let tinyBridge = DiagnosticsBridge(root: package.root, hardTimeout: Self.tinyHardTimeout)
        let context = FileContext(root: package.root, readOnly: false, allowSymlinks: false, diagnostics: tinyBridge)
        do {
            let tool = try FileTool.make(context: context)
            let output = try await DiagnosticsProbe.callTool(
                tool,
                arguments: DiagnosticsProbe.payload([
                    ("op", "edit file"),
                    ("filePath", package.typeRow.path),
                    ("find", ["let value = 1"]),
                    ("replace", ["let value: Int = \"s\""]),
                ])
            )

            let decoded = DiagnosticsProbe.diagnostics(fromToolOutput: output)
            #expect(decoded?.status == "pending", "cold start with a tiny hard timeout should be pending, got \(String(describing: decoded?.status))")
            #expect(decoded?.note != nil, "a pending result must carry an explanatory note")

            let onDisk = try String(contentsOf: package.typeRow, encoding: .utf8)
            #expect(
                onDisk.contains("let value: Int = \"s\""),
                "the mutation must be committed even when diagnostics are pending"
            )
        } catch {
            await context.stop()
            throw error
        }
        await context.stop()
    }

    /// Pending-then-settled (plan §9.2): after a cold `pending`, re-running the
    /// diagnostics with default timeouts and polling converges on the real
    /// settled errors on the same cold workspace.
    ///
    /// Both bridges share one `CodeContextManager` (one real language server): the
    /// tiny-timeout bridge drives the operation to `pending`, the default-timeout
    /// bridge polls the same workspace to settled. ``FileContext/stop()`` on the
    /// operation's context shuts the shared manager down (both bridges), so no
    /// language server leaks.
    @Test func pendingThenSettledPollsToRealErrors() async throws {
        let package = try IsolatedWorkspace.scaffoldSwiftPackage(named: "PendingThenSettled")
        defer { IsolatedWorkspace.remove(package.root) }

        let resolver = ManagerDiagnosticsResolver(embedder: NullEmbedder())
        let tinyBridge = DiagnosticsBridge(
            root: package.root,
            mode: .enabled,
            eagerWarmup: false,
            resolver: resolver,
            settleWindow: DiagnosticsBridge.defaultSettleWindow,
            hardTimeout: Self.tinyHardTimeout,
            perReportCap: DiagnosticsBridge.defaultCountingPerReportCap
        )
        let fullBridge = DiagnosticsBridge(
            root: package.root,
            mode: .enabled,
            eagerWarmup: false,
            resolver: resolver,
            settleWindow: DiagnosticsBridge.defaultSettleWindow,
            hardTimeout: DiagnosticsBridge.defaultHardTimeout,
            perReportCap: DiagnosticsBridge.defaultCountingPerReportCap
        )
        let context = FileContext(root: package.root, readOnly: false, allowSymlinks: false, diagnostics: tinyBridge)
        do {
            let tool = try FileTool.make(context: context)

            // Phase 1: cold + tiny hard timeout → honest pending, mutation committed.
            let output = try await DiagnosticsProbe.callTool(
                tool,
                arguments: DiagnosticsProbe.payload([
                    ("op", "edit file"),
                    ("filePath", package.typeRow.path),
                    ("find", ["let value = 1"]),
                    ("replace", ["let value: Int = \"s\""]),
                ])
            )
            let phase1 = DiagnosticsProbe.diagnostics(fromToolOutput: output)
            #expect(phase1?.status == "pending", "phase 1 should be pending on the cold workspace, got \(String(describing: phase1?.status))")

            // Phase 2: default timeouts, polling until the real errors settle.
            let settled = await DiagnosticsProbe.awaitDiagnostics(
                from: fullBridge,
                fileAt: package.typeRow
            ) { diagnostics in
                diagnostics.status == "errors"
                    && diagnostics.items.contains { $0.message.localizedCaseInsensitiveContains("cannot convert") }
            }

            assertRealErrors(
                settled,
                expectedFileSuffix: "TypeRow.swift",
                messageContains: ["cannot convert", "Int"],
                label: "pending-then-settled"
            )
        } catch {
            await context.stop()
            throw error
        }
        await context.stop()
    }

    // MARK: - Assertions

    /// Asserts a dispatched operation's JSON output carried a diagnostics object,
    /// proving live diagnostics ride back through the fused tool.
    private func expectDispatchedDiagnostics(_ output: String?, label: String) {
        guard let output else {
            Issue.record("\(label): the operation dispatch produced no output")
            return
        }
        #expect(
            DiagnosticsProbe.diagnostics(fromToolOutput: output) != nil,
            "\(label): the operation output carried no diagnostics object"
        )
    }

    /// Asserts a settled diagnostics result is an `errors` report whose real
    /// message content and one-based line match the expected file.
    private func assertRealErrors(
        _ diagnostics: FileDiagnostics?,
        expectedFileSuffix: String,
        messageContains: [String],
        label: String
    ) {
        guard let diagnostics else {
            Issue.record("\(label): diagnostics never settled to the expected errors within deadline")
            return
        }
        #expect(diagnostics.status == "errors", "\(label): expected errors, got \(diagnostics.status) (note: \(diagnostics.note ?? "nil"))")
        #expect(diagnostics.errors > 0, "\(label): expected a positive error count")

        let matching = diagnostics.items.first { item in
            item.file.hasSuffix(expectedFileSuffix)
                && messageContains.allSatisfy { item.message.localizedCaseInsensitiveContains($0) }
        }
        guard let item = matching else {
            let itemSummary = diagnostics.items.map { "\($0.file): \($0.message)" }
            Issue.record(
                "\(label): no error item for \(expectedFileSuffix) carried all of \(messageContains); items were \(itemSummary)"
            )
            return
        }
        #expect(item.line >= 1, "\(label): expected a one-based line, got \(item.line)")
        #expect(item.column >= 1, "\(label): expected a one-based column, got \(item.column)")
    }
}

/// The fused `files` tool type the matrix rows dispatch against.
///
/// A one-name alias for the concrete `OperationTool<FileContext>` the rows share,
/// so their signatures read as the tool they drive rather than restating the
/// generic each time.
private typealias FusedFilesTool = Operations.OperationTool<FileContext>
