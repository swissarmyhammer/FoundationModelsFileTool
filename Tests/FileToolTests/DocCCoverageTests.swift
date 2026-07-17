import Foundation
import Testing

/// Enforces plan.md task 12's "DocC comments on all public API in
/// `Sources/FileTool/`" acceptance criterion: every declaration carrying the
/// `public` keyword in the library sources has a `///` doc comment directly
/// attached to it — the codebase's own established convention.
///
/// This mirrors the sibling `FoundationModelsOperationTool`'s
/// `Tests/OperationsTests/DocCoverageTests.swift`, re-implemented here with a
/// self-contained line-based scanner rather than SwiftSyntax so it needs no
/// `swift-syntax` / `TestSupport` package dependency. The scanner recognizes
/// `public`-keyword declarations (types, methods, properties, initializers);
/// `public enum` *cases*, which carry no keyword of their own, are verified by
/// review (`EditEngine.Resolution` / `BatchOutcome`, `DiagnosticsBridge.Mode`,
/// `ScriptModeError`).
///
/// The scanner's own detection logic is pinned by `scannerFlags*` synthetic
/// fixtures; `librarySourceIsFullyDocumented` is the integration check against
/// the real source tree.
@Suite("Public API doc coverage")
struct DocCCoverageTests {
    @Test("every public declaration in Sources/FileTool has an attached doc comment")
    func librarySourceIsFullyDocumented() throws {
        let violations = try DocCCoverageScanner.scan(directory: "Sources/FileTool", root: packageRoot())
        #expect(violations.isEmpty, Comment(rawValue: "\n" + violations.map(\.description).joined(separator: "\n")))
    }

    @Test("the scanner flags a public declaration with no attached doc comment")
    func scannerFlagsUndocumentedPublicDeclaration() {
        let source = """
            public struct Undocumented {
                public let value: Int
            }
            """
        let violations = DocCCoverageScanner.violations(in: source, filePath: "Fixture.swift")
        #expect(violations.count == 2)
    }

    @Test("the scanner accepts a documented public declaration, past attributes and blank lines")
    func scannerAcceptsDocumentedPublicDeclaration() {
        let source = """
            /// A documented type.
            public struct Documented {
                /// A documented property.
                public let value: Int

                /// A documented, attributed method.
                @discardableResult
                public func f() -> Int { value }
            }
            """
        let violations = DocCCoverageScanner.violations(in: source, filePath: "Fixture.swift")
        #expect(violations.isEmpty, Comment(rawValue: violations.map(\.description).joined(separator: "\n")))
    }

    @Test("scanning a directory that escapes the package root throws")
    func scanningOutsideThePackageRootThrows() {
        #expect(throws: (any Error).self) {
            _ = try DocCCoverageScanner.scan(directory: "../../../../../../etc", root: packageRoot())
        }
    }

    @Test("scanning a sibling directory that merely shares the root's path prefix throws")
    func scanningSiblingSharingRootPrefixThrows() throws {
        let base = TestSupport.makeTemporaryDirectory(named: "DocCCoverageContainment")
        let root = base.appendingPathComponent("pkg", isDirectory: true)
        let sibling = base.appendingPathComponent("pkg-evil", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        #expect(throws: (any Error).self) {
            _ = try DocCCoverageScanner.scan(directory: "../pkg-evil", root: root)
        }
    }

    /// The package root directory, derived from this file's own path: three
    /// levels up from `Tests/FileToolTests/DocCCoverageTests.swift`.
    private func packageRoot(thisFile: String = #filePath) -> URL {
        URL(fileURLWithPath: thisFile)
            .deletingLastPathComponent()  // DocCCoverageTests.swift -> FileToolTests/
            .deletingLastPathComponent()  // FileToolTests/ -> Tests/
            .deletingLastPathComponent()  // Tests/ -> package root
    }
}

/// Scans Swift source for `public`-keyword declarations that have no `///` doc
/// comment directly attached — separated from the declaration (or its leading
/// `@attributes`) by nothing but blank lines and ordinary `//` comments.
enum DocCCoverageScanner {
    /// One undocumented public declaration: where it is, and the source line.
    struct Violation: CustomStringConvertible, Equatable {
        /// The source file's path, relative to the package root.
        let filePath: String

        /// The declaration's 1-based line number.
        let line: Int

        /// The trimmed source line declaring the public API.
        let text: String

        var description: String {
            "\(filePath):\(line): public declaration has no attached `///` doc comment: \(text)"
        }
    }

    /// Recursively scans every `.swift` file under `directory` for undocumented
    /// `public` declarations.
    ///
    /// - Parameters:
    ///   - directory: the directory to scan, relative to `root`.
    ///   - root: the package root the resolved directory must stay within.
    /// - Returns: every violation found, in file-then-line order.
    /// - Throws: an error if `directory` escapes `root`, or a file cannot be read.
    static func scan(directory: String, root: URL) throws -> [Violation] {
        let directoryURL = root.appendingPathComponent(directory).standardizedFileURL
        guard TestSupport.path(directoryURL, isContainedBy: root) else {
            throw ScanError.pathEscapesPackageRoot(directory)
        }
        let enumerator = FileManager.default.enumerator(at: directoryURL, includingPropertiesForKeys: nil)
        let files = (enumerator?.allObjects as? [URL] ?? [])
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.path < $1.path }

        var allViolations: [Violation] = []
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            let relativePath = file.path.replacingOccurrences(of: root.standardizedFileURL.path + "/", with: "")
            allViolations.append(contentsOf: violations(in: source, filePath: relativePath))
        }
        return allViolations
    }

    /// Returns every undocumented `public` declaration in `source`.
    ///
    /// A `///` or `/**` doc line, a blank line, an ordinary `//` comment, and an
    /// `@attribute` line all preserve a pending doc comment; any other line
    /// resets it. A `public`-keyword line reached with no pending doc comment is
    /// a violation.
    static func violations(in source: String, filePath: String) -> [Violation] {
        var results: [Violation] = []
        var hasPendingDoc = false
        for (index, rawLine) in source.components(separatedBy: "\n").enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("///") || line.hasPrefix("/**") {
                hasPendingDoc = true
                continue
            }
            if line.isEmpty || line.hasPrefix("//") || line.hasPrefix("@") {
                continue
            }
            if declaresPublicAPI(line), !hasPendingDoc {
                results.append(Violation(filePath: filePath, line: index + 1, text: line))
            }
            hasPendingDoc = false
        }
        return results
    }

    /// Whether `line` declares public API: it carries the `public` keyword as a
    /// standalone word (a declaration modifier), not merely as a substring.
    private static func declaresPublicAPI(_ line: String) -> Bool {
        let tokens = line.split { !($0.isLetter || $0.isNumber || $0 == "_") }
        return tokens.contains("public")
    }

    /// An error scanning a directory.
    enum ScanError: Error, CustomStringConvertible {
        /// `directory` resolved to a path outside the package root.
        case pathEscapesPackageRoot(String)

        var description: String {
            switch self {
            case .pathEscapesPackageRoot(let path):
                return "'\(path)' resolves outside the package root"
            }
        }
    }
}
