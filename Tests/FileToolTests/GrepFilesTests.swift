import Foundation
import FoundationModels
import Testing

@testable import FileTool

/// Behavioral tests for the ``GrepEngine`` and the ``GrepFiles`` operation.
///
/// Every case in the `grep files` plan row is exercised: a basic line match in
/// the default `content` mode, the invalid-regex corrective, case-insensitive
/// matching via the `caseInsensitive` flag, the file-type filter (a match
/// restricted to a type plus the unknown-type corrective listing the known
/// ones), the filename `glob` filter, all three output modes and their distinct
/// shapes, context assembly at 0 / 2 / N lines including hunk boundaries between
/// non-adjacent groups and the file-boundary edges, the null-byte binary skip,
/// the single-file path short-circuit, the nonexistent-path corrective, and the
/// git-aware walk never descending into a gitignored directory.
@Suite struct GrepFilesTests {
    // MARK: Test scaffolding

    /// Create a fresh temporary directory for a `grep files` test.
    ///
    /// - Returns: the URL of a fresh temporary directory owned by this suite.
    private static func makeDirectory() -> URL {
        TestSupport.makeTemporaryDirectory(named: "GrepFilesTests")
    }

    /// Write a UTF-8 text file, creating any intermediate directories.
    ///
    /// - Parameters:
    ///   - name: the file name (may contain `/` to create nested directories).
    ///   - directory: the directory to create the file under.
    ///   - contents: the UTF-8 text content to write.
    /// - Returns: the URL of the written file.
    @discardableResult
    private static func write(_ name: String, in directory: URL, contents: String) throws -> URL {
        let url = directory.appendingPathComponent(name, isDirectory: false)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: url)
        return url
    }

    /// Write a file of raw bytes, creating any intermediate directories.
    ///
    /// - Parameters:
    ///   - name: the file name.
    ///   - directory: the directory to create the file under.
    ///   - bytes: the raw bytes to write.
    /// - Returns: the URL of the written file.
    @discardableResult
    private static func writeBytes(_ name: String, in directory: URL, bytes: [UInt8]) throws -> URL {
        let url = directory.appendingPathComponent(name, isDirectory: false)
        try Data(bytes).write(to: url)
        return url
    }

    /// Run a `git` subcommand in a directory, failing the test on a nonzero exit.
    ///
    /// - Parameters:
    ///   - arguments: the `git` subcommand and its arguments.
    ///   - directory: the working directory to run `git` in.
    private static func runGit(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = directory
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "git \(arguments.joined(separator: " ")) failed")
    }

    /// Build a ``GrepFiles`` operation from its parameter payload.
    ///
    /// - Parameters:
    ///   - pattern: the regular-expression pattern.
    ///   - path: the optional file or directory to search.
    ///   - glob: the optional filename filter.
    ///   - type: the optional file-type filter.
    ///   - caseInsensitive: the optional case-insensitivity flag.
    ///   - contextLines: the optional context-line count.
    ///   - outputMode: the optional output mode.
    /// - Returns: the decoded ``GrepFiles`` operation.
    private static func makeOperation(
        pattern: String,
        path: String? = nil,
        glob: String? = nil,
        type: String? = nil,
        caseInsensitive: Bool? = nil,
        contextLines: Int? = nil,
        outputMode: String? = nil
    ) throws -> GrepFiles {
        var properties: [(String, any ConvertibleToGeneratedContent)] = [("pattern", pattern)]
        if let path { properties.append(("path", path)) }
        if let glob { properties.append(("glob", glob)) }
        if let type { properties.append(("type", type)) }
        if let caseInsensitive { properties.append(("caseInsensitive", caseInsensitive)) }
        if let contextLines { properties.append(("contextLines", contextLines)) }
        if let outputMode { properties.append(("outputMode", outputMode)) }
        return try GrepFiles(GeneratedContent(properties: properties, uniquingKeysWith: { _, new in new }))
    }

    // MARK: Basic matching

    @Test func basicMatchReturnsTheMatchingLine() throws {
        let root = Self.makeDirectory()
        try Self.write("a.txt", in: root, contents: "alpha\nbeta\ngamma\n")

        let output = GrepEngine().run(pattern: "beta", contextLines: 0, in: FileContext(root: root))
        let result = try #require(output.resultValue)

        let matches = try #require(result.matches)
        #expect(matches.count == 1)
        #expect(matches[0].file == "a.txt")
        #expect(matches[0].line == 2)
        #expect(matches[0].text == "beta")
        #expect(matches[0].isMatch)
        #expect(result.matchCount == 1)
        #expect(result.fileCount == 1)
    }

    @Test func regexPatternMatchesAcrossLines() throws {
        let root = Self.makeDirectory()
        try Self.write("a.txt", in: root, contents: "foo123\nbar\nbaz456\n")

        let output = GrepEngine().run(pattern: "[0-9]+", contextLines: 0, in: FileContext(root: root))
        let result = try #require(output.resultValue)

        #expect(result.matchCount == 2)
        #expect(Set((result.matches ?? []).map(\.line)) == [1, 3])
    }

    // MARK: Corrective outcomes

    @Test func invalidRegexIsCorrective() throws {
        let root = Self.makeDirectory()
        try Self.write("a.txt", in: root, contents: "text\n")

        let output = GrepEngine().run(pattern: "(unterminated", in: FileContext(root: root))
        let message = try #require(output.correctiveValue)

        #expect(!message.isEmpty)
    }

    @Test func nonexistentPathIsCorrective() throws {
        let root = Self.makeDirectory()
        let missing = root.appendingPathComponent("does-not-exist", isDirectory: false)

        let output = GrepEngine().run(pattern: "x", path: missing.path, in: FileContext(root: root))
        let message = try #require(output.correctiveValue)

        #expect(!message.isEmpty)
    }

    // MARK: Case sensitivity

    @Test func caseInsensitiveMatchingFindsMixedCase() throws {
        let root = Self.makeDirectory()
        try Self.write("a.txt", in: root, contents: "Hello World\n")

        let output = GrepEngine().run(pattern: "WORLD", caseInsensitive: true, contextLines: 0, in: FileContext(root: root))
        let result = try #require(output.resultValue)

        #expect(result.matchCount == 1)
    }

    @Test func caseSensitiveMatchingIsTheDefault() throws {
        let root = Self.makeDirectory()
        try Self.write("a.txt", in: root, contents: "Hello World\n")

        let output = GrepEngine().run(pattern: "WORLD", contextLines: 0, in: FileContext(root: root))
        let result = try #require(output.resultValue)

        #expect(result.matchCount == 0)
    }

    // MARK: Type filter

    @Test func typeFilterRestrictsToMatchingExtensions() throws {
        let root = Self.makeDirectory()
        try Self.write("code.swift", in: root, contents: "// TODO fix\n")
        try Self.write("notes.txt", in: root, contents: "TODO fix\n")

        let output = GrepEngine().run(pattern: "TODO", path: root.path, type: "swift", contextLines: 0, in: FileContext(root: root))
        let result = try #require(output.resultValue)

        #expect(result.matchCount == 1)
        #expect((result.matches ?? []).allSatisfy { $0.file == "code.swift" })
    }

    @Test func unknownTypeIsCorrectiveListingKnownTypes() throws {
        let root = Self.makeDirectory()
        try Self.write("code.swift", in: root, contents: "TODO\n")

        let output = GrepEngine().run(pattern: "TODO", path: root.path, type: "cobol", in: FileContext(root: root))
        let message = try #require(output.correctiveValue)

        #expect(message.contains("swift"))
    }

    // MARK: Glob filter

    @Test func globFilterRestrictsToMatchingFilenames() throws {
        let root = Self.makeDirectory()
        try Self.write("a.swift", in: root, contents: "match\n")
        try Self.write("b.txt", in: root, contents: "match\n")

        let output = GrepEngine().run(pattern: "match", path: root.path, glob: "*.txt", contextLines: 0, in: FileContext(root: root))
        let result = try #require(output.resultValue)

        #expect(result.matchCount == 1)
        #expect((result.matches ?? []).allSatisfy { $0.file == "b.txt" })
    }

    // MARK: Output modes

    @Test func filesWithMatchesModeReturnsFileListOnly() throws {
        let root = Self.makeDirectory()
        try Self.write("a.txt", in: root, contents: "match\n")
        try Self.write("b.txt", in: root, contents: "match\n")

        let output = GrepEngine().run(pattern: "match", path: root.path, outputMode: "filesWithMatches", in: FileContext(root: root))
        let result = try #require(output.resultValue)

        #expect(result.matches == nil)
        let files = try #require(result.files)
        #expect(Set(files) == ["a.txt", "b.txt"])
        #expect(result.fileCount == 2)
        #expect(result.matchCount == 2)
    }

    @Test func countModeReturnsCountsOnly() throws {
        let root = Self.makeDirectory()
        try Self.write("a.txt", in: root, contents: "match\nmatch\n")
        try Self.write("b.txt", in: root, contents: "match\n")

        let output = GrepEngine().run(pattern: "match", path: root.path, outputMode: "count", in: FileContext(root: root))
        let result = try #require(output.resultValue)

        #expect(result.matches == nil)
        #expect(result.files == nil)
        #expect(result.matchCount == 3)
        #expect(result.fileCount == 2)
    }

    @Test func contentModeIsTheDefault() throws {
        let root = Self.makeDirectory()
        try Self.write("a.txt", in: root, contents: "match\n")

        let output = GrepEngine().run(pattern: "match", path: root.path, in: FileContext(root: root))
        let result = try #require(output.resultValue)

        #expect(result.matches != nil)
    }

    // MARK: Context assembly

    @Test func contextLinesZeroReturnsOnlyMatchLines() throws {
        let root = Self.makeDirectory()
        try Self.write("a.txt", in: root, contents: "one\ntwo\nthree\nfour\nfive\n")

        let output = GrepEngine().run(pattern: "three", contextLines: 0, in: FileContext(root: root))
        let result = try #require(output.resultValue)

        let matches = try #require(result.matches)
        #expect(matches.map(\.line) == [3])
        #expect(matches.map(\.isMatch) == [true])
    }

    @Test func contextLinesTwoIncludesSurroundingContextFlaggedNotMatch() throws {
        let root = Self.makeDirectory()
        try Self.write("a.txt", in: root, contents: "one\ntwo\nthree\nfour\nfive\n")

        let output = GrepEngine().run(pattern: "three", contextLines: 2, in: FileContext(root: root))
        let result = try #require(output.resultValue)

        let matches = try #require(result.matches)
        #expect(matches.map(\.line) == [1, 2, 3, 4, 5])
        #expect(matches.filter(\.isMatch).map(\.line) == [3])
        #expect(matches.filter { !$0.isMatch }.map(\.line) == [1, 2, 4, 5])
        // Only the match line counts toward the total.
        #expect(result.matchCount == 1)
    }

    @Test func negativeContextLinesDegradeToMatchLinesOnly() throws {
        let root = Self.makeDirectory()
        try Self.write("a.txt", in: root, contents: "one\ntwo\nthree\n")

        let output = GrepEngine().run(pattern: "two", contextLines: -1, in: FileContext(root: root))
        let result = try #require(output.resultValue)

        // A negative context must not silently drop the matched line while still
        // counting it: matchCount and the emitted content stay consistent.
        let matches = try #require(result.matches)
        #expect(matches.map(\.line) == [2])
        #expect(matches.map(\.isMatch) == [true])
        #expect(result.matchCount == 1)
    }

    @Test func contextIsClampedAtFileBoundaries() throws {
        let root = Self.makeDirectory()
        try Self.write("a.txt", in: root, contents: "one\ntwo\nthree\n")

        let firstLine = GrepEngine().run(pattern: "one", contextLines: 2, in: FileContext(root: root))
        let firstResult = try #require(firstLine.resultValue)
        let firstLines = try #require(firstResult.matches).map(\.line)
        #expect(firstLines == [1, 2, 3])

        let lastLine = GrepEngine().run(pattern: "three", contextLines: 2, in: FileContext(root: root))
        let lastResult = try #require(lastLine.resultValue)
        let lastLines = try #require(lastResult.matches).map(\.line)
        #expect(lastLines == [1, 2, 3])
    }

    @Test func nonAdjacentMatchesFormSeparateHunksWithAGap() throws {
        let root = Self.makeDirectory()
        try Self.write(
            "a.txt",
            in: root,
            contents: "a\nm1\nc\nd\ne\nf\ng\nm2\ni\n"
        )

        let output = GrepEngine().run(pattern: "^m", contextLines: 1, in: FileContext(root: root))
        let result = try #require(output.resultValue)

        // Match lines 2 and 8 give windows [1,3] and [7,9], which never touch:
        // the gap (lines 4,5,6) is the hunk boundary.
        let hunkLines = try #require(result.matches).map(\.line)
        #expect(hunkLines == [1, 2, 3, 7, 8, 9])
        #expect(result.matchCount == 2)
    }

    @Test func adjacentMatchWindowsMergeIntoOneHunk() throws {
        let root = Self.makeDirectory()
        try Self.write(
            "a.txt",
            in: root,
            contents: "m1\nb\nm2\nd\ne\n"
        )

        let output = GrepEngine().run(pattern: "^m", contextLines: 1, in: FileContext(root: root))
        let result = try #require(output.resultValue)

        // Windows [1,3] and [2,4] overlap, so the hunk is contiguous [1,4].
        let matches = try #require(result.matches)
        #expect(matches.map(\.line) == [1, 2, 3, 4])
        #expect(matches.filter(\.isMatch).map(\.line) == [1, 3])
    }

    // MARK: Binary skip

    @Test func binaryFileIsSkipped() throws {
        let root = Self.makeDirectory()
        // A NUL byte within the first bytes marks the file as binary.
        try Self.writeBytes("bin.dat", in: root, bytes: Array("match".utf8) + [0x00] + Array("match".utf8))

        let output = GrepEngine().run(pattern: "match", path: root.path, contextLines: 0, in: FileContext(root: root))
        let result = try #require(output.resultValue)

        #expect(result.matchCount == 0)
    }

    // MARK: Single-file short-circuit

    @Test func singleFilePathGrepsThatFileDirectly() throws {
        let root = Self.makeDirectory()
        let file = try Self.write("only.txt", in: root, contents: "needle here\nno match\n")

        let output = GrepEngine().run(pattern: "needle", path: file.path, contextLines: 0, in: FileContext(root: root))
        let result = try #require(output.resultValue)

        #expect(result.matchCount == 1)
        #expect((result.matches ?? []).allSatisfy { $0.file == "only.txt" })
    }

    // MARK: Gitignore awareness

    @Test func gitignoredDirectoryIsNeverSearchedUnscoped() throws {
        let root = Self.makeDirectory()
        try Self.runGit(["init"], in: root)
        try Self.write(".gitignore", in: root, contents: "build/\n")
        try Self.write("keep.txt", in: root, contents: "match\n")
        try Self.write("build/generated.txt", in: root, contents: "match\n")

        let output = GrepEngine().run(pattern: "match", contextLines: 0, in: FileContext(root: root))
        let result = try #require(output.resultValue)

        #expect(result.fileCount == 1)
        #expect((result.matches ?? []).allSatisfy { $0.file == "keep.txt" })
    }

    // MARK: Operation wiring

    @Test func operationAppliesDefaultsAndReturnsContent() async throws {
        let root = Self.makeDirectory()
        try Self.write("a.txt", in: root, contents: "hello\n")

        let output = try await Self.makeOperation(pattern: "hello").execute(in: FileContext(root: root))
        let result = try #require(output.resultValue)

        #expect(result.matchCount == 1)
        #expect(result.matches != nil)
    }
}

/// Test-only pattern-matching accessors over ``GrepOutput``.
extension GrepOutput {
    /// The successful ``GrepResult``, or `nil` when the output is corrective.
    var resultValue: GrepResult? {
        if case .content(let result) = self { return result }
        return nil
    }

    /// The corrective message, or `nil` when the output carries a result.
    var correctiveValue: String? {
        if case .corrective(let message) = self { return message }
        return nil
    }
}
