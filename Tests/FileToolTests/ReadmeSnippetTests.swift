import Foundation
import Testing

/// Verifies plan.md task 12's "README's usage snippet compiles (doc-snippet
/// tested against the example source, the siblings' mechanism)" acceptance
/// criterion: every `<!-- doc-snippet source="..." --> ``` … ``` <!--
/// /doc-snippet -->` code block in the repo root's `README.md` is a genuine,
/// contiguous excerpt of the source file it cites — not hand-written
/// pseudocode that could drift out of sync with what actually compiles.
///
/// The cited sources are all part of the package's build graph (the compiled
/// `file-demo` example and the `FileTool` library), so proving every README
/// fence is a verbatim slice of one of them proves the README's usage
/// walkthrough genuinely compiles and cannot rot: change the API and the cited
/// source stops compiling; change the source without updating the README and
/// this test fails on the stale fence.
///
/// This mirrors the sibling `FoundationModelsOperationTool`'s
/// `Examples/NotesTool/Tests/NotesToolTests/ReadmeSnippetTests.swift`
/// doc-snippet provenance mechanism, re-implemented self-contained here (no
/// `TestSupport` / `swift-syntax` dependency) so it needs no new package
/// dependency.
@Suite("README code-snippet provenance")
struct ReadmeSnippetTests {
    /// The doc-snippet-bearing markdown file, relative to the package root.
    private static let docFile = "README.md"

    /// The source files the README's walkthrough must cite, so the declare →
    /// fuse → session → CLI story (and the diagnostics field it turns on) is
    /// always quoted from real, compiled source rather than prose.
    private static let requiredSources = [
        // The compiled declare → fuse → serve runnable example.
        "Examples/FileDemo/Sources/file-demo/ReadmeExample.swift",
        // The example executable's CLI / script-mode wiring.
        "Examples/FileDemo/Sources/file-demo/main.swift",
        // The library's diagnostics-result type — the field the edit → see
        // errors → fix loop reads.
        "Sources/FileTool/FileDiagnostics.swift",
    ]

    @Test("README has at least one doc-snippet block")
    func readmeContainsDocSnippets() throws {
        let snippets = try ReadmeSnippets.parse(fileContents(relativePath: Self.docFile))
        #expect(!snippets.isEmpty, "expected \(Self.docFile) to contain at least one <!-- doc-snippet --> block")
    }

    @Test("every doc-snippet code block is a real, contiguous excerpt of its cited source file")
    func everySnippetIsARealContiguousExcerptOfItsSource() throws {
        let snippets = try ReadmeSnippets.parse(fileContents(relativePath: Self.docFile))
        for snippet in snippets {
            let sourceLines = try sourceFileLines(relativePath: snippet.sourcePath)
            #expect(
                ReadmeSnippets.isContiguousExcerpt(snippet.code, of: sourceLines),
                Comment(rawValue: "README snippet citing '\(snippet.sourcePath)' is not a contiguous excerpt of that file")
            )
        }
    }

    @Test("the README quotes the declare/fuse/session/CLI walkthrough and the diagnostics field from real source")
    func readmeCitesEveryRequiredSource() throws {
        let snippets = try ReadmeSnippets.parse(fileContents(relativePath: Self.docFile))
        let citedSources = Set(snippets.map(\.sourcePath))
        for required in Self.requiredSources {
            #expect(
                citedSources.contains(required),
                Comment(rawValue: "expected README to cite '\(required)' in a <!-- doc-snippet --> block")
            )
        }
    }

    @Test("a doc-snippet source path that escapes the package root is rejected")
    func sourcePathOutsideThePackageRootIsRejected() {
        #expect(throws: (any Error).self) {
            _ = try sourceFileLines(relativePath: "../../../../../../etc/passwd")
        }
    }

    private func fileContents(relativePath: String) throws -> String {
        try String(contentsOf: packageRoot().appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func sourceFileLines(relativePath: String) throws -> [String] {
        let root = packageRoot()
        let fileURL = root.appendingPathComponent(relativePath).standardizedFileURL
        guard fileURL.path.hasPrefix(root.standardizedFileURL.path) else {
            throw PathEscapesPackageRoot(path: relativePath)
        }
        let contents = try String(contentsOf: fileURL, encoding: .utf8)
        return contents.components(separatedBy: "\n")
    }

    /// A source path cited by a README `doc-snippet` marker resolved outside
    /// the package root — e.g. via a `..` component.
    private struct PathEscapesPackageRoot: Error, CustomStringConvertible {
        let path: String
        var description: String { "'\(path)' resolves outside the package root" }
    }

    /// The package root directory, derived from this file's own path: three
    /// levels up from `Tests/FileToolTests/ReadmeSnippetTests.swift`.
    private func packageRoot(thisFile: String = #filePath) -> URL {
        URL(fileURLWithPath: thisFile)
            .deletingLastPathComponent()  // ReadmeSnippetTests.swift -> FileToolTests/
            .deletingLastPathComponent()  // FileToolTests/ -> Tests/
            .deletingLastPathComponent()  // Tests/ -> package root
    }
}

/// Parses `<!-- doc-snippet source="..." -->` blocks out of a README and
/// checks each fenced code block against the source file it cites.
enum ReadmeSnippets {
    /// One `<!-- doc-snippet -->` block: the fenced code it wraps, and the
    /// source-file path (relative to the package root) it claims to excerpt.
    struct Snippet {
        let sourcePath: String
        let code: String
    }

    /// Extracts every well-formed `doc-snippet` block from `readme`, in
    /// document order.
    ///
    /// A block is: a `<!-- doc-snippet source="PATH" -->` line, a fenced code
    /// block (` ``` ` … ` ``` `), then a `<!-- /doc-snippet -->` line.
    /// Malformed blocks (a marker with no following fence) are skipped.
    static func parse(_ readme: String) throws -> [Snippet] {
        let lines = readme.components(separatedBy: "\n")
        var snippets: [Snippet] = []
        var index = 0

        while index < lines.count {
            guard let sourcePath = sourcePath(fromMarkerLine: lines[index]) else {
                index += 1
                continue
            }
            index += 1  // past the marker line
            guard index < lines.count, lines[index].hasPrefix("```") else {
                index += 1
                continue
            }
            index += 1  // past the opening fence

            var codeLines: [String] = []
            while index < lines.count, !lines[index].hasPrefix("```") {
                codeLines.append(lines[index])
                index += 1
            }
            index += 1  // past the closing fence

            snippets.append(Snippet(sourcePath: sourcePath, code: codeLines.joined(separator: "\n")))
        }
        return snippets
    }

    /// The `source="..."` value from a `<!-- doc-snippet source="..." -->`
    /// line, or `nil` if `line` isn't one.
    private static func sourcePath(fromMarkerLine line: String) -> String? {
        let prefix = "<!-- doc-snippet source=\""
        guard line.hasPrefix(prefix), let closingQuote = line.range(of: "\" -->") else { return nil }
        let start = line.index(line.startIndex, offsetBy: prefix.count)
        return String(line[start..<closingQuote.lowerBound])
    }

    /// Whether `snippet`'s lines, each trimmed of leading/trailing whitespace,
    /// appear as a contiguous, in-order run somewhere in `sourceLines` (also
    /// trimmed).
    ///
    /// Comparing trimmed lines — rather than requiring byte-identical text —
    /// lets the README re-indent a snippet for readability (dedenting code
    /// excerpted from inside a function) while still requiring it to be a
    /// genuine, ordered, contiguous excerpt of the real file, not lines
    /// cherry-picked from unrelated places or invented outright.
    static func isContiguousExcerpt(_ snippet: String, of sourceLines: [String]) -> Bool {
        let needle = snippet.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let haystack = sourceLines.map { $0.trimmingCharacters(in: .whitespaces) }
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }

        for start in 0...(haystack.count - needle.count) where Array(haystack[start..<(start + needle.count)]) == needle {
            return true
        }
        return false
    }
}
