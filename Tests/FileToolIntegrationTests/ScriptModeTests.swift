import Foundation
import Testing

@testable import FileTool

/// The `file-demo --script` mode: reads JSON operation payloads and executes them
/// sequentially in one process against a shared ``FileContext``.
///
/// Two tiers, both in an isolated temporary directory:
///
/// - **In process** — drives the importable ``FileToolScript/run(lines:context:emit:)``
///   loop directly, proving the parse → dispatch → emit logic (and its
///   malformed-line rejection) without a built binary.
/// - **Spawned** — the acceptance criterion: launches the actual built
///   `file-demo --script` executable with a piped `read → edit → read` sequence,
///   asserting the JSON emitted per operation *and* the resulting file bytes on
///   disk, so the whole executable path (argv dispatch, stdin reading, printing)
///   is exercised end to end.
///
/// Script mode edits a plain-text file, whose extension is non-diagnosable, so no
/// `sourcekit-lsp` is ever spawned and the suite needs no LSP gate.
@Suite struct ScriptModeTests {
    // MARK: - Fixture

    /// The seed file's contents every flow reads, edits, and re-reads.
    private static let seedContents = "alpha\nbeta\ngamma\n"

    /// The seed file's contents after the `beta → BETA` edit.
    private static let editedContents = "alpha\nBETA\ngamma\n"

    /// The seed file's lines before the edit, as a `plain`-format read returns them.
    private static let seedLines = ["alpha", "beta", "gamma"]

    /// The seed file's lines after the edit, as a `plain`-format read returns them.
    private static let editedLines = ["alpha", "BETA", "gamma"]

    /// Builds the read → edit → read op-payload lines for a file at `path`.
    ///
    /// - Parameter path: the absolute path of the file the ops act on.
    /// - Returns: three JSON lines: a plain read, a `beta → BETA` edit, a plain read.
    /// - Throws: rethrows a `JSONSerialization` encoding failure.
    private func readEditReadLines(forFileAt path: String) throws -> [String] {
        [
            try Self.jsonLine(["op": "read file", "filePath": path, "format": "plain"]),
            try Self.jsonLine(["op": "edit file", "filePath": path, "find": ["beta"], "replace": ["BETA"]]),
            try Self.jsonLine(["op": "read file", "filePath": path, "format": "plain"]),
        ]
    }

    /// Serializes a JSON object into one compact line.
    ///
    /// - Parameter object: the operation payload's key/value pairs.
    /// - Returns: the single-line JSON encoding.
    /// - Throws: rethrows a `JSONSerialization` encoding failure.
    private static func jsonLine(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - In-process loop

    /// Driving the loop directly runs the read → edit → read sequence against the
    /// context: each op's typed JSON output comes back in order and the edit lands.
    @Test func inProcessRunExecutesReadEditReadSequence() async throws {
        try await IsolatedWorkspace.withIsolatedWorkspace(named: "ScriptModeInProcess") { root in
            let fileURL = root.appendingPathComponent("greeting.txt")
            try IsolatedWorkspace.write(Self.seedContents, to: fileURL)
            let context = FileContext(root: root)

            var outputs: [String] = []
            do {
                try await FileToolScript.run(lines: try readEditReadLines(forFileAt: fileURL.path), context: context) { outputs.append($0) }
            } catch {
                await context.stop()
                throw error
            }
            await context.stop()

            #expect(outputs.count == 3)
            let firstRead = try #require(OperationOutput.decode(DecodedReadResult.self, from: outputs[0]))
            #expect(firstRead.lines == Self.seedLines)
            let edit = try #require(OperationOutput.decode(DecodedEditResult.self, from: outputs[1]))
            #expect(edit.status == IntegrationWire.applied)
            let secondRead = try #require(OperationOutput.decode(DecodedReadResult.self, from: outputs[2]))
            #expect(secondRead.lines == Self.editedLines)
            #expect(try String(contentsOf: fileURL, encoding: .utf8) == Self.editedContents)
        }
    }

    /// Blank and whitespace-only lines produce no output, so a piped heredoc's
    /// trailing newline never yields a spurious result.
    @Test func inProcessRunSkipsBlankLines() async throws {
        try await IsolatedWorkspace.withIsolatedWorkspace(named: "ScriptModeBlankLines") { root in
            let fileURL = root.appendingPathComponent("greeting.txt")
            try IsolatedWorkspace.write(Self.seedContents, to: fileURL)
            let context = FileContext(root: root)

            let lines = ["", try Self.jsonLine(["op": "read file", "filePath": fileURL.path, "format": "plain"]), "   ", ""]
            var outputs: [String] = []
            do {
                try await FileToolScript.run(lines: lines, context: context) { outputs.append($0) }
            } catch {
                await context.stop()
                throw error
            }
            await context.stop()

            #expect(outputs.count == 1)
            let read = try #require(OperationOutput.decode(DecodedReadResult.self, from: outputs[0]))
            #expect(read.lines == Self.seedLines)
        }
    }

    /// A line that is not valid JSON is rejected with a ``ScriptModeError`` rather
    /// than crashing the run or being silently dropped.
    @Test func inProcessRunRejectsAMalformedPayloadLine() async throws {
        try await IsolatedWorkspace.withIsolatedWorkspace(named: "ScriptModeMalformed") { root in
            let context = FileContext(root: root)
            await #expect(throws: ScriptModeError.self) {
                try await FileToolScript.run(lines: ["this is not json"], context: context) { _ in }
            }
            await context.stop()
        }
    }

    // MARK: - Spawned executable (acceptance)

    /// Spawning the built `file-demo --script` with a piped read → edit → read
    /// sequence emits valid JSON per op and lands the edit on disk.
    @Test func spawnedExecutableRunsPipedReadEditReadSequence() async throws {
        try await IsolatedWorkspace.withIsolatedWorkspace(named: "ScriptModeSpawn") { root in
            let fileURL = root.appendingPathComponent("greeting.txt")
            try IsolatedWorkspace.write(Self.seedContents, to: fileURL)

            let standardInput = try readEditReadLines(forFileAt: fileURL.path).joined(separator: "\n") + "\n"
            let result = try ScriptModeProcess.run(
                arguments: [FileToolCLI.scriptModeFlag],
                workingDirectory: root,
                standardInput: standardInput
            )

            #expect(result.exitCode == 0, "expected a clean exit, got \(result.exitCode); stderr: \(result.standardError)")
            let outputLines = result.standardOutput
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map(String.init)
            #expect(outputLines.count == 3, "expected one JSON line per op, got: \(result.standardOutput)")

            let firstRead = try #require(OperationOutput.decode(DecodedReadResult.self, from: outputLines[0]))
            #expect(firstRead.lines == Self.seedLines)
            let edit = try #require(OperationOutput.decode(DecodedEditResult.self, from: outputLines[1]))
            #expect(edit.status == IntegrationWire.applied)
            let secondRead = try #require(OperationOutput.decode(DecodedReadResult.self, from: outputLines[2]))
            #expect(secondRead.lines == Self.editedLines)

            #expect(try String(contentsOf: fileURL, encoding: .utf8) == Self.editedContents)
        }
    }
}

// MARK: - Spawn helper

/// Spawns the built `file-demo` executable with piped standard input and captures
/// its output, so the acceptance test drives the real process rather than the
/// importable loop.
private enum ScriptModeProcess {
    /// The captured outcome of one spawned `file-demo` run.
    struct Result {
        /// The text the process wrote to standard output.
        let standardOutput: String

        /// The text the process wrote to standard error.
        let standardError: String

        /// The process's exit code.
        let exitCode: Int32
    }

    /// Runs `file-demo` with `arguments`, feeding `standardInput` and capturing output.
    ///
    /// - Parameters:
    ///   - arguments: the command-line arguments passed to `file-demo`.
    ///   - workingDirectory: the working directory the process runs in (the demo
    ///     roots its ``FileContext`` here).
    ///   - standardInput: the text piped to the process's standard input.
    /// - Returns: the captured standard output, standard error, and exit code.
    /// - Throws: rethrows a process-launch error.
    static func run(arguments: [String], workingDirectory: URL, standardInput: String) throws -> Result {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory

        let standardInputPipe = Pipe()
        let standardOutputPipe = Pipe()
        let standardErrorPipe = Pipe()
        process.standardInput = standardInputPipe
        process.standardOutput = standardOutputPipe
        process.standardError = standardErrorPipe

        try process.run()
        standardInputPipe.fileHandleForWriting.write(Data(standardInput.utf8))
        try standardInputPipe.fileHandleForWriting.close()

        let standardOutputData = standardOutputPipe.fileHandleForReading.readDataToEndOfFile()
        let standardErrorData = standardErrorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return Result(
            standardOutput: String(decoding: standardOutputData, as: UTF8.self),
            standardError: String(decoding: standardErrorData, as: UTF8.self),
            exitCode: process.terminationStatus
        )
    }

    /// The URL of the built `file-demo` executable in the test bundle's products directory.
    ///
    /// Resolves the products directory from the test bundle itself — the bundle
    /// containing ``BundleToken`` is this target's `.xctest` bundle, and SwiftPM
    /// builds the sibling `file-demo` executable into the same directory — so the
    /// acceptance test spawns the just-built binary rather than one on the search
    /// path. (`Bundle.allBundles` does not surface the test bundle under Swift
    /// Testing, so a token class is the reliable anchor.)
    static var executableURL: URL {
        let productsDirectory = Bundle(for: BundleToken.self).bundleURL.deletingLastPathComponent()
        return productsDirectory.appendingPathComponent("file-demo")
    }
}

/// An empty class whose defining bundle is this test target's `.xctest` bundle,
/// used by ``ScriptModeProcess/executableURL`` to locate the products directory.
private final class BundleToken {}
