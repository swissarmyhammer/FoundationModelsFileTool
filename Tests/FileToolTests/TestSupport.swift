import Foundation

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
}
