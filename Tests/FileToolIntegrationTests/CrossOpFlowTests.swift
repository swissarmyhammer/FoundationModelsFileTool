import Foundation
import FoundationModels
import Operations
import Testing

@testable import FileTool

// The combined integration-tier wall-clock budget is documented in the header of
// ``EditsOKTests``; this suite is the cross-op half of tier B and shares that
// budget and gating discipline.

/// Real-`sourcekit-lsp` cross-operation flows in isolated directories.
///
/// Where ``EditsOKTests`` drives each mutation path in isolation, this suite
/// chains the operations the way a model does — write → read → edit → diagnose;
/// glob → grep → edit; a `.gitignore` end to end — and pins the concurrency and
/// byte-preservation guarantees the tool makes in a real workspace.
///
/// Robustness follows suite A and ``EditsOKTests``:
///
/// - **The one flow that needs a settled server** (write → read → edit-by-anchor
///   → diagnostics) warms its own context once and tears it down; every other
///   flow runs in a fresh isolated workspace it owns, so the flows never
///   interfere.
/// - **No timing assertions.** The diagnostics flow converges via bounded
///   polling; the concurrency flows assert only the final bytes and the absence
///   of corruption/crash — never an ordering or a duration.
/// - **`.serialized`** so at most one heavy language server is live at a time and
///   the shared temporary-directory machinery is never raced.
@Suite(.serialized, .enabled(if: LSPGate.isSourceKitLSPAvailable, Comment(rawValue: LSPGate.skipMessage)))
struct CrossOpFlowTests {
    // MARK: - Tuning

    /// The generous deadline the diagnostics flow's warm-up polls a known-clean file within.
    private static let warmUpDeadline: Duration = .seconds(180)

    /// The number of concurrent reads launched during the parallel-reads smoke.
    private static let concurrentReadCount = 8

    // MARK: - write → read (anchors) → edit-by-anchor → diagnostics

    /// A full chain: write a Swift file, read its hashline anchors, edit by a
    /// lifted anchor, and confirm the mutation settles to `clean`.
    @Test func writeReadEditByAnchorSettlesClean() async throws {
        let package = try CleanEditPackage.scaffold(named: "CrossOpWarm")
        defer { IsolatedWorkspace.remove(package.root) }

        let context = FileContext(root: package.root, eagerWarmup: true)
        do {
            try await warmUp(context: context, fileURL: package.crossOp)
            let tool = try FileTool.make(context: context)

            _ = try await callWrite(tool, path: package.crossOp.path, content: "func crossOpValue() -> Int {\n    return 1\n}\n")

            let readOutput = try await DiagnosticsProbe.callTool(
                tool,
                arguments: DiagnosticsProbe.payload([
                    ("op", "read file"),
                    ("filePath", package.crossOp.path),
                ])
            )
            let readResult = try #require(OperationOutput.decode(DecodedReadResult.self, from: readOutput))
            try #require(readResult.lines.count >= 2)
            // The second line's hashline anchor ("2:HH|    return 1") drives the edit.
            let anchor = readResult.lines[1]

            let editOutput = try await DiagnosticsProbe.callTool(
                tool,
                arguments: DiagnosticsProbe.payload([
                    ("op", "edit file"),
                    ("filePath", package.crossOp.path),
                    ("find", [anchor]),
                    ("replace", ["    return 2"]),
                ])
            )
            let editResult = try #require(OperationOutput.decode(DecodedEditResult.self, from: editOutput))
            #expect(editResult.status == IntegrationWire.applied, "expected an applied edit, got \(editResult.status)")
            #expect(editResult.outcomes.first?.matchedBy == IntegrationWire.anchorMatch, "expected an anchor-resolved edit")
            #expect(try String(contentsOf: package.crossOp, encoding: .utf8) == "func crossOpValue() -> Int {\n    return 2\n}\n", "the anchor edit must land its exact bytes")

            let settled = await DiagnosticsProbe.awaitDiagnostics(
                from: context.diagnostics,
                fileAt: package.crossOp
            ) { diagnostics in diagnostics.status == IntegrationWire.clean }
            #expect(settled?.status == IntegrationWire.clean, "the anchor edit should settle clean, got \(String(describing: settled?.status))")
        } catch {
            await context.stop()
            throw error
        }
        await context.stop()
    }

    /// Awaits the eager warm-up and polls `fileURL` until the server settles.
    ///
    /// - Parameters:
    ///   - context: the warm context being warmed.
    ///   - fileURL: a known-clean file to poll to a settled result.
    /// - Throws: never; `throws` only so the caller can `try` it in its `do`.
    private func warmUp(context: FileContext, fileURL: URL) async throws {
        await context.diagnostics.warmUpTask?.value
        let settled = await DiagnosticsProbe.awaitDiagnostics(
            from: context.diagnostics,
            fileAt: fileURL,
            deadline: Self.warmUpDeadline
        ) { diagnostics in diagnostics.status != IntegrationWire.pending }
        #expect(settled?.status != IntegrationWire.pending, "warm-up never settled the workspace within budget")
    }

    // MARK: - glob → grep → edit

    /// A glob narrows the files, a grep finds a line within them, and an edit
    /// rewrites the matched line — chained through full dispatch.
    @Test func globThenGrepThenEdit() async throws {
        try await IsolatedWorkspace.withIsolatedWorkspace(named: "CrossOpGlobGrepEdit") { root in
            try IsolatedWorkspace.write("needle here\n", to: root.appendingPathComponent("alpha.txt"))
            try IsolatedWorkspace.write("haystack only\n", to: root.appendingPathComponent("beta.txt"))
            try IsolatedWorkspace.write("needle in markdown\n", to: root.appendingPathComponent("gamma.md"))
            let context = FileContext(root: root)
            do {
                let tool = try FileTool.make(context: context)

                let glob = try #require(try await callGlob(tool, pattern: "*.txt", path: root.path))
                #expect(Set(glob.files) == ["alpha.txt", "beta.txt"], "glob must match the two .txt files and not the .md")

                // Scope the grep to the globbed .txt files, so the .md that also
                // contains "needle" is excluded — the glob → grep narrowing.
                let grep = try #require(try await callGrep(tool, pattern: "needle", path: root.path, glob: "*.txt"))
                let matchedFiles = Set((grep.matches ?? []).filter(\.isMatch).map(\.file))
                #expect(matchedFiles == ["alpha.txt"], "grep must match only the globbed .txt file whose line contains the needle")

                let edit = try #require(try await callEdit(tool, path: root.appendingPathComponent("alpha.txt").path, find: ["needle here"], replace: ["needle edited"]))
                #expect(edit.status == IntegrationWire.applied, "the chained edit should apply")
                let onDisk = try String(contentsOf: root.appendingPathComponent("alpha.txt"), encoding: .utf8)
                #expect(onDisk == "needle edited\n", "the edit must rewrite the grepped line")
            } catch {
                await context.stop()
                throw error
            }
            await context.stop()
        }
    }

    // MARK: - .gitignore end to end

    /// An ignored file is invisible to `glob` and `grep` (the git-aware walk
    /// excludes it) yet remains readable by explicit path.
    @Test func gitignoredFileIsInvisibleToWalkButReadableByPath() async throws {
        try await IsolatedWorkspace.withIsolatedWorkspace(named: "CrossOpGitignore") { root in
            try IsolatedWorkspace.write("ignored.txt\n", to: root.appendingPathComponent(".gitignore"))
            try IsolatedWorkspace.write("visible content\n", to: root.appendingPathComponent("visible.txt"))
            try IsolatedWorkspace.write("secret content\n", to: root.appendingPathComponent("ignored.txt"))
            // `add --all` respects `.gitignore`, so `ignored.txt` stays untracked
            // and `git ls-files --exclude-standard` (the walk's source) omits it.
            try IsolatedWorkspace.initializeGitRepository(at: root)
            let context = FileContext(root: root)
            do {
                let tool = try FileTool.make(context: context)

                let glob = try #require(try await callGlob(tool, pattern: "*.txt", path: root.path))
                #expect(glob.files == ["visible.txt"], "glob must not surface the gitignored file")

                let grep = try #require(try await callGrep(tool, pattern: "content", path: root.path))
                let grepFiles = Set((grep.matches ?? []).map(\.file))
                #expect(grepFiles == ["visible.txt"], "grep must not descend into or scan the gitignored file")

                let readOutput = try await DiagnosticsProbe.callTool(
                    tool,
                    arguments: DiagnosticsProbe.payload([
                        ("op", "read file"),
                        ("filePath", root.appendingPathComponent("ignored.txt").path),
                        ("format", IntegrationWire.plainFormat),
                    ])
                )
                let readResult = try #require(OperationOutput.decode(DecodedReadResult.self, from: readOutput))
                #expect(readResult.lines == ["secret content"], "an explicit-path read must still read the gitignored file")
            } catch {
                await context.stop()
                throw error
            }
            await context.stop()
        }
    }

    // MARK: - Concurrency smoke

    /// Parallel reads overlapping one edit each see a whole (never partial) file,
    /// and the edit's final bytes land — the atomic write is never observed torn.
    @Test func parallelReadsDuringAnEditNeverSeeATornFile() async throws {
        try await IsolatedWorkspace.withIsolatedWorkspace(named: "CrossOpParallelReads") { root in
            let fileURL = root.appendingPathComponent("concurrent.txt")
            try IsolatedWorkspace.write("start\n", to: fileURL)
            let context = FileContext(root: root)
            do {
                let tool = try FileTool.make(context: context)
                let readArguments = DiagnosticsProbe.payload([
                    ("op", "read file"),
                    ("filePath", fileURL.path),
                    ("format", IntegrationWire.plainFormat),
                ])
                let editArguments = DiagnosticsProbe.payload([
                    ("op", "edit file"),
                    ("filePath", fileURL.path),
                    ("find", ["start"]),
                    ("replace", ["finished"]),
                ])

                // The edit runs concurrently with the reads.
                async let editOutput: String = DiagnosticsProbe.callTool(tool, arguments: editArguments)
                var readLines: [[String]] = []
                await withTaskGroup(of: String?.self) { group in
                    for _ in 0 ..< Self.concurrentReadCount {
                        group.addTask { try? await DiagnosticsProbe.callTool(tool, arguments: readArguments) }
                    }
                    for await output in group {
                        if let output, let read = OperationOutput.decode(DecodedReadResult.self, from: output) {
                            readLines.append(read.lines)
                        }
                    }
                }
                _ = try await editOutput

                #expect(readLines.count == Self.concurrentReadCount, "every concurrent read should have produced a result")
                for lines in readLines {
                    #expect(lines == ["start"] || lines == ["finished"], "a concurrent read observed a torn file: \(lines)")
                }
                let finalContent = try String(contentsOf: fileURL, encoding: .utf8)
                #expect(finalContent == "finished\n", "the edit's final bytes must land intact")
            } catch {
                await context.stop()
                throw error
            }
            await context.stop()
        }
    }

    /// Concurrent edits to distinct files each land their own final bytes with no
    /// cross-contamination.
    @Test func concurrentEditsToDistinctFilesEachLandCleanly() async throws {
        try await IsolatedWorkspace.withIsolatedWorkspace(named: "CrossOpConcurrentEdits") { root in
            let fileA = root.appendingPathComponent("a.txt")
            let fileB = root.appendingPathComponent("b.txt")
            try IsolatedWorkspace.write("a-original\n", to: fileA)
            try IsolatedWorkspace.write("b-original\n", to: fileB)
            let context = FileContext(root: root)
            do {
                let tool = try FileTool.make(context: context)
                async let editA: DecodedEditResult? = callEdit(tool, path: fileA.path, find: ["a-original"], replace: ["a-edited"])
                async let editB: DecodedEditResult? = callEdit(tool, path: fileB.path, find: ["b-original"], replace: ["b-edited"])
                let resultA = try await editA
                let resultB = try await editB

                #expect(resultA?.status == IntegrationWire.applied, "edit A should apply")
                #expect(resultB?.status == IntegrationWire.applied, "edit B should apply")
                #expect(try String(contentsOf: fileA, encoding: .utf8) == "a-edited\n", "file A must hold its own edit")
                #expect(try String(contentsOf: fileB, encoding: .utf8) == "b-edited\n", "file B must hold its own edit")
            } catch {
                await context.stop()
                throw error
            }
            await context.stop()
        }
    }

    // MARK: - Byte-level preservation

    /// A CRLF file keeps every carriage-return/line-feed terminator across an edit.
    @Test func carriageReturnLineFeedIsPreservedAcrossAnEdit() async throws {
        try await withByteFixture(named: "CrossOpCRLF") { tool, root in
            let fileURL = root.appendingPathComponent("crlf.txt")
            let original = Data("line one\r\nline two\r\nline three\r\n".utf8)
            try IntegrationFixtures.writeBytes(original, to: fileURL)

            let result = try #require(try await callEdit(tool, path: fileURL.path, find: ["line two"], replace: ["LINE TWO"]))
            #expect(result.lineEndings == IntegrationWire.crlfLineEnding, "the CRLF convention must be detected and preserved")
            #expect(result.encoding == IntegrationWire.utf8Encoding, "a CRLF UTF-8 file must stay utf-8")
            let committed = try IntegrationFixtures.readBytes(fileURL)
            #expect(committed == Data("line one\r\nLINE TWO\r\nline three\r\n".utf8), "every CRLF terminator must survive the edit")
        }
    }

    /// A UTF-8 byte-order-mark file keeps its mark byte-for-byte across an edit.
    @Test func byteOrderMarkIsPreservedAcrossAnEdit() async throws {
        try await withByteFixture(named: "CrossOpBOM") { tool, root in
            let fileURL = root.appendingPathComponent("bom.txt")
            let original = IntegrationFixtures.utf8ByteOrderMark + Data("alpha\nbeta\ngamma\n".utf8)
            try IntegrationFixtures.writeBytes(original, to: fileURL)

            let result = try #require(try await callEdit(tool, path: fileURL.path, find: ["beta"], replace: ["BETA"]))
            #expect(result.encoding == IntegrationWire.utf8BomEncoding, "the byte-order mark must be detected and preserved")
            let committed = try IntegrationFixtures.readBytes(fileURL)
            #expect(committed.prefix(IntegrationFixtures.utf8ByteOrderMark.count) == IntegrationFixtures.utf8ByteOrderMark, "the mark must remain at the head")
            #expect(committed == IntegrationFixtures.utf8ByteOrderMark + Data("alpha\nBETA\ngamma\n".utf8), "only the edited line's text may change")
        }
    }

    /// An executable script keeps its `0o755` permission bits across an edit.
    @Test func executablePermissionIsPreservedAcrossAnEdit() async throws {
        try await withByteFixture(named: "CrossOpExecutable") { tool, root in
            let fileURL = root.appendingPathComponent("script.sh")
            try IntegrationFixtures.writeBytes(Data("#!/bin/sh\necho old\n".utf8), to: fileURL)
            try IntegrationFixtures.makeExecutable(at: fileURL)

            let result = try #require(try await callEdit(tool, path: fileURL.path, find: ["echo old"], replace: ["echo new"]))
            #expect(result.status == IntegrationWire.applied, "the script edit should apply")
            #expect(IntegrationFixtures.permissionBits(of: fileURL) == Int(IntegrationFixtures.executablePermissionBits), "editing a 0755 script must keep it executable")
            let committed = try String(contentsOf: fileURL, encoding: .utf8)
            #expect(committed == "#!/bin/sh\necho new\n", "the edit must rewrite only the script's body")
        }
    }

    // MARK: - Dispatch helpers

    /// Runs `body` against a fused tool over a fresh isolated workspace, tearing
    /// the context down on every exit path.
    ///
    /// - Parameters:
    ///   - name: a human-readable prefix identifying the workspace on disk.
    ///   - body: the work to run against the fused tool and the workspace root.
    /// - Throws: rethrows whatever scaffolding, tool construction, or `body` throws.
    private func withByteFixture(
        named name: String,
        _ body: (FusedFilesTool, URL) async throws -> Void
    ) async throws {
        try await IsolatedWorkspace.withIsolatedWorkspace(named: name) { root in
            let context = FileContext(root: root)
            do {
                let tool = try FileTool.make(context: context)
                try await body(tool, root)
            } catch {
                await context.stop()
                throw error
            }
            await context.stop()
        }
    }

    /// Dispatches a `write file` and returns its JSON output.
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

    /// Dispatches an `edit file` and decodes its result envelope.
    private func callEdit(_ tool: FusedFilesTool, path: String, find: [String], replace: [String]) async throws -> DecodedEditResult? {
        let output = try await DiagnosticsProbe.callTool(
            tool,
            arguments: DiagnosticsProbe.payload([
                ("op", "edit file"),
                ("filePath", path),
                ("find", find),
                ("replace", replace),
            ])
        )
        return OperationOutput.decode(DecodedEditResult.self, from: output)
    }

    /// Dispatches a `glob files` and decodes its result.
    private func callGlob(_ tool: FusedFilesTool, pattern: String, path: String) async throws -> DecodedGlobResult? {
        let output = try await DiagnosticsProbe.callTool(
            tool,
            arguments: DiagnosticsProbe.payload([
                ("op", "glob files"),
                ("pattern", pattern),
                ("path", path),
            ])
        )
        return OperationOutput.decode(DecodedGlobResult.self, from: output)
    }

    /// Dispatches a `grep files` and decodes its result.
    ///
    /// - Parameters:
    ///   - tool: the fused `files` tool.
    ///   - pattern: the regular-expression pattern to search for.
    ///   - path: the directory to search.
    ///   - glob: an optional filename filter narrowing the walk, or `nil` for none.
    /// - Returns: the decoded grep result, or `nil` when the output is a corrective.
    /// - Throws: rethrows a fatal dispatch error.
    private func callGrep(_ tool: FusedFilesTool, pattern: String, path: String, glob: String? = nil) async throws -> DecodedGrepResult? {
        var entries: [(String, any ConvertibleToGeneratedContent)] = [
            ("op", "grep files"),
            ("pattern", pattern),
            ("path", path),
        ]
        if let glob { entries.append(("glob", glob)) }
        let output = try await DiagnosticsProbe.callTool(tool, arguments: DiagnosticsProbe.payload(entries))
        return OperationOutput.decode(DecodedGrepResult.self, from: output)
    }
}

/// The fused `files` tool type the cross-op flows dispatch against.
private typealias FusedFilesTool = Operations.OperationTool<FileContext>
