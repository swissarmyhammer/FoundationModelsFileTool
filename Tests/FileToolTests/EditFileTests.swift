import Foundation
import FoundationModels
import Testing

@testable import FileTool

/// Behavioral tests for the ``EditFile`` operation.
///
/// Every case in the `edit file` plan row is exercised through the real
/// operation against files on disk: single / `replacesAll` / `occurrence` edits;
/// a multi-pair parallel-array batch; CRLF and UTF-8-BOM round-trips asserting
/// the bytes outside the edited range stay identical (BOM intact, CRLF
/// preserved); mixed line endings reported; the executable bit preserved across
/// a commit; a read-only file left byte-identical with a corrective; a
/// commit-failure path that leaves no temporary files and the file
/// byte-identical; the structured retryable outcomes (ambiguous, near-miss,
/// already-applied, consumed-target) that commit nothing; the corrective hard
/// errors (`find == replace` no-op, count mismatch, empty find, blank path,
/// non-existent file, binary file); the applied-result envelope fields; and the
/// write→edit anchor chain where a `write file` envelope anchor resolves in an
/// edit with no intervening read.
@Suite struct EditFileTests {
    // MARK: Test scaffolding

    /// Build an ``EditFile`` operation from its parameter payload.
    ///
    /// - Parameters:
    ///   - filePath: the path of the file to edit.
    ///   - find: the `find` values (a one-element array is a scalar find).
    ///   - replace: the `replace` values.
    ///   - replacesAll: whether every occurrence is rewritten.
    ///   - occurrence: the 1-based occurrence selector.
    /// - Returns: the decoded ``EditFile`` operation.
    private static func makeOperation(
        filePath: String,
        find: [String]? = nil,
        replace: [String]? = nil,
        replacesAll: Bool? = nil,
        occurrence: Int? = nil
    ) throws -> EditFile {
        var properties: [(String, any ConvertibleToGeneratedContent)] = [("filePath", filePath)]
        if let find { properties.append(("find", find)) }
        if let replace { properties.append(("replace", replace)) }
        if let replacesAll { properties.append(("replacesAll", replacesAll)) }
        if let occurrence { properties.append(("occurrence", occurrence)) }
        return try EditFile(GeneratedContent(properties: properties, uniquingKeysWith: { _, new in new }))
    }

    /// Write `data` to a file named `name` inside a fresh temporary directory.
    ///
    /// - Parameters:
    ///   - data: the raw bytes to seed the file with.
    ///   - name: the file name to create within the temporary directory.
    /// - Returns: the session ``FileContext`` rooted at the temporary directory,
    ///   the file's URL, and its absolute path.
    private static func makeContext(
        seeding data: Data,
        named name: String = "sample.txt"
    ) throws -> (context: FileContext, url: URL, path: String) {
        let root = TestSupport.makeTemporaryDirectory(named: "EditFileTests")
        let fileURL = root.appendingPathComponent(name, isDirectory: false)
        try data.write(to: fileURL)
        return (FileContext(root: root), fileURL, fileURL.path)
    }

    /// Read the raw on-disk bytes of a file.
    ///
    /// - Parameter path: the absolute path to read.
    /// - Returns: the file's bytes.
    private static func readBytes(_ path: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: path))
    }

    /// The POSIX permission bits (`mode & 0o777`) of a path.
    ///
    /// - Parameter path: the absolute path to inspect.
    /// - Returns: the permission bits, or `nil` when the attributes are unreadable.
    private static func permissionBits(_ path: String) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int) ?? nil
    }

    /// The names of directory entries whose name marks them as a leftover temporary file.
    ///
    /// - Parameter directory: the directory URL to scan.
    /// - Returns: the names of any temporary-file leftovers.
    private static func temporaryFileLeftovers(in directory: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.contains(".tmp.") }
    }

    /// The UTF-8 byte-order-mark bytes (`EF BB BF`).
    private static let utf8ByteOrderMark = Data([0xEF, 0xBB, 0xBF])

    // MARK: Single / replacesAll / occurrence

    @Test func singleEditReplacesTheMatchedText() async throws {
        let (context, _, path) = try Self.makeContext(seeding: Data("alpha\nbeta\ngamma\n".utf8))
        let output = try await Self.makeOperation(filePath: path, find: ["beta"], replace: ["BETA"]).execute(in: context)
        let result = try #require(output.resultValue)

        #expect(result.status == "applied")
        #expect(result.applied == 1)
        #expect(result.outcomes.first?.matchedBy == "literal")
        #expect(try Self.readBytes(path) == Data("alpha\nBETA\ngamma\n".utf8))
    }

    @Test func replacesAllRewritesEveryOccurrence() async throws {
        let (context, _, path) = try Self.makeContext(seeding: Data("x\nx\nx\n".utf8))
        let output = try await Self.makeOperation(filePath: path, find: ["x"], replace: ["y"], replacesAll: true)
            .execute(in: context)
        let result = try #require(output.resultValue)

        #expect(result.status == "applied")
        #expect(result.applied == 1)
        #expect(try Self.readBytes(path) == Data("y\ny\ny\n".utf8))
    }

    @Test func occurrenceSelectsAmongLiteralMatches() async throws {
        let (context, _, path) = try Self.makeContext(seeding: Data("x\nx\nx\n".utf8))
        let output = try await Self.makeOperation(filePath: path, find: ["x"], replace: ["y"], occurrence: 2)
            .execute(in: context)
        let result = try #require(output.resultValue)

        #expect(result.status == "applied")
        #expect(try Self.readBytes(path) == Data("x\ny\nx\n".utf8))
    }

    // MARK: Multi-pair batch

    @Test func multiPairParallelArraysApplyInOrder() async throws {
        let (context, _, path) = try Self.makeContext(seeding: Data("foo\nbar\n".utf8))
        let output = try await Self.makeOperation(filePath: path, find: ["foo", "bar"], replace: ["FOO", "BAR"])
            .execute(in: context)
        let result = try #require(output.resultValue)

        #expect(result.status == "applied")
        #expect(result.applied == 2)
        #expect(result.outcomes.count == 2)
        #expect(try Self.readBytes(path) == Data("FOO\nBAR\n".utf8))
    }

    // MARK: CRLF round-trip

    @Test func crlfEditPreservesBytesOutsideTheEditedLine() async throws {
        let original = Data("line one\r\nline two\r\nline three\r\n".utf8)
        let (context, _, path) = try Self.makeContext(seeding: original)
        let output = try await Self.makeOperation(filePath: path, find: ["line two"], replace: ["LINE TWO"])
            .execute(in: context)
        let result = try #require(output.resultValue)

        #expect(result.status == "applied")
        #expect(result.lineEndings == "crlf")
        #expect(result.encoding == "utf-8")
        let committed = try Self.readBytes(path)
        #expect(committed == Data("line one\r\nLINE TWO\r\nline three\r\n".utf8))
        // Every terminator survives: the edit rewrites only the line's text.
        #expect(String(decoding: committed, as: UTF8.self).contains("\r\n"))
        #expect(!String(decoding: committed, as: UTF8.self).contains("\n\n"))
    }

    // MARK: UTF-8-BOM round-trip

    @Test func bomEditKeepsTheByteOrderMarkIntact() async throws {
        let original = Self.utf8ByteOrderMark + Data("alpha\nbeta\n".utf8)
        let (context, _, path) = try Self.makeContext(seeding: original)
        let output = try await Self.makeOperation(filePath: path, find: ["beta"], replace: ["BETA"]).execute(in: context)
        let result = try #require(output.resultValue)

        #expect(result.status == "applied")
        #expect(result.encoding == "utf-8 bom")
        let committed = try Self.readBytes(path)
        #expect(committed.prefix(3) == Self.utf8ByteOrderMark)
        #expect(committed == Self.utf8ByteOrderMark + Data("alpha\nBETA\n".utf8))
    }

    // MARK: Mixed line endings

    @Test func mixedLineEndingsAreReported() async throws {
        let (context, _, path) = try Self.makeContext(seeding: Data("a\r\nb\rc\n".utf8))
        let output = try await Self.makeOperation(filePath: path, find: ["b"], replace: ["B"]).execute(in: context)
        let result = try #require(output.resultValue)

        #expect(result.status == "applied")
        #expect(result.lineEndings == "mixed")
    }

    // MARK: Permission preservation

    @Test func executableBitIsPreservedAcrossAnEdit() async throws {
        let (context, url, path) = try Self.makeContext(seeding: Data("#!/bin/sh\necho old\n".utf8), named: "script.sh")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)

        let output = try await Self.makeOperation(filePath: path, find: ["echo old"], replace: ["echo new"])
            .execute(in: context)
        _ = try #require(output.resultValue)

        #expect(Self.permissionBits(path) == 0o755, "editing a 0755 file must keep it 0755")
    }

    // MARK: Read-only file

    @Test func readOnlyFileIsCorrectiveAndLeavesItByteIdentical() async throws {
        let original = Data("original\n".utf8)
        let (context, url, path) = try Self.makeContext(seeding: original, named: "locked.txt")
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }

        let output = try await Self.makeOperation(filePath: path, find: ["original"], replace: ["changed"])
            .execute(in: context)
        let message = try #require(output.correctiveValue)

        #expect(!message.isEmpty)
        #expect(try Self.readBytes(path) == original, "a read-only target must be byte-identical")
    }

    // MARK: Commit-failure cleanup

    @Test func commitFailureLeavesNoTempFilesAndTheFileByteIdentical() async throws {
        let root = TestSupport.makeTemporaryDirectory(named: "EditFileTests")
        let lockedDirectory = root.appendingPathComponent("locked-dir", isDirectory: true)
        try FileManager.default.createDirectory(at: lockedDirectory, withIntermediateDirectories: true)
        let fileURL = lockedDirectory.appendingPathComponent("target.txt", isDirectory: false)
        let original = Data("alpha\nbeta\n".utf8)
        try original.write(to: fileURL)
        // The file itself stays writable (edit permission passes) but its
        // directory is read-only, so the atomic writer's temp-file creation
        // fails at commit time — after the batch has already resolved.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: lockedDirectory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: lockedDirectory.path) }
        let context = FileContext(root: root)

        let output = try await Self.makeOperation(filePath: fileURL.path, find: ["beta"], replace: ["BETA"])
            .execute(in: context)
        let message = try #require(output.correctiveValue)

        #expect(!message.isEmpty)
        #expect(Self.temporaryFileLeftovers(in: lockedDirectory).isEmpty, "a failed commit must remove the temp file")
        #expect(try Self.readBytes(fileURL.path) == original, "a failed commit must leave the file byte-identical")
    }

    // MARK: Structured retryable outcomes

    @Test func ambiguousEditReportsCandidatesAndCommitsNothing() async throws {
        let original = Data("x\nx\n".utf8)
        let (context, _, path) = try Self.makeContext(seeding: original)
        let output = try await Self.makeOperation(filePath: path, find: ["x"], replace: ["y"]).execute(in: context)
        let result = try #require(output.resultValue)

        #expect(result.status == "ambiguous")
        #expect(result.applied == 0)
        #expect(result.bytesWritten == nil)
        #expect(result.hash == nil)
        #expect(result.outcomes.first?.candidates?.count == 2)
        #expect(try Self.readBytes(path) == original, "an ambiguous edit must leave the file byte-identical")
    }

    @Test func nearMissEditReportsALineDiffAndCommitsNothing() async throws {
        let original = Data("the quick brown fox\n".utf8)
        let (context, _, path) = try Self.makeContext(seeding: original)
        let output = try await Self.makeOperation(filePath: path, find: ["the quick red fox"], replace: ["X"])
            .execute(in: context)
        let result = try #require(output.resultValue)

        #expect(result.status == "nearMiss")
        #expect(result.applied == 0)
        let nearMiss = try #require(result.outcomes.first?.nearMisses?.first)
        #expect(nearMiss.startLine == 1)
        #expect(nearMiss.lines.contains { $0.change == "expected" && $0.text == "the quick red fox" })
        #expect(nearMiss.lines.contains { $0.change == "actual" && $0.text == "the quick brown fox" })
        #expect(try Self.readBytes(path) == original, "a near-miss must leave the file byte-identical")
    }

    @Test func nearMissEditSurfacesAConfusablePunctuationNote() async throws {
        let original = Data("don\u{2019}t stop\n".utf8)
        let (context, _, path) = try Self.makeContext(seeding: original)
        let output = try await Self.makeOperation(
            filePath: path,
            find: ["don't stop\nEXTRA_LINE_NOT_PRESENT"],
            replace: ["X"]
        ).execute(in: context)
        let result = try #require(output.resultValue)

        #expect(result.status == "nearMiss")
        let nearMiss = try #require(result.outcomes.first?.nearMisses?.first)
        #expect(
            nearMiss.note
                == "differs only by Unicode punctuation: the file has '\u{2019}' (U+2019) where the find has \"'\" (U+0027)"
        )

        // The note rides through the Encodable wire projection.
        let encoded = try JSONEncoder().encode(nearMiss)
        let json = String(decoding: encoded, as: UTF8.self)
        #expect(json.contains("U+2019"))
        #expect(json.contains("U+0027"))
        #expect(try Self.readBytes(path) == original, "a near-miss must leave the file byte-identical")
    }

    @Test func alreadyAppliedEditIsReportedAndCommitsNothing() async throws {
        let original = Data("world\n".utf8)
        let (context, _, path) = try Self.makeContext(seeding: original)
        let output = try await Self.makeOperation(filePath: path, find: ["hello"], replace: ["world"]).execute(in: context)
        let result = try #require(output.resultValue)

        #expect(result.status == "alreadyApplied")
        #expect(result.applied == 0)
        #expect(result.outcomes.first?.note != nil)
        #expect(try Self.readBytes(path) == original)
    }

    @Test func consumedTargetEditIsReportedAndCommitsNothing() async throws {
        let original = Data("foo\nbar\n".utf8)
        let (context, _, path) = try Self.makeContext(seeding: original)
        let output = try await Self.makeOperation(filePath: path, find: ["foo", "foo"], replace: ["XXX", "YYY"])
            .execute(in: context)
        let result = try #require(output.resultValue)

        #expect(result.status == "consumedTarget")
        #expect(result.applied == 0)
        #expect(try Self.readBytes(path) == original)
    }

    // MARK: Corrective hard errors

    @Test func identicalFindAndReplaceIsCorrective() async throws {
        let (context, _, path) = try Self.makeContext(seeding: Data("same\n".utf8))
        let output = try await Self.makeOperation(filePath: path, find: ["same"], replace: ["same"]).execute(in: context)
        let message = try #require(output.correctiveValue)

        #expect(!message.isEmpty)
    }

    @Test func countMismatchIsCorrective() async throws {
        let (context, _, path) = try Self.makeContext(seeding: Data("a\nb\nc\n".utf8))
        let output = try await Self.makeOperation(filePath: path, find: ["a", "b", "c"], replace: ["X", "Y"])
            .execute(in: context)
        let message = try #require(output.correctiveValue)

        #expect(message.contains("\"c\""))
    }

    @Test func missingFindIsCorrective() async throws {
        let (context, _, path) = try Self.makeContext(seeding: Data("content\n".utf8))
        let output = try await Self.makeOperation(filePath: path, replace: ["X"]).execute(in: context)
        let message = try #require(output.correctiveValue)

        #expect(!message.isEmpty)
    }

    @Test func blankPathIsCorrective() async throws {
        let context = FileContext(root: TestSupport.makeTemporaryDirectory(named: "EditFileTests"))
        let output = try await Self.makeOperation(filePath: "   ", find: ["a"], replace: ["b"]).execute(in: context)
        let message = try #require(output.correctiveValue)

        #expect(!message.isEmpty)
    }

    @Test func nonExistentFileIsCorrective() async throws {
        let root = TestSupport.makeTemporaryDirectory(named: "EditFileTests")
        let missing = root.appendingPathComponent("does-not-exist.txt", isDirectory: false)
        let context = FileContext(root: root)
        let output = try await Self.makeOperation(filePath: missing.path, find: ["a"], replace: ["b"]).execute(in: context)
        let message = try #require(output.correctiveValue)

        #expect(!message.isEmpty)
    }

    @Test func binaryFileIsCorrectiveAndLeftByteIdentical() async throws {
        let original = Data([0xFF, 0xFE, 0x00, 0x01, 0xFF, 0x80])
        let (context, _, path) = try Self.makeContext(seeding: original, named: "blob.bin")
        let output = try await Self.makeOperation(filePath: path, find: ["a"], replace: ["b"]).execute(in: context)
        let message = try #require(output.correctiveValue)

        #expect(message.localizedCaseInsensitiveContains("utf-8") || message.localizedCaseInsensitiveContains("binary"))
        #expect(try Self.readBytes(path) == original, "a binary file must never be decoded or rewritten")
    }

    // MARK: Applied-result envelope fields

    @Test func appliedResultEnvelopeMatchesASubsequentRead() async throws {
        let (context, url, path) = try Self.makeContext(seeding: Data("alpha\nbeta\ngamma\n".utf8))
        let output = try await Self.makeOperation(filePath: path, find: ["beta"], replace: ["BETA"]).execute(in: context)
        let result = try #require(output.resultValue)

        let committed = try Self.readBytes(path)
        #expect(result.bytesWritten == committed.count)
        #expect(result.encoding == "utf-8")
        #expect(result.hash == Hashline.wholeFileHash(bytes: committed))

        let readOutput = try await ReadFile(
            GeneratedContent(properties: [("path", url.path)], uniquingKeysWith: { _, new in new })
        ).execute(in: context)
        let readResult = try #require(readOutput.resultValue)
        #expect(result.hash == readResult.hash)
        #expect(result.taggedContent == readResult.lines)
    }

    // MARK: Write → edit anchor chain (no intervening read)

    @Test func writeEnvelopeAnchorResolvesInAnEditWithNoInterveningRead() async throws {
        let root = TestSupport.makeTemporaryDirectory(named: "EditFileTests")
        let url = root.appendingPathComponent("chained.txt", isDirectory: false)
        let context = FileContext(root: root)

        // 1. write file — capture the write envelope's hashline-tagged content.
        let writeOutput = try await WriteFile(
            GeneratedContent(
                properties: [("filePath", url.path), ("content", "alpha\nbeta\ngamma\n")],
                uniquingKeysWith: { _, new in new }
            )
        ).execute(in: context)
        let writeResult = try #require(writeOutput.resultValue)
        // The second tagged line ("2:HH|beta") is the anchor a chained edit lifts.
        let anchor = writeResult.taggedContent[1]

        // 2. edit file using that anchor directly — no read in between.
        let editOutput = try await Self.makeOperation(filePath: url.path, find: [anchor], replace: ["BETA"])
            .execute(in: context)
        let editResult = try #require(editOutput.resultValue)

        #expect(editResult.status == "applied")
        #expect(editResult.outcomes.first?.matchedBy == "anchor")
        #expect(editResult.outcomes.first?.line == 2)
        #expect(try Self.readBytes(url.path) == Data("alpha\nBETA\ngamma\n".utf8))
    }
}

/// Test-only pattern-matching accessors over ``EditOutput``.
extension EditOutput {
    /// The successful ``EditResult``, or `nil` when the output is corrective.
    var resultValue: EditResult? {
        if case .content(let result) = self { return result }
        return nil
    }

    /// The corrective message, or `nil` when the output carries a result.
    var correctiveValue: String? {
        if case .corrective(let message) = self { return message }
        return nil
    }
}
