import Foundation
import Testing

@testable import FileTool

/// Unit tests for the ``AtomicWriter`` primitive.
///
/// These cover the reusable capabilities the operations layer cannot reach
/// through ``PathGuard`` (which guarantees an existing parent before a write):
/// parent-directory creation for a deep target, and the encoding and
/// line-ending detection / re-encode hooks the `edit file` operation consumes.
/// The operation-level atomicity, cleanup, and permission-preservation
/// behaviors are exercised through the operation in ``WriteFileTests``.
@Suite struct AtomicWriterTests {
    // MARK: Test scaffolding

    /// Create a fresh, empty temporary directory and return its URL.
    ///
    /// - Returns: the URL of the freshly created temporary directory.
    private static func makeTemporaryDirectory() -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtomicWriterTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    // MARK: Parent-directory creation

    @Test func writeCreatesMissingParentDirectories() throws {
        let root = Self.makeTemporaryDirectory()
        let target = root
            .appendingPathComponent("deep", isDirectory: true)
            .appendingPathComponent("nested", isDirectory: true)
            .appendingPathComponent("file.txt", isDirectory: false)

        try AtomicWriter.write(Data("content\n".utf8), to: target)

        #expect(try Data(contentsOf: target) == Data("content\n".utf8))
    }

    // MARK: Line-ending detection

    @Test func detectsLineFeedEndings() {
        #expect(AtomicWriter.detectLineEnding(in: "a\nb\nc\n") == .lineFeed)
    }

    @Test func detectsCarriageReturnLineFeedEndings() {
        #expect(AtomicWriter.detectLineEnding(in: "a\r\nb\r\n") == .carriageReturnLineFeed)
    }

    @Test func detectsCarriageReturnEndings() {
        #expect(AtomicWriter.detectLineEnding(in: "a\rb\r") == .carriageReturn)
    }

    @Test func detectsMixedEndings() {
        #expect(AtomicWriter.detectLineEnding(in: "a\r\nb\nc\r") == .mixed)
    }

    @Test func detectsNoEndingsWhenUnterminated() {
        #expect(AtomicWriter.detectLineEnding(in: "no terminator") == nil)
    }

    // MARK: Encoding detection and re-encode

    @Test func decodesPlainUTF8() throws {
        let decoded = try #require(AtomicWriter.decode(Data("hello\n".utf8)))
        #expect(decoded.encoding == .utf8)
        #expect(decoded.text == "hello\n")
    }

    @Test func decodesUTF8WithByteOrderMarkStrippingTheMark() throws {
        var bytes = Data([0xEF, 0xBB, 0xBF])
        bytes.append(Data("hello\n".utf8))
        let decoded = try #require(AtomicWriter.decode(bytes))

        #expect(decoded.encoding == .utf8WithByteOrderMark)
        #expect(decoded.text == "hello\n", "the byte-order mark must be stripped from the decoded text")
    }

    @Test func rejectsUndecodableBytes() {
        #expect(AtomicWriter.decode(Data([0xFF, 0xFE, 0x00, 0x01, 0xFF, 0x80])) == nil)
    }

    @Test func plainUTF8RoundTripsThroughEncode() throws {
        let original = Data("re-encoded\n".utf8)
        let decoded = try #require(AtomicWriter.decode(original))
        #expect(AtomicWriter.encode(decoded.text, as: decoded.encoding) == original)
    }

    @Test func byteOrderMarkedUTF8RoundTripsThroughEncode() throws {
        var original = Data([0xEF, 0xBB, 0xBF])
        original.append(Data("re-encoded\n".utf8))
        let decoded = try #require(AtomicWriter.decode(original))
        #expect(AtomicWriter.encode(decoded.text, as: decoded.encoding) == original)
    }
}
