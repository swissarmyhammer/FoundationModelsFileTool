import Foundation
import FoundationModels
import Operations
import Testing

@testable import FileTool

/// CLI-driver tests for the `file-demo` wiring over the fused ``FileTool`` tool.
///
/// Every case drives the real upstream `OperationCLIDriver` through
/// ``FileToolCLI`` — the importable wiring both `main.swift` and these tests
/// share — against a real temporary directory:
///
/// - **Convergence contract** — for every op, the `argv` path dispatches to an
///   output identical to the one the equivalent model-path payload produces
///   (``FileTool/make(context:)`` + `OperationTool.call`). This is the
///   behavioral proxy for `argv → payload` equalling the model-path payload:
///   every case exercises each output-affecting parameter (offset, content,
///   find/replace, pattern, path), so a dropped or mis-wired field would change
///   the output. Compared as canonicalized JSON so only wall-clock-volatile
///   fields (grep's `elapsedMs`) are ignored.
/// - **Help snapshot** — the root `--help` lists both nouns and the executable
///   name.
/// - **Unknown noun/verb** — a misspelled noun or verb is a non-zero-exit error.
/// - **Corrective exit code** — an operation-level corrective (e.g. an
///   unreadable path) maps to a non-zero exit carrying the corrective message.
/// - **Outcome resolution** — the pure ``FileToolCLI/resolveOutcome(output:exitCode:)``
///   mapping from a driver result to a printable outcome.
@Suite struct CLIDriverTests {
    // MARK: Test scaffolding

    /// The seed text used for the read/edit/grep fixtures.
    private static let seedContents = "needle here\nsecond line\n"

    /// JSON object keys whose values are wall-clock-volatile and must be
    /// stripped before a byte-level convergence comparison.
    ///
    /// `grep files` reports an `elapsedMs` timing that necessarily differs
    /// between two runs of the same search; every other field of every op's
    /// output is determined solely by the payload, so stripping this one key
    /// makes the CLI-path and model-path outputs directly comparable.
    private static let volatileConvergenceKeys: Set<String> = ["elapsedMs"]

    /// Build a `GeneratedContent` payload from ordered key/value entries.
    ///
    /// - Parameter entries: the payload's properties, in order; a later
    ///   duplicate key wins.
    /// - Returns: the assembled structure payload.
    private static func payload(_ entries: [(String, any ConvertibleToGeneratedContent)]) -> GeneratedContent {
        GeneratedContent(properties: entries, uniquingKeysWith: { _, new in new })
    }

    /// Canonicalize a JSON string for convergence comparison: parse it, strip
    /// every ``volatileConvergenceKeys`` entry recursively, and re-serialize
    /// with sorted keys.
    ///
    /// - Parameter json: the JSON text to canonicalize.
    /// - Returns: the canonicalized JSON text.
    /// - Throws: an error if `json` is not valid JSON or cannot be re-serialized.
    private static func canonicalized(_ json: String) throws -> String {
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed])
        let stripped = strippingVolatileKeys(object)
        let data = try JSONSerialization.data(withJSONObject: stripped, options: [.sortedKeys, .fragmentsAllowed])
        return String(decoding: data, as: UTF8.self)
    }

    /// Recursively remove every ``volatileConvergenceKeys`` entry from a parsed
    /// JSON value.
    ///
    /// - Parameter object: the parsed JSON value (dictionary, array, or scalar).
    /// - Returns: the value with volatile keys removed at every depth.
    private static func strippingVolatileKeys(_ object: Any) -> Any {
        if let dictionary = object as? [String: Any] {
            var result: [String: Any] = [:]
            for (key, value) in dictionary where !volatileConvergenceKeys.contains(key) {
                result[key] = strippingVolatileKeys(value)
            }
            return result
        }
        if let array = object as? [Any] {
            return array.map(strippingVolatileKeys)
        }
        return object
    }

    /// Write `contents` to a file named `name` under `root`, returning its path.
    ///
    /// - Parameters:
    ///   - name: the file name to create under `root`.
    ///   - contents: the UTF-8 text to write.
    ///   - root: the directory to create the file in.
    /// - Returns: the created file's absolute path.
    /// - Throws: an error if the file cannot be written.
    @discardableResult
    private static func seed(_ name: String, contents: String, in root: URL) throws -> String {
        let fileURL = root.appendingPathComponent(name, isDirectory: false)
        try Data(contents.utf8).write(to: fileURL)
        return fileURL.path
    }

    // MARK: Convergence contract — argv -> payload equals the model-path payload

    /// One op's convergence fixture: how to seed the directory, the `argv` the
    /// CLI parses, and the equivalent model-path payload.
    private struct ConvergenceCase {
        /// The op's name, for failure messages.
        let name: String

        /// Seeds the directory to the state both runs execute against.
        let prepare: (URL) throws -> Void

        /// The `argv` (excluding the executable name) the CLI parses.
        let arguments: (URL) -> [String]

        /// The model-path payload equivalent to `arguments`.
        let modelPayload: (URL) -> GeneratedContent
    }

    /// The convergence fixtures, one per fused op.
    ///
    /// - Parameter root: the directory paths are derived from.
    /// - Returns: the five ops' convergence fixtures.
    private static func convergenceCases() -> [ConvergenceCase] {
        [
            ConvergenceCase(
                name: "read file",
                prepare: { try seed("sample.txt", contents: seedContents, in: $0) },
                arguments: { ["file", "read", "--path", $0.appendingPathComponent("sample.txt").path, "--offset", "2"] },
                modelPayload: {
                    payload([("op", "read file"), ("path", $0.appendingPathComponent("sample.txt").path), ("offset", 2)])
                }
            ),
            ConvergenceCase(
                name: "write file",
                // Remove the target so both runs are clean creates: the path a
                // write returns is symlink-resolved only once the file exists,
                // so a create (`/var/…`) and an overwrite (`/private/var/…`)
                // would otherwise report different paths for the same payload.
                prepare: { try? FileManager.default.removeItem(at: $0.appendingPathComponent("new.txt")) },
                arguments: { ["file", "write", "--file-path", $0.appendingPathComponent("new.txt").path, "--content", "brand new\n"] },
                modelPayload: {
                    payload([
                        ("op", "write file"),
                        ("filePath", $0.appendingPathComponent("new.txt").path),
                        ("content", "brand new\n"),
                    ])
                }
            ),
            ConvergenceCase(
                name: "edit file",
                prepare: { try seed("edit.txt", contents: seedContents, in: $0) },
                arguments: {
                    ["file", "edit", "--file-path", $0.appendingPathComponent("edit.txt").path, "--find", "needle", "--replace", "thread"]
                },
                modelPayload: {
                    payload([
                        ("op", "edit file"),
                        ("filePath", $0.appendingPathComponent("edit.txt").path),
                        ("find", ["needle"]),
                        ("replace", ["thread"]),
                    ])
                }
            ),
            ConvergenceCase(
                name: "glob files",
                prepare: { try seed("alpha.swift", contents: "let a = 1\n", in: $0) },
                arguments: { _ in ["files", "glob", "--pattern", "*.swift"] },
                modelPayload: { _ in payload([("op", "glob files"), ("pattern", "*.swift")]) }
            ),
            ConvergenceCase(
                name: "grep files",
                prepare: { try seed("grep.txt", contents: seedContents, in: $0) },
                arguments: { ["files", "grep", "--pattern", "needle", "--path", $0.appendingPathComponent("grep.txt").path] },
                modelPayload: {
                    payload([("op", "grep files"), ("pattern", "needle"), ("path", $0.appendingPathComponent("grep.txt").path)])
                }
            ),
        ]
    }

    @Test func argvConvergesToTheModelPathPayloadForEveryOp() async throws {
        for testCase in Self.convergenceCases() {
            let root = TestSupport.makeTemporaryDirectory(named: "CLIDriverTests-\(testCase.name)")

            try testCase.prepare(root)
            let modelTool = try FileTool.make(context: FileContext(root: root))
            let modelJSON = try await modelTool.call(arguments: testCase.modelPayload(root))

            try testCase.prepare(root)
            let cliResult = try await FileToolCLI.run(arguments: testCase.arguments(root), context: FileContext(root: root))

            #expect(cliResult.isError == false, "op \(testCase.name) should not be an error")
            #expect(cliResult.exitCode == 0, "op \(testCase.name) should exit 0")
            #expect(
                try Self.canonicalized(cliResult.output) == Self.canonicalized(modelJSON),
                "op \(testCase.name): argv output must converge with the model-path output"
            )
        }
    }

    // MARK: Help snapshot

    @Test func rootHelpListsBothNounsAndTheExecutableName() async throws {
        let root = TestSupport.makeTemporaryDirectory(named: "CLIDriverTests-help")

        let result = try await FileToolCLI.run(arguments: ["--help"], context: FileContext(root: root))

        #expect(result.isError == false)
        #expect(result.exitCode == 0)
        #expect(result.output.contains(FileToolCLI.executableName))
        // Assert on each noun's own subcommand abstract so the `file` noun is
        // proven present distinctly from `files` (a bare "file" substring is
        // also satisfied by "files" and by "file-demo").
        #expect(result.output.contains("Operations on file."))
        #expect(result.output.contains("Operations on files."))
        #expect(result.output.contains("File operations for reading"))
    }

    // MARK: Unknown noun / verb

    @Test func unknownNounIsANonZeroExitError() async throws {
        let root = TestSupport.makeTemporaryDirectory(named: "CLIDriverTests-unknown-noun")

        let result = try await FileToolCLI.run(arguments: ["fil", "read"], context: FileContext(root: root))

        #expect(result.isError == true)
        #expect(result.exitCode != 0)
        #expect(!result.output.isEmpty)
        // The driver surfaces the executable's usage/help guidance so the user
        // can recover the valid nouns.
        #expect(result.output.contains(FileToolCLI.executableName))
    }

    @Test func unknownVerbIsANonZeroExitError() async throws {
        let root = TestSupport.makeTemporaryDirectory(named: "CLIDriverTests-unknown-verb")

        let result = try await FileToolCLI.run(arguments: ["file", "reed"], context: FileContext(root: root))

        #expect(result.isError == true)
        #expect(result.exitCode != 0)
        #expect(!result.output.isEmpty)
        // The driver surfaces the executable's usage/help guidance so the user
        // can recover the valid verbs.
        #expect(result.output.contains(FileToolCLI.executableName))
    }

    // MARK: Corrective exit code

    @Test func operationCorrectiveMapsToANonZeroExitCarryingTheMessage() async throws {
        let root = TestSupport.makeTemporaryDirectory(named: "CLIDriverTests-corrective")
        let missing = root.appendingPathComponent("does-not-exist.txt").path

        let result = try await FileToolCLI.run(arguments: ["file", "read", "--path", missing], context: FileContext(root: root))

        #expect(result.isError == true)
        #expect(result.exitCode != 0)
        #expect(result.output.contains("does-not-exist.txt"))
        #expect(result.output.contains("\"corrective\"") == false)
    }

    // MARK: Outcome resolution (pure mapping)

    @Test func resolveOutcomeMapsACorrectiveJSONToANonZeroExitWithTheMessage() {
        let result = FileToolCLI.resolveOutcome(output: "{\"corrective\":\"boom\"}", exitCode: 0)

        #expect(result.isError == true)
        #expect(result.exitCode != 0)
        #expect(result.output == "boom")
    }

    @Test func resolveOutcomePassesASuccessfulJSONOutputThrough() {
        let result = FileToolCLI.resolveOutcome(output: "{\"hash\":\"abc\"}", exitCode: 0)

        #expect(result.isError == false)
        #expect(result.exitCode == 0)
        #expect(result.output == "{\"hash\":\"abc\"}")
    }

    @Test func resolveOutcomePassesNonJSONHelpTextThroughAsSuccess() {
        let helpText = "USAGE: file-demo <subcommand>"

        let result = FileToolCLI.resolveOutcome(output: helpText, exitCode: 0)

        #expect(result.isError == false)
        #expect(result.exitCode == 0)
        #expect(result.output == helpText)
    }

    @Test func resolveOutcomePassesAParseErrorThroughAsAnError() {
        let result = FileToolCLI.resolveOutcome(output: "Error: unknown argument", exitCode: 64)

        #expect(result.isError == true)
        #expect(result.exitCode == 64)
        #expect(result.output == "Error: unknown argument")
    }
}
