import Foundation
import FoundationModels
import Operations
import Testing

@testable import FileTool

/// Behavioral tests for the ``PatchFiles`` operation.
///
/// The `patch files` wire layer is exercised end-to-end: a multi-file
/// add/update/delete/move envelope applied both directly through
/// `execute(in:)` and through the fused ``FileTool`` `files` tool's op
/// dispatch; op-inference from the bare `patch` key; a malformed envelope
/// returning a corrective naming the offending line while leaving the
/// filesystem untouched; an unresolved update pair returning a structured
/// `nearMiss`/`ambiguous` result carrying the failing file's path and the same
/// candidates/near-miss diffs `edit file` produces (all files byte-identical);
/// a read-only tool rejecting the operation before parsing; the encoded result
/// envelope's field names; and the format-teaching description pinning the
/// envelope syntax it must carry.
@Suite struct PatchFilesTests {
    // MARK: Test scaffolding

    /// Build a ``PatchFiles`` operation from a patch-envelope string.
    ///
    /// - Parameter patch: the whole patch envelope.
    /// - Returns: the decoded ``PatchFiles`` operation.
    private static func makeOperation(patch: String) throws -> PatchFiles {
        try PatchFiles(GeneratedContent(properties: [("patch", patch)], uniquingKeysWith: { _, new in new }))
    }

    /// Build a `GeneratedContent` payload from ordered key/value entries.
    ///
    /// - Parameter entries: the payload's properties, in order.
    /// - Returns: the assembled structure payload.
    private static func payload(_ entries: [(String, any ConvertibleToGeneratedContent)]) -> GeneratedContent {
        GeneratedContent(properties: entries, uniquingKeysWith: { _, new in new })
    }

    /// Wrap a section body in the envelope markers.
    ///
    /// - Parameter body: the file-section text between the markers.
    /// - Returns: the complete `*** Begin Patch` … `*** End Patch` envelope.
    private static func envelope(_ body: String) -> String {
        "*** Begin Patch\n\(body)\n*** End Patch\n"
    }

    /// Seed a file with UTF-8 `contents` at `name` inside a fresh temporary directory.
    ///
    /// - Parameters:
    ///   - files: the file names and UTF-8 contents to seed.
    /// - Returns: the session ``FileContext`` and the temporary root URL.
    private static func makeContext(seeding files: [(name: String, contents: String)] = []) -> (
        context: FileContext, root: URL
    ) {
        let root = TestSupport.makeTemporaryDirectory(named: "PatchFilesTests")
        for file in files {
            try? Data(file.contents.utf8).write(to: root.appendingPathComponent(file.name, isDirectory: false))
        }
        return (FileContext(root: root), root)
    }

    /// The absolute path of `name` under `root`.
    private static func path(_ name: String, in root: URL) -> String {
        root.appendingPathComponent(name, isDirectory: false).path
    }

    /// The raw on-disk bytes of a file, or `nil` when it does not exist.
    private static func bytes(_ path: String) -> Data? {
        try? Data(contentsOf: URL(fileURLWithPath: path))
    }

    /// The per-file result whose reported path ends with `suffix`.
    private static func file(
        _ files: [PatchFileResult],
        endingWith suffix: String
    ) -> PatchFileResult? {
        files.first { $0.path.hasSuffix(suffix) }
    }

    // MARK: Multi-file apply (direct execute)

    @Test func multiFilePatchAppliesAndReportsEveryTouchedFile() async throws {
        let (context, root) = Self.makeContext(seeding: [
            ("update.txt", "one\ntwo\nthree\n"),
            ("delete.txt", "obsolete\n"),
            ("source.txt", "keep me\n"),
        ])
        let body = """
            *** Add File: \(Self.path("added.txt", in: root))
            +added
            *** Update File: \(Self.path("update.txt", in: root))
            *** Find:
            two
            *** Replace:
            TWO
            *** Delete File: \(Self.path("delete.txt", in: root))
            *** Update File: \(Self.path("source.txt", in: root))
            *** Move to: \(Self.path("dest.txt", in: root))
            """
        let output = try await Self.makeOperation(patch: Self.envelope(body)).execute(in: context)
        let result = try #require(output.resultValue)

        #expect(result.status == "applied")
        #expect(result.files.count == 4)

        let add = try #require(Self.file(result.files, endingWith: "added.txt"))
        #expect(add.action == "added")
        #expect(add.applied == 0)
        #expect(add.bytesWritten == Data("added\n".utf8).count)
        #expect(add.hash == Hashline.wholeFileHash(bytes: Data("added\n".utf8)))
        #expect(Self.bytes(Self.path("added.txt", in: root)) == Data("added\n".utf8))

        let update = try #require(Self.file(result.files, endingWith: "update.txt"))
        #expect(update.action == "modified")
        #expect(update.applied == 1)
        #expect(Self.bytes(Self.path("update.txt", in: root)) == Data("one\nTWO\nthree\n".utf8))

        let delete = try #require(Self.file(result.files, endingWith: "delete.txt"))
        #expect(delete.action == "deleted")
        #expect(delete.bytesWritten == nil)
        #expect(delete.hash == nil)
        #expect(Self.bytes(Self.path("delete.txt", in: root)) == nil)

        let move = try #require(Self.file(result.files, endingWith: "source.txt"))
        #expect(move.action == "moved")
        #expect(move.movedTo == Self.path("dest.txt", in: root))
        #expect(Self.bytes(Self.path("dest.txt", in: root)) == Data("keep me\n".utf8))
        #expect(Self.bytes(Self.path("source.txt", in: root)) == nil)
    }

    // MARK: Dispatch through the fused tool

    @Test func dispatchesPatchFilesThroughTypedOutput() async throws {
        let (context, root) = Self.makeContext()
        let tool = try FileTool.make(context: context)
        let body = "*** Add File: \(Self.path("new.txt", in: root))\n+hello"

        let json = try await tool.call(arguments: Self.payload([("op", "patch files"), ("patch", Self.envelope(body))]))

        #expect(json.contains("\"status\":\"applied\""))
        #expect(json.contains("\"action\":\"added\""))
        #expect(Self.bytes(Self.path("new.txt", in: root)) == Data("hello\n".utf8))
    }

    // MARK: Op-inference from the bare `patch` key

    @Test func infersPatchFilesFromPatchKey() {
        #expect(FileTool.inferOperation(from: Self.payload([("patch", "*** Begin Patch")])) == "patch files")
    }

    @Test func barePatchPayloadDispatchesAndApplies() async throws {
        let (context, root) = Self.makeContext()
        let tool = try FileTool.make(context: context)
        let body = "*** Add File: \(Self.path("inferred.txt", in: root))\n+inferred"

        let json = try await tool.call(arguments: Self.payload([("patch", Self.envelope(body))]))

        #expect(json.contains("\"status\":\"applied\""))
        #expect(Self.bytes(Self.path("inferred.txt", in: root)) == Data("inferred\n".utf8))
    }

    // MARK: Malformed envelope

    @Test func malformedEnvelopeIsCorrectiveNamingTheLineAndLeavesFilesUntouched() async throws {
        let (context, root) = Self.makeContext(seeding: [("keep.txt", "unchanged\n")])
        // A `*** Begin Patch` with no `*** End Patch`.
        let malformed = "*** Begin Patch\n*** Add File: \(Self.path("nope.txt", in: root))\n+x\n"
        let output = try await Self.makeOperation(patch: malformed).execute(in: context)
        let message = try #require(output.correctiveValue)

        #expect(message.contains("line"))
        #expect(Self.bytes(Self.path("keep.txt", in: root)) == Data("unchanged\n".utf8))
        #expect(Self.bytes(Self.path("nope.txt", in: root)) == nil)
    }

    // MARK: Unresolved update pair (structured, byte-identical)

    @Test func nearMissUpdateReportsPathAndDiffAndCommitsNothing() async throws {
        let original = "the quick brown fox\n"
        let (context, root) = Self.makeContext(seeding: [("prose.txt", original)])
        let target = Self.path("prose.txt", in: root)
        let body = """
            *** Update File: \(target)
            *** Find:
            the quick red fox
            *** Replace:
            X
            """
        let output = try await Self.makeOperation(patch: Self.envelope(body)).execute(in: context)
        let result = try #require(output.resultValue)

        #expect(result.status == "nearMiss")
        // The failing file's path is the guard-resolved absolute path (existing
        // files canonicalize the `/var` → `/private/var` symlink, exactly as
        // `edit file` reports it), so match by suffix rather than the raw seed path.
        #expect(result.path?.hasSuffix("prose.txt") == true)
        #expect(result.files.isEmpty)
        let nearMiss = try #require(result.outcome?.nearMisses?.first)
        #expect(nearMiss.lines.contains { $0.change == "expected" && $0.text == "the quick red fox" })
        #expect(nearMiss.lines.contains { $0.change == "actual" && $0.text == "the quick brown fox" })
        #expect(Self.bytes(target) == Data(original.utf8), "an unresolved patch must leave every file byte-identical")
    }

    @Test func ambiguousUpdateReportsCandidatesAndCommitsNothing() async throws {
        let original = "x\nx\n"
        let (context, root) = Self.makeContext(seeding: [("dup.txt", original)])
        let target = Self.path("dup.txt", in: root)
        let body = """
            *** Update File: \(target)
            *** Find:
            x
            *** Replace:
            y
            """
        let output = try await Self.makeOperation(patch: Self.envelope(body)).execute(in: context)
        let result = try #require(output.resultValue)

        #expect(result.status == "ambiguous")
        #expect(result.outcome?.matchedBy == "ambiguous")
        #expect(result.outcome?.candidates?.count == 2)
        #expect(Self.bytes(target) == Data(original.utf8))
    }

    // MARK: Read-only rejection (before parsing)

    @Test func readOnlyToolRejectsPatchWithCorrectiveAndDoesNotWrite() async throws {
        let (context, root) = Self.makeContext()
        let tool = try FileTool.makeReadOnly(context: context)
        let target = Self.path("blocked.txt", in: root)
        let body = "*** Add File: \(target)\n+nope"

        let message = try await tool.call(arguments: Self.payload([("op", "patch files"), ("patch", Self.envelope(body))]))

        #expect(message.contains("not available in read-only mode"))
        #expect(Self.bytes(target) == nil)
    }

    // MARK: Encoded envelope field names

    @Test func encodedResultCarriesTheExpectedFieldNames() async throws {
        let (context, root) = Self.makeContext(seeding: [("src.txt", "hi\n")])
        let body = """
            *** Add File: \(Self.path("made.txt", in: root))
            +made
            *** Update File: \(Self.path("src.txt", in: root))
            *** Move to: \(Self.path("moved.txt", in: root))
            """
        let output = try await Self.makeOperation(patch: Self.envelope(body)).execute(in: context)
        let result = try #require(output.resultValue)

        let json = String(decoding: try JSONEncoder().encode(output), as: UTF8.self)
        #expect(json.contains("\"status\""))
        #expect(json.contains("\"files\""))
        #expect(json.contains("\"path\""))
        #expect(json.contains("\"action\""))
        #expect(json.contains("\"applied\""))
        #expect(json.contains("\"bytesWritten\""))
        #expect(json.contains("\"hash\""))
        #expect(json.contains("\"movedTo\""))
        #expect(result.status == "applied")
    }

    // MARK: Format-teaching description

    @Test func operationDescriptionTeachesTheEnvelopeSyntax() {
        let description = PatchFiles.operationDescription
        for marker in [
            "*** Begin Patch",
            "*** Add File:",
            "*** Update File:",
            "*** Delete File:",
            "*** Move to:",
            "*** Find:",
            "*** Replace:",
            "*** End Patch",
        ] {
            #expect(description.contains(marker), "the format-teaching description must document `\(marker)`")
        }
    }
}

/// Test-only pattern-matching accessors over ``PatchOutput``.
extension PatchOutput {
    /// The successful ``PatchResult``, or `nil` when the output is corrective.
    var resultValue: PatchResult? {
        if case .content(let result) = self { return result }
        return nil
    }

    /// The corrective message, or `nil` when the output carries a result.
    var correctiveValue: String? {
        if case .corrective(let message) = self { return message }
        return nil
    }
}
