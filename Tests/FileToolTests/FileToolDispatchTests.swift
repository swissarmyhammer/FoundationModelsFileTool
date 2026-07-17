import Foundation
import FoundationModels
import Operations
import Testing

@testable import FileTool

/// Dispatch, inference, alias, read-only, and schema tests for the fused
/// ``FileTool`` `files` tool.
///
/// Every case is exercised through the real fused ``OperationTool`` built by
/// ``FileTool/make(context:)`` or ``FileTool/makeReadOnly(context:)``: dispatch
/// per op through ``AnyOperation`` typed outputs; a verbatim sah-style
/// snake_case edit payload landing as a working edit on disk; the native-Edit
/// dialect (`old_string`/`new_string`) inferring and aliasing to an edit; the
/// full missing-`op` inference matrix (every precedence branch and the
/// undeterminable case); the read-only tool rejecting mutations with the
/// corrective and allowing read/glob/grep; and the rendered schema carrying
/// exactly the six op strings.
@Suite struct FileToolDispatchTests {
    // MARK: Test scaffolding

    /// Build a `GeneratedContent` payload from ordered key/value entries.
    ///
    /// - Parameter entries: the payload's properties, in order; a later
    ///   duplicate key wins.
    /// - Returns: the assembled structure payload.
    private static func payload(_ entries: [(String, any ConvertibleToGeneratedContent)]) -> GeneratedContent {
        GeneratedContent(properties: entries, uniquingKeysWith: { _, new in new })
    }

    /// Create a fresh temporary session directory seeded with one text file.
    ///
    /// - Parameters:
    ///   - name: the file name to create in the session root.
    ///   - contents: the UTF-8 text to seed the file with.
    /// - Returns: the session ``FileContext`` and the seeded file's absolute path.
    private static func makeContext(
        seeding name: String = "sample.txt",
        contents: String = "needle here\nsecond line\n"
    ) throws -> (context: FileContext, path: String) {
        let root = TestSupport.makeTemporaryDirectory(named: "FileToolDispatchTests")
        let fileURL = root.appendingPathComponent(name, isDirectory: false)
        try Data(contents.utf8).write(to: fileURL)
        return (FileContext(root: root), fileURL.path)
    }

    /// Read the current UTF-8 contents of a file.
    ///
    /// - Parameter path: the absolute path to read.
    /// - Returns: the file's decoded text.
    private static func readContents(_ path: String) throws -> String {
        try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
    }

    // MARK: Dispatch per op

    @Test func dispatchesReadFileThroughTypedOutput() async throws {
        let (context, path) = try Self.makeContext()
        let tool = try FileTool.make(context: context)

        let json = try await tool.call(arguments: Self.payload([("op", "read file"), ("path", path)]))

        #expect(json.contains("\"hash\""))
        #expect(json.contains("needle here"))
    }

    @Test func dispatchesWriteFileThroughTypedOutput() async throws {
        let (context, _) = try Self.makeContext()
        let target = URL(fileURLWithPath: context.root.path).appendingPathComponent("written.txt").path
        let tool = try FileTool.make(context: context)

        let json = try await tool.call(
            arguments: Self.payload([("op", "write file"), ("filePath", target), ("content", "brand new\n")])
        )

        #expect(json.contains("\"bytesWritten\""))
        #expect(try Self.readContents(target) == "brand new\n")
    }

    @Test func dispatchesEditFileThroughTypedOutput() async throws {
        let (context, path) = try Self.makeContext()
        let tool = try FileTool.make(context: context)

        let json = try await tool.call(
            arguments: Self.payload([
                ("op", "edit file"), ("filePath", path), ("find", ["needle"]), ("replace", ["thread"]),
            ])
        )

        #expect(json.contains("\"status\":\"applied\""))
        #expect(try Self.readContents(path) == "thread here\nsecond line\n")
    }

    @Test func dispatchesGlobFilesThroughTypedOutput() async throws {
        let (context, _) = try Self.makeContext(seeding: "alpha.swift", contents: "let a = 1\n")
        let tool = try FileTool.make(context: context)

        let json = try await tool.call(arguments: Self.payload([("op", "glob files"), ("pattern", "*.swift")]))

        #expect(json.contains("alpha.swift"))
    }

    @Test func dispatchesGrepFilesThroughTypedOutput() async throws {
        let (context, path) = try Self.makeContext()
        let tool = try FileTool.make(context: context)

        let json = try await tool.call(
            arguments: Self.payload([("op", "grep files"), ("pattern", "needle"), ("path", path)])
        )

        #expect(json.contains("needle here"))
    }

    // MARK: sah-parity snake_case payload

    @Test func snakeCaseParityEditPayloadLandsAsWorkingEdit() async throws {
        let (context, path) = try Self.makeContext()
        let tool = try FileTool.make(context: context)

        let json = try await tool.call(
            arguments: Self.payload([
                ("op", "edit file"),
                ("file_path", path),
                ("old_string", ["needle"]),
                ("new_string", ["thread"]),
            ])
        )

        #expect(json.contains("\"status\":\"applied\""))
        #expect(try Self.readContents(path) == "thread here\nsecond line\n")
    }

    // MARK: native-Edit dialect (inference + aliasing, no explicit op)

    @Test func nativeEditDialectInfersAndAliasesToAWorkingEdit() async throws {
        let (context, path) = try Self.makeContext()
        let tool = try FileTool.make(context: context)

        let json = try await tool.call(
            arguments: Self.payload([
                ("file_path", path),
                ("old_string", ["needle"]),
                ("new_string", ["thread"]),
            ])
        )

        #expect(json.contains("\"status\":\"applied\""))
        #expect(try Self.readContents(path) == "thread here\nsecond line\n")
    }

    // MARK: Inference matrix — every precedence branch

    @Test func infersEditFromEditsKey() {
        #expect(FileTool.inferOperation(from: Self.payload([("edits", ["x"])])) == "edit file")
    }

    @Test func infersEditFromCanonicalFindKey() {
        #expect(FileTool.inferOperation(from: Self.payload([("find", ["x"])])) == "edit file")
    }

    @Test func infersEditFromFindIshAliasKey() {
        #expect(FileTool.inferOperation(from: Self.payload([("old_string", ["x"])])) == "edit file")
    }

    @Test func infersEditFromCanonicalReplaceKey() {
        #expect(FileTool.inferOperation(from: Self.payload([("replace", ["x"])])) == "edit file")
    }

    @Test func infersEditFromReplaceIshAliasKey() {
        #expect(FileTool.inferOperation(from: Self.payload([("new_string", ["x"])])) == "edit file")
    }

    @Test func infersEditFromUppercaseAliasKey() {
        #expect(FileTool.inferOperation(from: Self.payload([("OLD_STRING", ["x"])])) == "edit file")
    }

    @Test func infersWriteFromMixedCaseContentKey() {
        #expect(FileTool.inferOperation(from: Self.payload([("Content", "x")])) == "write file")
    }

    @Test func infersWriteFromContentKey() {
        #expect(FileTool.inferOperation(from: Self.payload([("content", "x")])) == "write file")
    }

    @Test func editTakesPrecedenceOverWriteWhenBothPresent() {
        #expect(FileTool.inferOperation(from: Self.payload([("content", "x"), ("find", ["y"])])) == "edit file")
    }

    @Test func infersGrepFromPatternPlusCaseInsensitiveMarker() {
        #expect(
            FileTool.inferOperation(from: Self.payload([("pattern", "x"), ("caseInsensitive", true)])) == "grep files"
        )
    }

    @Test func infersGrepFromPatternPlusContextLinesMarker() {
        #expect(FileTool.inferOperation(from: Self.payload([("pattern", "x"), ("contextLines", 2)])) == "grep files")
    }

    @Test func infersGrepFromPatternPlusOutputModeMarker() {
        #expect(
            FileTool.inferOperation(from: Self.payload([("pattern", "x"), ("outputMode", "count")])) == "grep files"
        )
    }

    @Test func infersGlobFromPatternAlone() {
        #expect(FileTool.inferOperation(from: Self.payload([("pattern", "x")])) == "glob files")
    }

    @Test func infersReadFromPathAlone() {
        #expect(FileTool.inferOperation(from: Self.payload([("path", "x")])) == "read file")
    }

    @Test func infersReadFromPathAliasAlone() {
        #expect(FileTool.inferOperation(from: Self.payload([("file_path", "x")])) == "read file")
    }

    @Test func inferenceReturnsNilForUndeterminablePayload() {
        #expect(FileTool.inferOperation(from: Self.payload([("mystery", "x")])) == nil)
    }

    @Test func undeterminablePayloadDispatchYieldsCorrectiveNamingAllSixOps() async throws {
        let (context, _) = try Self.makeContext()
        let tool = try FileTool.make(context: context)

        let message = try await tool.call(arguments: Self.payload([("mystery", "x")]))

        for opString in ["read file", "write file", "edit file", "glob files", "grep files", "patch files"] {
            #expect(message.contains(opString))
        }
    }

    // MARK: Read-only variant

    @Test func readOnlyToolRejectsWriteWithCorrectiveAndDoesNotWrite() async throws {
        let (context, _) = try Self.makeContext()
        let target = URL(fileURLWithPath: context.root.path).appendingPathComponent("blocked.txt").path
        let tool = try FileTool.makeReadOnly(context: context)

        let message = try await tool.call(
            arguments: Self.payload([("op", "write file"), ("filePath", target), ("content", "nope\n")])
        )

        #expect(message.contains("not available in read-only mode"))
        #expect(FileManager.default.fileExists(atPath: target) == false)
    }

    @Test func readOnlyToolRejectsEditWithCorrectiveAndLeavesFileUnchanged() async throws {
        let (context, path) = try Self.makeContext()
        let tool = try FileTool.makeReadOnly(context: context)

        let message = try await tool.call(
            arguments: Self.payload([
                ("op", "edit file"), ("filePath", path), ("find", ["needle"]), ("replace", ["thread"]),
            ])
        )

        #expect(message.contains("not available in read-only mode"))
        #expect(try Self.readContents(path) == "needle here\nsecond line\n")
    }

    @Test func readOnlyToolAllowsRead() async throws {
        let (context, path) = try Self.makeContext()
        let tool = try FileTool.makeReadOnly(context: context)

        let json = try await tool.call(arguments: Self.payload([("op", "read file"), ("path", path)]))

        #expect(json.contains("needle here"))
    }

    @Test func readOnlyToolAllowsGlob() async throws {
        let (context, _) = try Self.makeContext(seeding: "alpha.swift", contents: "let a = 1\n")
        let tool = try FileTool.makeReadOnly(context: context)

        let json = try await tool.call(arguments: Self.payload([("op", "glob files"), ("pattern", "*.swift")]))

        #expect(json.contains("alpha.swift"))
    }

    @Test func readOnlyToolAllowsGrep() async throws {
        let (context, path) = try Self.makeContext()
        let tool = try FileTool.makeReadOnly(context: context)

        let json = try await tool.call(
            arguments: Self.payload([("op", "grep files"), ("pattern", "needle"), ("path", path)])
        )

        #expect(json.contains("needle here"))
    }

    // MARK: Rendered schema

    @Test func renderedSchemaContainsExactlyTheSixOpStrings() throws {
        let (context, _) = try Self.makeContext()
        let tool = try FileTool.make(context: context)

        let opEnum = try Self.opEnum(of: tool)

        #expect(Set(opEnum) == Set(["read file", "write file", "edit file", "glob files", "grep files", "patch files"]))
        #expect(opEnum.count == 6)
    }

    @Test func readOnlyRenderedSchemaContainsAllSixOpStrings() throws {
        let (context, _) = try Self.makeContext()
        let tool = try FileTool.makeReadOnly(context: context)

        let opEnum = try Self.opEnum(of: tool)

        #expect(Set(opEnum) == Set(["read file", "write file", "edit file", "glob files", "grep files", "patch files"]))
        #expect(opEnum.count == 6)
    }

    /// The `op` discriminator's enum values, read back from a fused tool's
    /// rendered `GenerationSchema`.
    ///
    /// Encodes the schema to JSON and decodes the discriminator's `enum`, the
    /// same structural round-trip the upstream schema-fusion tests use — never a
    /// byte-level snapshot of Apple's encoding.
    ///
    /// - Parameter tool: the fused tool whose schema to inspect.
    /// - Returns: the `op` enum's declared op strings.
    /// - Throws: a decoding error if the encoded schema does not carry the
    ///   expected `properties.op.enum` shape.
    private static func opEnum(of tool: OperationTool<FileContext>) throws -> [String] {
        let data = try JSONEncoder().encode(tool.parameters)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let properties = try #require(object["properties"] as? [String: Any])
        let opSchema = try #require(properties["op"] as? [String: Any])
        return try #require(opSchema["enum"] as? [String])
    }
}
