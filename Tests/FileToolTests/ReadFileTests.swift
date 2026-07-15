import Foundation
import FoundationModels
import Testing

@testable import FileTool

/// Behavioral tests for the ``ReadFile`` operation.
///
/// Every case in the `read file` plan row is exercised: offset / limit / both
/// windowing, each bound violation, absolute anchors under windowing, the
/// whole-file freshness token staying identical across windows, the `plain`
/// opt-out dropping anchors and per-line tags, binary rejection in both
/// formats, the empty file, unicode content, and the missing-path corrective.
@Suite struct ReadFileTests {
    // MARK: Test scaffolding

    /// Create a fresh, empty temporary directory and return its URL.
    ///
    /// The directory is created under the process temporary directory with a
    /// unique name so tests never collide; the operating system reclaims the
    /// temporary tree regardless of per-test cleanup.
    ///
    /// - Returns: the URL of the freshly created temporary directory.
    private static func makeTemporaryDirectory() -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReadFileTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// Write `data` to a file named `name` inside a fresh temporary directory.
    ///
    /// - Parameters:
    ///   - data: the raw bytes to write.
    ///   - name: the file name to create within the temporary directory.
    /// - Returns: the session ``FileContext`` rooted at the temporary directory
    ///   and the absolute path of the written file.
    private static func makeContext(
        writing data: Data,
        named name: String = "sample.txt"
    ) throws -> (context: FileContext, path: String) {
        let root = makeTemporaryDirectory()
        let fileURL = root.appendingPathComponent(name, isDirectory: false)
        try data.write(to: fileURL)
        return (FileContext(root: root), fileURL.path)
    }

    /// Write `text` (UTF-8) to a file named `name` inside a fresh temporary directory.
    ///
    /// - Parameters:
    ///   - text: the text content to write, encoded as UTF-8.
    ///   - name: the file name to create within the temporary directory.
    /// - Returns: the session ``FileContext`` rooted at the temporary directory
    ///   and the absolute path of the written file.
    private static func makeContext(
        writing text: String,
        named name: String = "sample.txt"
    ) throws -> (context: FileContext, path: String) {
        try makeContext(writing: Data(text.utf8), named: name)
    }

    /// Build a ``ReadFile`` operation from its parameter payload.
    ///
    /// - Parameters:
    ///   - path: the file path to read.
    ///   - offset: the optional 1-based start line.
    ///   - limit: the optional maximum line count.
    ///   - format: the optional output format name.
    /// - Returns: the decoded ``ReadFile`` operation.
    private static func makeOperation(
        path: String,
        offset: Int? = nil,
        limit: Int? = nil,
        format: String? = nil
    ) throws -> ReadFile {
        var properties: [(String, any ConvertibleToGeneratedContent)] = [("path", path)]
        if let offset { properties.append(("offset", offset)) }
        if let limit { properties.append(("limit", limit)) }
        if let format { properties.append(("format", format)) }
        return try ReadFile(GeneratedContent(properties: properties, uniquingKeysWith: { _, new in new }))
    }

    // MARK: Whole-file read

    @Test func readsWholeFileWithHashlineAnchorsByDefault() async throws {
        let (context, path) = try Self.makeContext(writing: "line one\nline two\nline three\n")
        let output = try await Self.makeOperation(path: path).execute(in: context)
        let result = try #require(output.resultValue)

        #expect(result.lines.count == 3)
        #expect(result.note == nil)
        for (offset, line) in result.lines.enumerated() {
            #expect(line.hasPrefix("\(offset + 1):"), "expected absolute anchor, got \(line)")
            #expect(line.contains("|"), "expected an anchor delimiter, got \(line)")
        }
    }

    @Test func wholeFileHashMatchesHashlineToken() async throws {
        let text = "alpha\nbeta\ngamma\n"
        let (context, path) = try Self.makeContext(writing: text)
        let output = try await Self.makeOperation(path: path).execute(in: context)
        let result = try #require(output.resultValue)

        #expect(result.hash == Hashline.wholeFileHash(bytes: Data(text.utf8)))
    }

    // MARK: Windowing

    @Test func offsetSkipsLeadingLines() async throws {
        let (context, path) = try Self.makeContext(writing: "one\ntwo\nthree\n")
        let output = try await Self.makeOperation(path: path, offset: 2).execute(in: context)
        let result = try #require(output.resultValue)

        #expect(result.lines.count == 2)
        #expect(result.lines[0].hasPrefix("2:"))
        #expect(result.lines[1].hasPrefix("3:"))
        #expect(result.note == "showing lines 2\u{2013}3 of 3")
    }

    @Test func limitTruncatesTrailingLines() async throws {
        let (context, path) = try Self.makeContext(writing: "one\ntwo\nthree\n")
        let output = try await Self.makeOperation(path: path, limit: 2).execute(in: context)
        let result = try #require(output.resultValue)

        #expect(result.lines.count == 2)
        #expect(result.lines[0].hasPrefix("1:"))
        #expect(result.lines[1].hasPrefix("2:"))
        #expect(result.note == "showing lines 1\u{2013}2 of 3")
    }

    @Test func offsetAndLimitSelectWindow() async throws {
        let (context, path) = try Self.makeContext(writing: "one\ntwo\nthree\nfour\n")
        let output = try await Self.makeOperation(path: path, offset: 2, limit: 1).execute(in: context)
        let result = try #require(output.resultValue)

        #expect(result.lines.count == 1)
        #expect(result.lines[0].hasPrefix("2:"))
        #expect(result.lines[0].hasSuffix("|two"))
        #expect(result.note == "showing lines 2\u{2013}2 of 4")
    }

    @Test func anchorsCarryAbsoluteLineNumbersUnderWindowing() async throws {
        let text = (1...100).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let (context, path) = try Self.makeContext(writing: text)
        let output = try await Self.makeOperation(path: path, offset: 60, limit: 3).execute(in: context)
        let result = try #require(output.resultValue)

        #expect(result.lines.count == 3)
        #expect(result.lines[0].hasPrefix("60:"))
        #expect(result.lines[1].hasPrefix("61:"))
        #expect(result.lines[2].hasPrefix("62:"))
        #expect(result.lines[0].hasSuffix("|line 60"))
        #expect(result.note == "showing lines 60\u{2013}62 of 100")
    }

    @Test func wholeFileTokenIsIdenticalAcrossWindows() async throws {
        let text = (1...20).map { "row \($0)" }.joined(separator: "\n") + "\n"
        let (context, path) = try Self.makeContext(writing: text)

        let whole = try #require(try await Self.makeOperation(path: path).execute(in: context).resultValue)
        let windowed = try #require(
            try await Self.makeOperation(path: path, offset: 5, limit: 4).execute(in: context).resultValue
        )

        #expect(whole.hash == windowed.hash)
        #expect(windowed.hash == Hashline.wholeFileHash(bytes: Data(text.utf8)))
    }

    // MARK: Plain opt-out

    @Test func plainFormatHasNoAnchorsOrPerLineTags() async throws {
        let (context, path) = try Self.makeContext(writing: "aaa\nbbb\nccc\n")
        let output = try await Self.makeOperation(path: path, offset: 2, limit: 1, format: "plain").execute(in: context)
        let result = try #require(output.resultValue)

        #expect(result.lines == ["bbb"])
        #expect(result.note == "showing lines 2\u{2013}2 of 3")
    }

    @Test func plainFormatReadsWholeFileVerbatim() async throws {
        let (context, path) = try Self.makeContext(writing: "first\nsecond\n")
        let output = try await Self.makeOperation(path: path, format: "plain").execute(in: context)
        let result = try #require(output.resultValue)

        #expect(result.lines == ["first", "second"])
        #expect(result.note == nil)
    }

    // MARK: Bound violations

    @Test func offsetBeyondBoundIsCorrective() async throws {
        let (context, path) = try Self.makeContext(writing: "one\n")
        let output = try await Self.makeOperation(path: path, offset: 1_000_001).execute(in: context)
        let message = try #require(output.correctiveValue)

        #expect(message.contains("1000000"))
    }

    @Test func offsetOfZeroIsCorrective() async throws {
        let (context, path) = try Self.makeContext(writing: "one\n")
        let output = try await Self.makeOperation(path: path, offset: 0).execute(in: context)
        let message = try #require(output.correctiveValue)

        #expect(message.contains("1000000"))
    }

    @Test func limitOfZeroIsCorrective() async throws {
        let (context, path) = try Self.makeContext(writing: "one\n")
        let output = try await Self.makeOperation(path: path, limit: 0).execute(in: context)
        let message = try #require(output.correctiveValue)

        #expect(message.contains("100000"))
    }

    @Test func limitBeyondBoundIsCorrective() async throws {
        let (context, path) = try Self.makeContext(writing: "one\n")
        let output = try await Self.makeOperation(path: path, limit: 100_001).execute(in: context)
        let message = try #require(output.correctiveValue)

        #expect(message.contains("100000"))
    }

    @Test func unknownFormatIsCorrective() async throws {
        let (context, path) = try Self.makeContext(writing: "one\n")
        let output = try await Self.makeOperation(path: path, format: "xml").execute(in: context)
        let message = try #require(output.correctiveValue)

        #expect(message.contains("hashline"))
        #expect(message.contains("plain"))
    }

    // MARK: Binary rejection

    /// Bytes that are never valid UTF-8, so decoding must fail.
    private static let binaryBytes = Data([0xFF, 0xFE, 0x00, 0x01, 0xFF, 0x80])

    @Test func binaryFileRejectedInHashlineFormat() async throws {
        let (context, path) = try Self.makeContext(writing: Self.binaryBytes, named: "blob.bin")
        let output = try await Self.makeOperation(path: path).execute(in: context)
        let message = try #require(output.correctiveValue)

        #expect(message.localizedCaseInsensitiveContains("utf-8") || message.localizedCaseInsensitiveContains("binary"))
        #expect(output.resultValue == nil, "binary content must never be decoded into a result")
    }

    @Test func binaryFileRejectedInPlainFormat() async throws {
        let (context, path) = try Self.makeContext(writing: Self.binaryBytes, named: "blob.bin")
        let output = try await Self.makeOperation(path: path, format: "plain").execute(in: context)
        let message = try #require(output.correctiveValue)

        #expect(message.localizedCaseInsensitiveContains("utf-8") || message.localizedCaseInsensitiveContains("binary"))
        #expect(output.resultValue == nil, "binary content must never be decoded into a result")
    }

    // MARK: Empty and unicode content

    @Test func emptyFileReadsAsNoLines() async throws {
        let (context, path) = try Self.makeContext(writing: "")
        let output = try await Self.makeOperation(path: path).execute(in: context)
        let result = try #require(output.resultValue)

        #expect(result.lines.isEmpty)
        #expect(result.note == nil)
        #expect(result.hash == Hashline.wholeFileHash(bytes: Data()))
    }

    @Test func unicodeContentIsPreserved() async throws {
        let text = "h\u{00E9}llo \u{1F30D}\n\u{0441}\u{0432}\u{0456}\u{0442}\n"
        let (context, path) = try Self.makeContext(writing: text)
        let output = try await Self.makeOperation(path: path).execute(in: context)
        let result = try #require(output.resultValue)

        #expect(result.lines.count == 2)
        #expect(result.lines[0].hasSuffix("|h\u{00E9}llo \u{1F30D}"))
        #expect(result.lines[1].hasSuffix("|\u{0441}\u{0432}\u{0456}\u{0442}"))
        #expect(result.hash == Hashline.wholeFileHash(bytes: Data(text.utf8)))
    }

    // MARK: Line-ending fidelity

    /// A read over content mixing every terminator (`\r\n`, `\r`, `\n`) plus an
    /// unterminated final line must tag contiguous absolute anchors line for
    /// line, guarding that the operation's physical-line split stays in lockstep
    /// with ``Hashline``'s line model across all terminator kinds.
    @Test func mixedLineEndingsTagContiguousAbsoluteAnchors() async throws {
        let (context, path) = try Self.makeContext(writing: "a\r\nb\rc\nd")
        let output = try await Self.makeOperation(path: path).execute(in: context)
        let result = try #require(output.resultValue)

        #expect(result.lines.count == 4)
        for (offset, line) in result.lines.enumerated() {
            #expect(line.hasPrefix("\(offset + 1):"), "expected contiguous absolute anchor, got \(line)")
        }
        #expect(result.lines[0].hasSuffix("|a"))
        #expect(result.lines[1].hasSuffix("|b"))
        #expect(result.lines[2].hasSuffix("|c"))
        #expect(result.lines[3].hasSuffix("|d"))
        #expect(result.note == nil)
    }

    // MARK: Missing path

    @Test func missingPathIsCorrective() async throws {
        let root = Self.makeTemporaryDirectory()
        let missing = root.appendingPathComponent("does-not-exist.txt", isDirectory: false)
        let context = FileContext(root: root)
        let output = try await Self.makeOperation(path: missing.path).execute(in: context)
        let message = try #require(output.correctiveValue)

        #expect(!message.isEmpty)
    }
}

/// Test-only pattern-matching accessors over ``ReadOutput``.
extension ReadOutput {
    /// The successful ``ReadResult``, or `nil` when the output is corrective.
    var resultValue: ReadResult? {
        if case .content(let result) = self { return result }
        return nil
    }

    /// The corrective message, or `nil` when the output carries a result.
    var correctiveValue: String? {
        if case .corrective(let message) = self { return message }
        return nil
    }
}
