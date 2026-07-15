import Foundation
import FoundationModels
import Testing

@testable import FileTool

/// Behavioral tests for the ``WriteFile`` operation.
///
/// Every case in the `write file` plan row is exercised: writing a new file and
/// overwriting an existing one; the blank-path corrective; the content-size cap
/// (rejected one byte over, accepted exactly at the cap); the read-only-target
/// corrective; temp-file cleanup on both a write failure and a rename failure,
/// with a directory scan proving no `.tmp.*` files remain; unicode and empty
/// content; permission preservation on overwrite; and the envelope fields —
/// `bytesWritten`, the freshness `hash` matching a subsequent `read file`, and
/// `taggedContent` matching that read's hashline tagging.
@Suite struct WriteFileTests {
    // MARK: Test scaffolding

    /// The content-size cap in bytes, matching ``WriteFile``'s cap (10 MiB).
    private static let contentByteCap = 10 * 1024 * 1024

    /// Build a ``WriteFile`` operation from its parameter payload.
    ///
    /// - Parameters:
    ///   - filePath: the path of the file to write.
    ///   - content: the content to write.
    /// - Returns: the decoded ``WriteFile`` operation.
    private static func makeOperation(filePath: String, content: String) throws -> WriteFile {
        let properties: [(String, any ConvertibleToGeneratedContent)] = [
            ("filePath", filePath),
            ("content", content),
        ]
        return try WriteFile(GeneratedContent(properties: properties, uniquingKeysWith: { _, new in new }))
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
    /// Scans `directory` for entries whose name contains the `.tmp.` infix
    /// ``AtomicWriter`` uses, so a test can assert the atomic write left nothing
    /// behind on a failure.
    ///
    /// - Parameter directory: the directory URL to scan.
    /// - Returns: the names of any temporary-file leftovers.
    private static func temporaryFileLeftovers(in directory: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.contains(".tmp.") }
    }

    // MARK: New and overwrite

    @Test func writesANewFile() async throws {
        let root = TestSupport.makeTemporaryDirectory(named: "WriteFileTests")
        let path = root.appendingPathComponent("new.txt", isDirectory: false).path
        let context = FileContext(root: root)

        let output = try await Self.makeOperation(filePath: path, content: "hello\nworld\n").execute(in: context)
        let result = try #require(output.resultValue)

        #expect(try Self.readBytes(path) == Data("hello\nworld\n".utf8))
        #expect(result.bytesWritten == Data("hello\nworld\n".utf8).count)
    }

    @Test func overwritesAnExistingFile() async throws {
        let root = TestSupport.makeTemporaryDirectory(named: "WriteFileTests")
        let url = root.appendingPathComponent("existing.txt", isDirectory: false)
        try Data("stale contents that are longer\n".utf8).write(to: url)
        let context = FileContext(root: root)

        let output = try await Self.makeOperation(filePath: url.path, content: "fresh\n").execute(in: context)
        let result = try #require(output.resultValue)

        #expect(try Self.readBytes(url.path) == Data("fresh\n".utf8))
        #expect(result.bytesWritten == Data("fresh\n".utf8).count)
    }

    // MARK: Blank path

    @Test func blankPathIsCorrective() async throws {
        let context = FileContext(root: TestSupport.makeTemporaryDirectory(named: "WriteFileTests"))
        let output = try await Self.makeOperation(filePath: "   ", content: "x").execute(in: context)
        let message = try #require(output.correctiveValue)

        #expect(!message.isEmpty)
    }

    // MARK: Content-size cap

    @Test func contentOneByteOverCapIsCorrective() async throws {
        let root = TestSupport.makeTemporaryDirectory(named: "WriteFileTests")
        let path = root.appendingPathComponent("big.txt", isDirectory: false).path
        let context = FileContext(root: root)
        let oversized = String(repeating: "a", count: Self.contentByteCap + 1)

        let output = try await Self.makeOperation(filePath: path, content: oversized).execute(in: context)
        let message = try #require(output.correctiveValue)

        #expect(message.contains("content"))
        #expect(!FileManager.default.fileExists(atPath: path), "an over-cap write must not create the file")
    }

    @Test func contentExactlyAtCapIsAccepted() async throws {
        let root = TestSupport.makeTemporaryDirectory(named: "WriteFileTests")
        let path = root.appendingPathComponent("atcap.txt", isDirectory: false).path
        let context = FileContext(root: root)
        let atCap = String(repeating: "a", count: Self.contentByteCap)

        let output = try await Self.makeOperation(filePath: path, content: atCap).execute(in: context)
        let result = try #require(output.resultValue)

        #expect(result.bytesWritten == Self.contentByteCap)
    }

    // MARK: Read-only target

    @Test func readOnlyTargetIsCorrectiveAndLeavesItUntouched() async throws {
        let root = TestSupport.makeTemporaryDirectory(named: "WriteFileTests")
        let url = root.appendingPathComponent("locked.txt", isDirectory: false)
        try Data("original\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
        let context = FileContext(root: root)

        let output = try await Self.makeOperation(filePath: url.path, content: "overwrite\n").execute(in: context)
        let message = try #require(output.correctiveValue)

        #expect(!message.isEmpty)
        #expect(try Self.readBytes(url.path) == Data("original\n".utf8), "a read-only target must be untouched")
    }

    // MARK: Cleanup on failure

    @Test func renameFailureWhenTargetIsADirectoryIsCorrectiveAndLeavesNoTempFiles() async throws {
        let root = TestSupport.makeTemporaryDirectory(named: "WriteFileTests")
        let directoryTarget = root.appendingPathComponent("target-dir", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryTarget, withIntermediateDirectories: true)
        let context = FileContext(root: root)

        let output = try await Self.makeOperation(filePath: directoryTarget.path, content: "data\n").execute(in: context)
        let message = try #require(output.correctiveValue)

        #expect(!message.isEmpty)
        #expect(Self.temporaryFileLeftovers(in: root).isEmpty, "rename failure must remove the temporary file")
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: directoryTarget.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue, "the directory target must be untouched")
    }

    @Test func writeFailureIntoAReadOnlyDirectoryIsCorrectiveAndLeavesNoTempFiles() async throws {
        let root = TestSupport.makeTemporaryDirectory(named: "WriteFileTests")
        let readOnlyDirectory = root.appendingPathComponent("read-only", isDirectory: true)
        try FileManager.default.createDirectory(at: readOnlyDirectory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: readOnlyDirectory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: readOnlyDirectory.path) }
        let target = readOnlyDirectory.appendingPathComponent("blocked.txt", isDirectory: false)
        let context = FileContext(root: root)

        let output = try await Self.makeOperation(filePath: target.path, content: "data\n").execute(in: context)
        let message = try #require(output.correctiveValue)

        #expect(!message.isEmpty)
        #expect(Self.temporaryFileLeftovers(in: readOnlyDirectory).isEmpty, "write failure must remove the temporary file")
        #expect(!FileManager.default.fileExists(atPath: target.path), "a failed write must not create the target")
    }

    // MARK: Unicode and empty content

    @Test func unicodeContentRoundTripsOnDisk() async throws {
        let root = TestSupport.makeTemporaryDirectory(named: "WriteFileTests")
        let url = root.appendingPathComponent("unicode.txt", isDirectory: false)
        let text = "h\u{00E9}llo \u{1F30D}\n\u{0441}\u{0432}\u{0456}\u{0442}\n"
        let context = FileContext(root: root)

        let output = try await Self.makeOperation(filePath: url.path, content: text).execute(in: context)
        let result = try #require(output.resultValue)

        #expect(try Self.readBytes(url.path) == Data(text.utf8))
        #expect(result.bytesWritten == Data(text.utf8).count)
    }

    @Test func emptyContentWritesAnEmptyFile() async throws {
        let root = TestSupport.makeTemporaryDirectory(named: "WriteFileTests")
        let url = root.appendingPathComponent("empty.txt", isDirectory: false)
        let context = FileContext(root: root)

        let output = try await Self.makeOperation(filePath: url.path, content: "").execute(in: context)
        let result = try #require(output.resultValue)

        #expect(try Self.readBytes(url.path).isEmpty)
        #expect(result.bytesWritten == 0)
        #expect(result.taggedContent.isEmpty)
        #expect(result.hash == Hashline.wholeFileHash(bytes: Data()))
    }

    // MARK: Permission preservation

    @Test func overwritingPreservesExecutablePermissionBits() async throws {
        let root = TestSupport.makeTemporaryDirectory(named: "WriteFileTests")
        let url = root.appendingPathComponent("script.sh", isDirectory: false)
        try Data("#!/bin/sh\necho old\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        let context = FileContext(root: root)

        let output = try await Self.makeOperation(filePath: url.path, content: "#!/bin/sh\necho new\n").execute(in: context)
        _ = try #require(output.resultValue)

        #expect(Self.permissionBits(url.path) == 0o755, "overwriting a 0755 file must keep it 0755")
    }

    // MARK: Envelope fields

    @Test func envelopeBytesWrittenCountsUTF8Bytes() async throws {
        let root = TestSupport.makeTemporaryDirectory(named: "WriteFileTests")
        let url = root.appendingPathComponent("bytes.txt", isDirectory: false)
        // A multi-byte scalar makes byte count differ from character count.
        let text = "a\u{1F30D}b"
        let context = FileContext(root: root)

        let output = try await Self.makeOperation(filePath: url.path, content: text).execute(in: context)
        let result = try #require(output.resultValue)

        #expect(result.bytesWritten == Data(text.utf8).count)
        #expect(result.bytesWritten != text.count, "byte count must not be conflated with character count")
    }

    @Test func envelopeHashEqualsASubsequentReadToken() async throws {
        let root = TestSupport.makeTemporaryDirectory(named: "WriteFileTests")
        let url = root.appendingPathComponent("hash.txt", isDirectory: false)
        let text = "alpha\nbeta\ngamma\n"
        let context = FileContext(root: root)

        let writeOutput = try await Self.makeOperation(filePath: url.path, content: text).execute(in: context)
        let writeResult = try #require(writeOutput.resultValue)

        let readOutput = try await ReadFile(GeneratedContent(properties: [("path", url.path)], uniquingKeysWith: { _, new in new }))
            .execute(in: context)
        let readResult = try #require(readOutput.resultValue)

        #expect(writeResult.hash == readResult.hash)
        #expect(writeResult.hash == Hashline.wholeFileHash(bytes: Data(text.utf8)))
    }

    @Test func envelopeTaggedContentEqualsSubsequentReadBackTagging() async throws {
        let root = TestSupport.makeTemporaryDirectory(named: "WriteFileTests")
        let url = root.appendingPathComponent("tagged.txt", isDirectory: false)
        let text = "first line\nsecond line\nthird line\n"
        let context = FileContext(root: root)

        let writeOutput = try await Self.makeOperation(filePath: url.path, content: text).execute(in: context)
        let writeResult = try #require(writeOutput.resultValue)

        let readOutput = try await ReadFile(GeneratedContent(properties: [("path", url.path)], uniquingKeysWith: { _, new in new }))
            .execute(in: context)
        let readResult = try #require(readOutput.resultValue)

        #expect(writeResult.taggedContent == readResult.lines)
        #expect(writeResult.taggedContent.first?.hasPrefix("1:") == true)
    }
}

/// Test-only pattern-matching accessors over ``WriteOutput``.
extension WriteOutput {
    /// The successful ``WriteResult``, or `nil` when the output is corrective.
    var resultValue: WriteResult? {
        if case .content(let result) = self { return result }
        return nil
    }

    /// The corrective message, or `nil` when the output carries a result.
    var correctiveValue: String? {
        if case .corrective(let message) = self { return message }
        return nil
    }
}
