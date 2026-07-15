import Foundation
import FoundationModels
import Testing

@testable import FileTool

/// Behavioral tests for the ``GlobEngine`` and the ``GlobFiles`` operation.
///
/// Every case in the `glob files` plan row is exercised: the git-aware walk
/// hiding a gitignored file by default and surfacing it when
/// `respectGitIgnore` is off, the non-repository `FileManager` fallback walk,
/// the full broad-pattern matrix (each broad pattern rejected unscoped and
/// allowed once a `path` scopes the walk), case sensitivity in both
/// directions, strict mtime-descending ordering with explicitly set file
/// dates, the honest `capped` flag via an injected small `maxResults`, the
/// nonexistent-directory corrective, the pattern-too-long corrective, and the
/// invalid-glob-syntax corrective.
@Suite struct GlobFilesTests {
    // MARK: Test scaffolding

    /// Create a fresh temporary directory for a `glob files` test.
    ///
    /// - Returns: the URL of a fresh temporary directory owned by this suite.
    private static func makeDirectory() -> URL {
        TestSupport.makeTemporaryDirectory(named: "GlobFilesTests")
    }

    /// Write a file (creating any intermediate directories) with an optional modification date.
    ///
    /// - Parameters:
    ///   - name: the file name (may contain `/` to create nested directories).
    ///   - directory: the directory to create the file under.
    ///   - contents: the UTF-8 text content to write.
    ///   - modified: the modification date to stamp, or `nil` to leave the
    ///     filesystem default.
    /// - Returns: the URL of the written file.
    @discardableResult
    private static func write(
        _ name: String,
        in directory: URL,
        contents: String = "content",
        modified: Date? = nil
    ) throws -> URL {
        let url = directory.appendingPathComponent(name, isDirectory: false)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: url)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
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

    /// Build a ``GlobFiles`` operation from its parameter payload.
    ///
    /// - Parameters:
    ///   - pattern: the glob pattern.
    ///   - path: the optional search directory.
    ///   - caseSensitive: the optional case-sensitivity flag.
    ///   - respectGitIgnore: the optional gitignore-respecting flag.
    /// - Returns: the decoded ``GlobFiles`` operation.
    private static func makeOperation(
        pattern: String,
        path: String? = nil,
        caseSensitive: Bool? = nil,
        respectGitIgnore: Bool? = nil
    ) throws -> GlobFiles {
        var properties: [(String, any ConvertibleToGeneratedContent)] = [("pattern", pattern)]
        if let path { properties.append(("path", path)) }
        if let caseSensitive { properties.append(("caseSensitive", caseSensitive)) }
        if let respectGitIgnore { properties.append(("respectGitIgnore", respectGitIgnore)) }
        return try GlobFiles(GeneratedContent(properties: properties, uniquingKeysWith: { _, new in new }))
    }

    // MARK: Gitignore awareness

    @Test func gitignoredFileIsAbsentByDefault() throws {
        let root = Self.makeDirectory()
        try Self.runGit(["init"], in: root)
        try Self.write(".gitignore", in: root, contents: "*.log\n")
        try Self.write("keep.txt", in: root)
        try Self.write("debug.log", in: root)

        let output = GlobEngine().run(pattern: "*.log", in: FileContext(root: root))
        let result = try #require(output.resultValue)

        #expect(!result.files.contains("debug.log"))
        #expect(result.total == 0)
    }

    @Test func gitignoredFileIsPresentWhenRespectGitIgnoreIsFalse() throws {
        let root = Self.makeDirectory()
        try Self.runGit(["init"], in: root)
        try Self.write(".gitignore", in: root, contents: "*.log\n")
        try Self.write("keep.txt", in: root)
        try Self.write("debug.log", in: root)

        let output = GlobEngine().run(pattern: "*.log", respectGitIgnore: false, in: FileContext(root: root))
        let result = try #require(output.resultValue)

        #expect(result.files.contains("debug.log"))
    }

    @Test func gitTrackedAndUntrackedNonIgnoredFilesAreVisible() throws {
        let root = Self.makeDirectory()
        try Self.runGit(["init"], in: root)
        try Self.write(".gitignore", in: root, contents: "*.log\n")
        try Self.write("keep.txt", in: root)
        try Self.write("notes.txt", in: root)
        try Self.write("debug.log", in: root)

        let output = GlobEngine().run(pattern: "*.txt", in: FileContext(root: root))
        let result = try #require(output.resultValue)

        #expect(Set(result.files) == ["keep.txt", "notes.txt"])
    }

    @Test func gitScopedSubdirectoryReturnsSessionRelativePaths() throws {
        let root = Self.makeDirectory()
        try Self.runGit(["init"], in: root)
        try Self.write("sub/a.txt", in: root)
        try Self.write("sub/deep/b.txt", in: root)
        try Self.write("top.txt", in: root)
        let subdirectory = root.appendingPathComponent("sub", isDirectory: true)

        let output = GlobEngine().run(pattern: "**/*.txt", path: subdirectory.path, in: FileContext(root: root))
        let result = try #require(output.resultValue)

        #expect(Set(result.files) == ["sub/a.txt", "sub/deep/b.txt"])
    }

    // MARK: Non-repository fallback

    @Test func nonRepositoryFallbackWalkFindsFiles() throws {
        let root = Self.makeDirectory()
        try Self.write("foo.txt", in: root)
        try Self.write("bar.txt", in: root)

        let output = GlobEngine().run(pattern: "*.txt", in: FileContext(root: root))
        let result = try #require(output.resultValue)

        #expect(Set(result.files) == ["foo.txt", "bar.txt"])
    }

    @Test func relativePathPatternMatchesNestedFiles() throws {
        let root = Self.makeDirectory()
        try Self.write("src/deep/nested.swift", in: root)
        try Self.write("top.swift", in: root)

        let output = GlobEngine().run(pattern: "**/*.swift", path: root.path, in: FileContext(root: root))
        let result = try #require(output.resultValue)

        #expect(Set(result.files) == ["src/deep/nested.swift", "top.swift"])
    }

    // MARK: Broad-pattern matrix

    /// The broad patterns rejected when the walk is unscoped by a `path`.
    private static let broadPatterns = ["*", "**", "**/*", "*.*", "**/*.swift"]

    @Test func broadPatternsAreRejectedWhenUnscoped() throws {
        let root = Self.makeDirectory()
        try Self.write("a.txt", in: root)
        try Self.write("b.swift", in: root)

        for pattern in Self.broadPatterns {
            let output = GlobEngine().run(pattern: pattern, in: FileContext(root: root))
            let message = try #require(output.correctiveValue, "expected \(pattern) to be rejected unscoped")
            #expect(message.contains("path"), "expected guidance to scope with a path, got: \(message)")
        }
    }

    @Test func broadPatternsAreAllowedWhenScopedByPath() throws {
        let root = Self.makeDirectory()
        try Self.write("a.txt", in: root)
        try Self.write("b.swift", in: root)

        for pattern in Self.broadPatterns {
            let output = GlobEngine().run(pattern: pattern, path: root.path, in: FileContext(root: root))
            #expect(output.resultValue != nil, "expected \(pattern) to be allowed when scoped")
        }
    }

    // MARK: Case sensitivity

    @Test func caseInsensitiveMatchingIsTheDefault() throws {
        let root = Self.makeDirectory()
        try Self.write("README.md", in: root)

        let output = GlobEngine().run(pattern: "readme.md", in: FileContext(root: root))
        let result = try #require(output.resultValue)

        #expect(result.files == ["README.md"])
    }

    @Test func caseSensitiveMatchingRejectsMismatchedCase() throws {
        let root = Self.makeDirectory()
        try Self.write("README.md", in: root)

        let output = GlobEngine().run(pattern: "readme.md", caseSensitive: true, in: FileContext(root: root))
        let result = try #require(output.resultValue)

        #expect(result.files.isEmpty)
    }

    // MARK: Ordering

    @Test func resultsAreOrderedByModificationTimeNewestFirst() throws {
        let root = Self.makeDirectory()
        let now = Date()
        try Self.write("a.txt", in: root, modified: now.addingTimeInterval(-300))
        try Self.write("b.txt", in: root, modified: now.addingTimeInterval(-200))
        try Self.write("c.txt", in: root, modified: now.addingTimeInterval(-100))

        let output = GlobEngine().run(pattern: "*.txt", in: FileContext(root: root))
        let result = try #require(output.resultValue)

        #expect(result.files == ["c.txt", "b.txt", "a.txt"])
    }

    // MARK: Result cap

    @Test func capIsHonoredWithHonestCappedFlag() throws {
        let root = Self.makeDirectory()
        let now = Date()
        for index in 1...5 {
            try Self.write("f\(index).txt", in: root, modified: now.addingTimeInterval(Double(index) * 100))
        }

        let output = GlobEngine(maxResults: 2).run(pattern: "*.txt", in: FileContext(root: root))
        let result = try #require(output.resultValue)

        #expect(result.total == 5)
        #expect(result.capped)
        #expect(result.files.count == 2)
        #expect(result.files == ["f5.txt", "f4.txt"])
    }

    @Test func belowCapReportsNotCapped() throws {
        let root = Self.makeDirectory()
        try Self.write("only.txt", in: root)

        let output = GlobEngine(maxResults: 10).run(pattern: "*.txt", in: FileContext(root: root))
        let result = try #require(output.resultValue)

        #expect(result.total == 1)
        #expect(!result.capped)
        #expect(result.files == ["only.txt"])
    }

    // MARK: Corrective outcomes

    @Test func nonexistentDirectoryIsCorrective() throws {
        let root = Self.makeDirectory()
        let missing = root.appendingPathComponent("does-not-exist", isDirectory: true)

        let output = GlobEngine().run(pattern: "*.txt", path: missing.path, in: FileContext(root: root))
        let message = try #require(output.correctiveValue)

        #expect(!message.isEmpty)
    }

    @Test func patternTooLongIsCorrective() throws {
        let root = Self.makeDirectory()
        let pattern = String(repeating: "a", count: 1001)

        let output = GlobEngine().run(pattern: pattern, path: root.path, in: FileContext(root: root))
        let message = try #require(output.correctiveValue)

        #expect(message.contains("1000"))
    }

    @Test func invalidPatternSyntaxIsCorrective() throws {
        let root = Self.makeDirectory()

        let output = GlobEngine().run(pattern: "[", path: root.path, in: FileContext(root: root))
        let message = try #require(output.correctiveValue)

        #expect(!message.isEmpty)
    }

    // MARK: Operation wiring

    @Test func operationAppliesDefaultsAndReturnsContent() async throws {
        let root = Self.makeDirectory()
        try Self.write("foo.txt", in: root)

        let output = try await Self.makeOperation(pattern: "*.txt").execute(in: FileContext(root: root))
        let result = try #require(output.resultValue)

        #expect(result.files == ["foo.txt"])
        #expect(result.pattern == "*.txt")
    }
}

/// Test-only pattern-matching accessors over ``GlobOutput``.
extension GlobOutput {
    /// The successful ``GlobResult``, or `nil` when the output is corrective.
    var resultValue: GlobResult? {
        if case .content(let result) = self { return result }
        return nil
    }

    /// The corrective message, or `nil` when the output carries a result.
    var correctiveValue: String? {
        if case .corrective(let message) = self { return message }
        return nil
    }
}
