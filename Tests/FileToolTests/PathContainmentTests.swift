import Foundation
import Testing

/// Pins the containment contract of `TestSupport.path(candidate:isContainedBy:)`, the
/// single guard the doc-snippet and DocC-coverage scanners route their
/// package-root check through.
///
/// The `sibling*` cases are the defensive point of the helper: a bare
/// `hasPrefix(root)` admits a sibling directory that merely shares the root's
/// string prefix, which is the path-traversal weakness this guard closes.
@Suite("Package-root path containment")
struct PathContainmentTests {
    private let root = URL(fileURLWithPath: "/tmp/test", isDirectory: true)

    @Test("the root itself is contained")
    func rootItselfIsContained() {
        #expect(TestSupport.path(candidate: root, isContainedBy: root))
    }

    @Test("a descendant of the root is contained")
    func descendantIsContained() {
        let descendant = root.appendingPathComponent("Sources/FileTool/File.swift")
        #expect(TestSupport.path(candidate: descendant, isContainedBy: root))
    }

    @Test("a sibling directory sharing the root's string prefix is not contained")
    func siblingSharingPrefixIsNotContained() {
        let sibling = URL(fileURLWithPath: "/tmp/test-evil/file.swift")
        #expect(!TestSupport.path(candidate: sibling, isContainedBy: root))
    }

    @Test("a path escaping the root via `..` is not contained")
    func parentEscapeIsNotContained() {
        let escape = root.appendingPathComponent("../etc/passwd")
        #expect(!TestSupport.path(candidate: escape, isContainedBy: root))
    }
}
