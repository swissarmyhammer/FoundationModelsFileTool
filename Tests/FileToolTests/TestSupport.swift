import Foundation
import FoundationModels

/// Shared scaffolding for the `FileTool` test target.
///
/// Consolidates helpers that would otherwise be copy-pasted across individual
/// suites so a single implementation governs the behavior every suite depends
/// on. Each suite calls into this namespace with its own arguments rather than
/// carrying its own near-identical copy.
enum TestSupport {
    /// Create a fresh, empty temporary directory and return its URL.
    ///
    /// The directory is created under the process temporary directory with a
    /// unique name so concurrent tests never collide; the operating system
    /// reclaims the temporary tree regardless of per-test cleanup. The `named`
    /// prefix makes the directory identifiable on disk as belonging to a
    /// particular suite.
    ///
    /// - Parameter named: a human-readable prefix, typically the calling
    ///   suite's name, prepended to the unique directory name.
    /// - Returns: the URL of the freshly created temporary directory.
    static func makeTemporaryDirectory(named name: String) -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// Whether `candidate` resolves to a path *contained within* `root` — the
    /// root itself, or a genuine descendant of it — rather than merely sharing
    /// the root's string prefix.
    ///
    /// Both URLs are standardized (collapsing `.` / `..` components) before
    /// comparison. The trailing path separator on the prefix test is what
    /// rejects a *sibling* that shares the root's prefix: for root `/tmp/test`,
    /// `/tmp/test/a` is contained but `/tmp/test-evil` is not — a bare
    /// `hasPrefix(root)` would wrongly admit the latter. The path-containment
    /// scanners (`DocCCoverageScanner`, `ReadmeSnippets`) route their root guard
    /// through here so the check lives in one place.
    ///
    /// - Parameters:
    ///   - candidate: the path to test for containment.
    ///   - root: the directory `candidate` must stay within.
    /// - Returns: `true` iff `candidate` is `root` or a descendant of it.
    static func path(candidate: URL, isContainedBy root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let candidatePath = candidate.standardizedFileURL.path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }

    /// The absolute path of `name` directly under `root`, without creating it.
    ///
    /// - Parameters:
    ///   - name: the file name within `root`.
    ///   - root: the directory to resolve `name` against.
    /// - Returns: the resolved absolute path.
    static func path(_ name: String, in root: URL) -> String {
        root.appendingPathComponent(name, isDirectory: false).path
    }

    /// The POSIX permission bits (`mode & 0o777`) of a path.
    ///
    /// - Parameter path: the absolute path to inspect.
    /// - Returns: the permission bits, or `nil` when the attributes are unreadable.
    static func permissionBits(_ path: String) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int) ?? nil
    }

    /// The names of directory entries whose name marks them as a leftover temporary file.
    ///
    /// Scans `directory` for entries whose name contains the `.tmp.` infix
    /// ``AtomicWriter`` uses, so a test can assert an atomic write or a staged
    /// multi-file commit left nothing behind on a failure.
    ///
    /// - Parameter directory: the directory URL to scan.
    /// - Returns: the names of any temporary-file leftovers.
    static func temporaryFileLeftovers(in directory: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.contains(".tmp.") }
    }

    /// Build a `GeneratedContent` payload from ordered key/value entries.
    ///
    /// - Parameter entries: the payload's properties, in order; a later
    ///   duplicate key wins.
    /// - Returns: the assembled structure payload.
    static func payload(_ entries: [(String, any ConvertibleToGeneratedContent)]) -> GeneratedContent {
        GeneratedContent(properties: entries, uniquingKeysWith: { _, new in new })
    }
}
