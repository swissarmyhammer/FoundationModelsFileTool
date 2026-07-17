import Foundation
import FoundationModels
import Operations
import Testing

@testable import FileTool

// MARK: - Combined integration-tier wall-clock budget
//
// The isolated-directory integration tier is real: suites A (``ErrorDetectionTests``)
// and B (``EditsOKTests`` + ``CrossOpFlowTests``) each stand up a live
// `sourcekit-lsp` against a scaffolded, compiling Swift package, so their cost is
// dominated by language-server start-up and settle, not by CPU. The tier is
// budgeted in *bounded polling*, never in exact-timing assertions:
//
// - Each suite warms one shared context once (warm-up polls up to 180 s for the
//   server to settle a known-clean file), then reuses it for every row — no
//   per-row re-warm.
// - Every settled expectation converges via
//   ``DiagnosticsProbe/awaitDiagnostics(from:fileAt:deadline:pollInterval:until:)``
//   under a generous deadline (≤120 s per settle here), so a slow-but-correct
//   server still passes; nothing asserts a duration.
//
// Rough wall-clock envelope for the whole tier (A + B), cold, on a developer
// machine: on the order of five to fifteen minutes, essentially all of it real
// `sourcekit-lsp` start-up and re-index time across the three warm contexts and
// the error-then-fix re-settles. Warm re-runs are far faster. CI must never skip
// the tier (``SourceKitLSPGateTests`` enforces that); locally it skips cleanly
// when `sourcekit-lsp` is absent (the `.enabled(if:)` trait below).

/// The real-`sourcekit-lsp` edits-OK matrix: every clean-preserving mutation
/// path drives a real op through full `AnyOperation` dispatch against one warm
/// ``FileContext`` and asserts the live diagnostics settle to `clean`, plus the
/// gate rows that must *never* engage the bridge at all.
///
/// Structure and robustness mirror suite A:
///
/// - **One warm context per suite.** ``editsOKMatrix()`` warms a single context
///   over a scaffolded ``CleanEditPackage`` and reuses it for every rung; its
///   ``FileContext/stop()`` runs on every exit path, so the real language server
///   is never leaked.
/// - **No timing assertions.** Every rung converges to `clean` (or, for the
///   error-then-fix rung, to `errors` then back to `clean`) via bounded polling
///   under a generous deadline.
/// - **Per-rung isolation.** Each rung owns its own file, and every clean rung
///   rewrites its file to fresh valid Swift first, so the rungs are
///   order-independent and the `.serialized` suite never leaks a diagnostic
///   between rows. The one rung that transiently breaks the build
///   (``runErrorThenFixRow(tool:context:package:)``) lives in its own package
///   target and repairs itself before the row ends.
/// - **Gate rows on fresh contexts.** The non-diagnosable and read-only rows use
///   their own cold contexts (a warm context has already opened a root) and
///   assert the bridge was never engaged, so they need no settled server.
@Suite(.serialized, .enabled(if: LSPGate.isSourceKitLSPAvailable, Comment(rawValue: LSPGate.skipMessage)))
struct EditsOKTests {
    // MARK: - Tuning

    /// The generous deadline the shared context's warm-up polls a known-clean file within.
    private static let warmUpDeadline: Duration = .seconds(180)

    /// The generous deadline the error-then-fix rung polls each settle within.
    ///
    /// The break and the repair each mark the file dirty and wait for the real
    /// server to re-index and re-settle, so this warrants a larger budget than a
    /// single clean rung's default poll.
    private static let roundTripDeadline: Duration = .seconds(180)

    // MARK: - Warm matrix

    @Test func editsOKMatrix() async throws {
        let package = try CleanEditPackage.scaffold(named: "EditsOKWarm")
        defer { IsolatedWorkspace.remove(package.root) }

        // One warm context, shared by every rung below; stopped on every exit path.
        let context = FileContext(root: package.root, eagerWarmup: true)
        do {
            try await warmUp(context: context, package: package)
            let tool = try FileTool.make(context: context)

            await runCleanWriteRow(tool: tool, context: context, package: package)
            await runAnchorRow(tool: tool, context: context, package: package)
            await runLiteralRow(tool: tool, context: context, package: package)
            await runRecoveredRow(tool: tool, context: context, package: package)
            await runReplaceAllRow(tool: tool, context: context, package: package)
            await runOccurrenceRow(tool: tool, context: context, package: package)
            await runMultiPairBatchRow(tool: tool, context: context, package: package)
            await runErrorThenFixRow(tool: tool, context: context, package: package)
        } catch {
            await context.stop()
            throw error
        }
        await context.stop()
    }

    /// Awaits the eager warm-up and polls a known-clean seed until the workspace
    /// settles, so the matrix rungs run against a ready language server.
    ///
    /// - Parameters:
    ///   - context: the shared warm context whose bridge is being warmed.
    ///   - package: the scaffolded clean-edit package.
    /// - Throws: never; the signature is `throws` only to fit the matrix's `do`.
    private func warmUp(context: FileContext, package: ScaffoldedCleanEditPackage) async throws {
        await context.diagnostics.warmUpTask?.value
        let settled = await DiagnosticsProbe.awaitDiagnostics(
            from: context.diagnostics,
            fileAt: package.cleanWrite,
            deadline: Self.warmUpDeadline
        ) { diagnostics in diagnostics.status != IntegrationWire.pending }
        #expect(settled != nil, "warm-up never produced a diagnostics result within budget")
        #expect(settled?.status != IntegrationWire.pending, "warm-up never settled the workspace within budget")
    }

    // MARK: - Clean-write row

    /// A clean write of a valid Swift file lands its exact bytes and settles to `clean`.
    ///
    /// - Parameters:
    ///   - tool: the fused `files` tool.
    ///   - context: the shared warm context.
    ///   - package: the scaffolded clean-edit package.
    private func runCleanWriteRow(tool: FusedFilesTool, context: FileContext, package: ScaffoldedCleanEditPackage) async {
        let content = "let cleanWriteRowValue = 41\n"
        let output = try? await callWrite(tool, path: package.cleanWrite.path, content: content)
        expectDispatchedResult(output, label: "clean write")
        expectOnDisk(package.cleanWrite, equals: content, label: "clean write")
        await expectSettlesClean(context: context, fileURL: package.cleanWrite, label: "clean write")
    }

    // MARK: - Cascade rungs

    /// The anchor rung: an anchor lifted from the write envelope resolves the edit.
    private func runAnchorRow(tool: FusedFilesTool, context: FileContext, package: ScaffoldedCleanEditPackage) async {
        let content = "func anchorRowValue() -> Int {\n    return 1\n}\n"
        guard let writeOutput = try? await callWrite(tool, path: package.anchor.path, content: content),
            let writeResult = OperationOutput.decode(DecodedWriteResult.self, from: writeOutput),
            writeResult.taggedContent.count >= 2
        else {
            Issue.record("anchor: the setup write did not return a hashline-tagged body")
            return
        }
        // The second tagged line ("2:HH|    return 1") is the anchor the edit lifts.
        let anchor = writeResult.taggedContent[1]

        let output = try? await DiagnosticsProbe.callTool(
            tool,
            arguments: DiagnosticsProbe.payload([
                ("op", "edit file"),
                ("filePath", package.anchor.path),
                ("find", [anchor]),
                ("replace", ["    return 2"]),
            ])
        )
        expectApplied(output, matchedBy: IntegrationWire.anchorMatch, appliedCount: 1, label: "anchor")
        expectOnDisk(package.anchor, equals: "func anchorRowValue() -> Int {\n    return 2\n}\n", label: "anchor")
        await expectSettlesClean(context: context, fileURL: package.anchor, label: "anchor")
    }

    /// The literal rung: a byte-exact `find` resolves the edit.
    private func runLiteralRow(tool: FusedFilesTool, context: FileContext, package: ScaffoldedCleanEditPackage) async {
        await runCleanEditRow(
            tool: tool,
            context: context,
            fileURL: package.literal,
            setupContent: "func literalRowValue() -> Int {\n    let literalValue = 1\n    return literalValue\n}\n",
            find: ["let literalValue = 1"],
            replace: ["let literalValue = 2"],
            expectedMatchedBy: IntegrationWire.literalMatch,
            expectedApplied: 1,
            label: "literal",
            expectedContent: "func literalRowValue() -> Int {\n    let literalValue = 2\n    return literalValue\n}\n"
        )
    }

    /// The recovered rung: a drifted (re-indented) multi-line `find` recovers via the ladder.
    private func runRecoveredRow(tool: FusedFilesTool, context: FileContext, package: ScaffoldedCleanEditPackage) async {
        await runCleanEditRow(
            tool: tool,
            context: context,
            fileURL: package.recovered,
            setupContent: "func recoveredRowValue() -> Int {\n    let base = 1\n    return base\n}\n",
            // The interior newline is un-indented, so this is NOT a byte-exact
            // substring; the recovery ladder's normalized rung locates the block.
            find: ["let base = 1\nreturn base"],
            replace: ["    let base = 2\n    return base"],
            expectedMatchedBy: IntegrationWire.recoveredMatch,
            expectedApplied: 1,
            label: "recovered",
            expectedContent: "func recoveredRowValue() -> Int {\n    let base = 2\n    return base\n}\n"
        )
    }

    /// The `replaceAll` rung: every occurrence of the `find` is rewritten.
    private func runReplaceAllRow(tool: FusedFilesTool, context: FileContext, package: ScaffoldedCleanEditPackage) async {
        await runCleanEditRow(
            tool: tool,
            context: context,
            fileURL: package.replaceAll,
            setupContent: "let replaceAllFirst = 7\nlet replaceAllSecond = 7\n",
            find: ["7"],
            replace: ["8"],
            replacesAll: true,
            expectedMatchedBy: IntegrationWire.literalMatch,
            expectedApplied: 1,
            label: "replaceAll",
            expectedContent: "let replaceAllFirst = 8\nlet replaceAllSecond = 8\n"
        )
    }

    /// The `occurrence` rung: one disambiguated occurrence among several is rewritten.
    private func runOccurrenceRow(tool: FusedFilesTool, context: FileContext, package: ScaffoldedCleanEditPackage) async {
        await runCleanEditRow(
            tool: tool,
            context: context,
            fileURL: package.occurrence,
            setupContent: "let occurrenceFirst = 5\nlet occurrenceSecond = 5\nlet occurrenceThird = 5\n",
            find: ["5"],
            replace: ["6"],
            occurrence: 2,
            expectedMatchedBy: IntegrationWire.literalMatch,
            expectedApplied: 1,
            label: "occurrence",
            expectedContent: "let occurrenceFirst = 5\nlet occurrenceSecond = 6\nlet occurrenceThird = 5\n"
        )
    }

    /// The multi-pair rung: parallel `find`/`replace` arrays apply in one batch.
    private func runMultiPairBatchRow(tool: FusedFilesTool, context: FileContext, package: ScaffoldedCleanEditPackage) async {
        await runCleanEditRow(
            tool: tool,
            context: context,
            fileURL: package.batch,
            setupContent: "let batchAlpha = 1\nlet batchBeta = 2\n",
            find: ["batchAlpha = 1", "batchBeta = 2"],
            replace: ["batchAlpha = 10", "batchBeta = 20"],
            expectedMatchedBy: IntegrationWire.literalMatch,
            expectedApplied: 2,
            label: "multi-pair batch",
            expectedContent: "let batchAlpha = 10\nlet batchBeta = 20\n"
        )
    }

    // MARK: - Error-then-fix round trip

    /// Error-then-fix: an edit breaks the build (diagnostics show it), a second
    /// edit repairs it, and the file settles back to `clean`.
    private func runErrorThenFixRow(tool: FusedFilesTool, context: FileContext, package: ScaffoldedCleanEditPackage) async {
        guard (try? await callWrite(tool, path: package.roundTrip.path, content: "func roundTripValue() -> Int {\n    return 1\n}\n")) != nil else {
            Issue.record("error-then-fix: the baseline write failed")
            return
        }
        await expectSettlesClean(context: context, fileURL: package.roundTrip, label: "error-then-fix baseline")

        // Break: return a String from an Int-returning function.
        let breakOutput = try? await DiagnosticsProbe.callTool(
            tool,
            arguments: DiagnosticsProbe.payload([
                ("op", "edit file"),
                ("filePath", package.roundTrip.path),
                ("find", ["return 1"]),
                ("replace", ["return \"broken\""]),
            ])
        )
        expectApplied(breakOutput, matchedBy: IntegrationWire.literalMatch, appliedCount: 1, label: "error-then-fix break")
        let broken = await DiagnosticsProbe.awaitDiagnostics(
            from: context.diagnostics,
            fileAt: package.roundTrip,
            deadline: Self.roundTripDeadline
        ) { diagnostics in
            diagnostics.status == IntegrationWire.errors
                && diagnostics.items.contains { $0.message.localizedCaseInsensitiveContains("convert") }
        }
        guard let broken else {
            Issue.record("error-then-fix: the break never surfaced a real error within deadline")
            return
        }
        #expect(broken.status == IntegrationWire.errors, "error-then-fix: expected errors after the break, got \(broken.status)")
        #expect(broken.errors > 0, "error-then-fix: expected a positive error count after the break")

        // Fix: restore the Int return.
        let fixOutput = try? await DiagnosticsProbe.callTool(
            tool,
            arguments: DiagnosticsProbe.payload([
                ("op", "edit file"),
                ("filePath", package.roundTrip.path),
                ("find", ["return \"broken\""]),
                ("replace", ["return 1"]),
            ])
        )
        expectApplied(fixOutput, matchedBy: IntegrationWire.literalMatch, appliedCount: 1, label: "error-then-fix fix")
        let settled = await DiagnosticsProbe.awaitDiagnostics(
            from: context.diagnostics,
            fileAt: package.roundTrip,
            deadline: Self.roundTripDeadline
        ) { diagnostics in diagnostics.status == IntegrationWire.clean }
        expectClean(settled, label: "error-then-fix fix")
    }

    // MARK: - Non-diagnosable files (CodeContext untouched)

    /// A non-diagnosable file (`README.md`, `.json`) is `skipped` and never opens
    /// a workspace, so the bridge's `CodeContext` manager stays untouched.
    @Test func nonDiagnosableFilesAreSkippedAndLeaveCodeContextUntouched() async throws {
        try await IsolatedWorkspace.withIsolatedWorkspace(named: "EditsOKNonDiagnosable") { root in
            let context = FileContext(root: root)
            do {
                let tool = try FileTool.make(context: context)
                for name in ["README.md", "notes.json"] {
                    let output = try await DiagnosticsProbe.callTool(
                        tool,
                        arguments: DiagnosticsProbe.payload([
                            ("op", "write file"),
                            ("filePath", root.appendingPathComponent(name).path),
                            ("content", "{\n}\n"),
                        ])
                    )
                    let diagnostics = DiagnosticsProbe.diagnostics(fromToolOutput: output)
                    #expect(diagnostics?.status == IntegrationWire.skipped, "\(name): expected skipped, got \(String(describing: diagnostics?.status))")
                    #expect(diagnostics?.note == DiagnosticsBridge.nonDiagnosableNote, "\(name): expected the non-diagnosable note")
                }
                let openRoots = await context.diagnostics.openRootDirectories()
                #expect(openRoots.isEmpty, "a non-diagnosable write must never open a CodeContext workspace")
            } catch {
                await context.stop()
                throw error
            }
            await context.stop()
        }
    }

    // MARK: - Read-only tool never triggers the bridge

    /// The read-only tool rejects a write and an edit with a corrective and never
    /// engages the diagnostics bridge.
    @Test func readOnlyToolNeverTriggersTheBridge() async throws {
        try await IsolatedWorkspace.withIsolatedWorkspace(named: "EditsOKReadOnly") { root in
            let context = FileContext(root: root, readOnly: true)
            do {
                let tool = try FileTool.makeReadOnly(context: context)
                for op in ["write file", "edit file"] {
                    let output = try await DiagnosticsProbe.callTool(
                        tool,
                        arguments: DiagnosticsProbe.payload([
                            ("op", op),
                            ("filePath", root.appendingPathComponent("target.swift").path),
                            ("content", "let readOnlyValue = 0\n"),
                            ("find", ["a"]),
                            ("replace", ["b"]),
                        ])
                    )
                    let corrective = OperationOutput.decode(DecodedCorrective.self, from: output)
                    #expect(corrective?.corrective.isEmpty == false, "\(op): expected a read-only corrective")
                }
                let openRoots = await context.diagnostics.openRootDirectories()
                #expect(openRoots.isEmpty, "the read-only tool must never open a CodeContext workspace")
            } catch {
                await context.stop()
                throw error
            }
            await context.stop()
        }
    }

    // MARK: - Shared row helper

    /// Runs a clean cascade rung: rewrite the file, apply the edit, assert the
    /// batch applied by the expected rung and landed the expected bytes, and the
    /// file settles to `clean`.
    ///
    /// - Parameters:
    ///   - tool: the fused `files` tool.
    ///   - context: the shared warm context.
    ///   - fileURL: the rung's own file.
    ///   - setupContent: the fresh valid Swift the rung writes before editing.
    ///   - find: the `find` values for the edit.
    ///   - replace: the `replace` values for the edit.
    ///   - replacesAll: whether every occurrence is rewritten, or `nil` for the default.
    ///   - occurrence: the 1-based occurrence selector, or `nil` for none.
    ///   - expectedMatchedBy: the `matchedBy` name the first outcome must carry.
    ///   - expectedApplied: the number of pairs the batch must apply.
    ///   - label: the row label for diagnostic messages.
    ///   - expectedContent: the exact on-disk content to assert after the edit, or `nil` to skip that check.
    private func runCleanEditRow(
        tool: FusedFilesTool,
        context: FileContext,
        fileURL: URL,
        setupContent: String,
        find: [String],
        replace: [String],
        replacesAll: Bool? = nil,
        occurrence: Int? = nil,
        expectedMatchedBy: String,
        expectedApplied: Int,
        label: String,
        expectedContent: String? = nil
    ) async {
        guard (try? await callWrite(tool, path: fileURL.path, content: setupContent)) != nil else {
            Issue.record("\(label): the setup write failed")
            return
        }

        var entries: [(String, any ConvertibleToGeneratedContent)] = [
            ("op", "edit file"),
            ("filePath", fileURL.path),
            ("find", find),
            ("replace", replace),
        ]
        if let replacesAll { entries.append(("replacesAll", replacesAll)) }
        if let occurrence { entries.append(("occurrence", occurrence)) }

        let output = try? await DiagnosticsProbe.callTool(tool, arguments: DiagnosticsProbe.payload(entries))
        expectApplied(output, matchedBy: expectedMatchedBy, appliedCount: expectedApplied, label: label)

        if let expectedContent {
            expectOnDisk(fileURL, equals: expectedContent, label: label)
        }
        await expectSettlesClean(context: context, fileURL: fileURL, label: label)
    }

    /// Dispatches a `write file` through the fused tool.
    ///
    /// - Parameters:
    ///   - tool: the fused `files` tool.
    ///   - path: the absolute path to write.
    ///   - content: the content to write.
    /// - Returns: the operation's JSON output.
    /// - Throws: rethrows a fatal dispatch error.
    private func callWrite(_ tool: FusedFilesTool, path: String, content: String) async throws -> String {
        try await DiagnosticsProbe.callTool(
            tool,
            arguments: DiagnosticsProbe.payload([
                ("op", "write file"),
                ("filePath", path),
                ("content", content),
            ])
        )
    }

    // MARK: - Assertions

    /// Asserts a dispatched op produced a decodable result envelope (not a corrective).
    private func expectDispatchedResult(_ output: String?, label: String) {
        guard let output else {
            Issue.record("\(label): the operation dispatch produced no output")
            return
        }
        #expect(
            OperationOutput.decode(DecodedWriteResult.self, from: output) != nil,
            "\(label): the operation output was not a result envelope"
        )
    }

    /// Asserts a dispatched `edit file` applied by the expected rung.
    ///
    /// - Parameters:
    ///   - output: the operation's JSON output.
    ///   - matchedBy: the `matchedBy` name the first outcome must carry.
    ///   - appliedCount: the number of pairs the batch must apply.
    ///   - label: the row label for diagnostic messages.
    private func expectApplied(_ output: String?, matchedBy: String, appliedCount: Int, label: String) {
        guard let output, let result = OperationOutput.decode(DecodedEditResult.self, from: output) else {
            Issue.record("\(label): the edit dispatch produced no decodable result")
            return
        }
        #expect(result.status == IntegrationWire.applied, "\(label): expected an applied edit, got \(result.status)")
        #expect(result.applied == appliedCount, "\(label): expected \(appliedCount) applied pair(s), got \(result.applied)")
        #expect(result.outcomes.first?.matchedBy == matchedBy, "\(label): expected a \(matchedBy) match, got \(String(describing: result.outcomes.first?.matchedBy))")
    }

    /// Asserts a file's exact on-disk UTF-8 content.
    ///
    /// - Parameters:
    ///   - fileURL: the file to read back.
    ///   - content: the exact content the file must hold.
    ///   - label: the row label for diagnostic messages.
    private func expectOnDisk(_ fileURL: URL, equals content: String, label: String) {
        let onDisk = try? String(contentsOf: fileURL, encoding: .utf8)
        #expect(onDisk == content, "\(label): on-disk content did not match the expected bytes")
    }

    /// Polls the warm bridge until the file settles to `clean`, then asserts it.
    ///
    /// - Parameters:
    ///   - context: the shared warm context.
    ///   - fileURL: the mutated file to diagnose.
    ///   - label: the row label for diagnostic messages.
    private func expectSettlesClean(context: FileContext, fileURL: URL, label: String) async {
        let settled = await DiagnosticsProbe.awaitDiagnostics(
            from: context.diagnostics,
            fileAt: fileURL
        ) { diagnostics in diagnostics.status == IntegrationWire.clean }
        expectClean(settled, label: label)
    }

    /// Asserts a settled diagnostics result is `clean` with zero errors and warnings.
    ///
    /// - Parameters:
    ///   - diagnostics: the settled diagnostics, or `nil` when it never settled.
    ///   - label: the row label for diagnostic messages.
    private func expectClean(_ diagnostics: FileDiagnostics?, label: String) {
        guard let diagnostics else {
            Issue.record("\(label): diagnostics never settled to clean within deadline")
            return
        }
        #expect(diagnostics.status == IntegrationWire.clean, "\(label): expected clean, got \(diagnostics.status) (note: \(diagnostics.note ?? "nil"))")
        #expect(diagnostics.errors == 0, "\(label): expected zero errors")
        #expect(diagnostics.warnings == 0, "\(label): expected zero warnings")
    }
}

/// The fused `files` tool type the edits-OK rows dispatch against.
private typealias FusedFilesTool = Operations.OperationTool<FileContext>
