import Foundation
import Testing

@testable import FileTool

/// Behavioral tests for the ``PathGuard`` validation stack and ``FileContext``.
///
/// This is a Swift port of the Rust `swissarmyhammer-tools`
/// `shared_utils` path-validation stack (`FilePathValidator::validate_path`,
/// `validate_file_path`, `reject_filesystem_root`, `check_file_permissions`,
/// `ensure_workspace_boundary`). The tables below mirror the Rust integration
/// suite's `DANGEROUS_PATHS` traversal exemplars, its symlink / workspace-
/// boundary security tests, and the `check_file_permissions` unit expectations,
/// so the Swift port rejects and accepts the same inputs the Rust `files` tool
/// does — this is security-sensitive code and the parity is the point.
@Suite struct PathGuardTests {
    // MARK: Temp-directory helpers

    /// The unique final directory-name component of a temporary directory.
    ///
    /// macOS routes the temp directory through the `/var` -> `/private/var`
    /// symlink, so a resolved absolute path cannot be compared by prefix against
    /// a raw temp URL. The unique UUID-bearing directory name, however, appears
    /// in the resolved path only when resolution was anchored at that session
    /// root — so asserting the resolved path contains it proves resolution went
    /// through the session root rather than the process current directory.
    private static func uniqueName(_ url: URL) -> String {
        url.lastPathComponent
    }

    // MARK: Traversal exemplars

    /// Every `../`-style traversal exemplar from the Rust `DANGEROUS_PATHS`
    /// table is rejected as a blocked pattern, on every operation.
    private static let traversalExemplars: [String] = [
        "/tmp/../../../etc/passwd",
        "/tmp/../../etc/passwd",
        "/home/user/../../../etc/passwd",
        "../../../etc/passwd",
        "..\\..\\..\\windows\\system32\\config\\sam",
        "/var/tmp/../../../../etc/shadow",
        "~/../../etc/hosts",
        "/usr/local/../../../root/.ssh/id_rsa",
        "/tmp/../../../../../proc/version",
    ]

    @Test(arguments: traversalExemplars, [FileOperation.read, .write, .edit, .directory])
    func rejectsTraversalExemplarOnEveryOperation(path: String, operation: FileOperation) {
        let guardUnderTest = PathGuard(root: URL(fileURLWithPath: "/tmp"))
        let result = guardUnderTest.validate(path, for: operation)
        #expect(throws: PathViolation.self) { try result.get() }
        if case .failure(let violation) = result {
            #expect(
                violation.message.contains("blocked pattern"),
                "traversal exemplar \(path) should be rejected as a blocked pattern, got: \(violation.message)"
            )
        }
    }

    // MARK: Length / null / control rejects

    @Test func rejectsPathLongerThanMaximum() {
        let guardUnderTest = PathGuard(root: URL(fileURLWithPath: "/tmp"))
        let overlyLong = String(repeating: "a", count: 5000)
        let result = guardUnderTest.validatePath(overlyLong)
        #expect(throws: PathViolation.self) { try result.get() }
        if case .failure(let violation) = result {
            #expect(violation.message.lowercased().contains("too long"))
        }
    }

    @Test func rejectsEmptyAndWhitespacePath() {
        let guardUnderTest = PathGuard(root: URL(fileURLWithPath: "/tmp"))
        #expect(throws: PathViolation.self) { try guardUnderTest.validatePath("").get() }
        #expect(throws: PathViolation.self) { try guardUnderTest.validatePath("   ").get() }
        // Rust's `str::trim` covers the full Unicode whitespace set, including
        // newlines, so a newline-only path is empty and must be rejected too.
        #expect(throws: PathViolation.self) { try guardUnderTest.validatePath("\n").get() }
    }

    @Test func rejectsResolvedPathExceedingMaximumLength() {
        // A short relative input that resolves under a very long session root
        // can exceed the maximum length even though the raw input does not; the
        // resolved path is re-checked, matching Rust's nested length check.
        let longRoot = "/" + String(repeating: "a", count: 5000)
        let guardUnderTest = PathGuard(root: URL(fileURLWithPath: longRoot))
        let result = guardUnderTest.validatePath("file.txt")
        #expect(throws: PathViolation.self) { try result.get() }
        if case .failure(let violation) = result {
            #expect(violation.message.lowercased().contains("too long"))
        }
    }

    @Test func rejectsNullByte() {
        let guardUnderTest = PathGuard(root: URL(fileURLWithPath: "/tmp"))
        let result = guardUnderTest.validatePath("/tmp/foo\u{0}bar")
        #expect(throws: PathViolation.self) { try result.get() }
    }

    @Test func rejectsControlCharacter() {
        // A control character other than tab / newline / carriage return is
        // rejected. The parent (the temp dir) exists so validation reaches the
        // control-character gate rather than failing on a missing parent first.
        let directory = TestSupport.makeTemporaryDirectory(named: "PathGuardTests")
        let guardUnderTest = PathGuard(root: directory)
        let result = guardUnderTest.validatePath(directory.path + "/foo\u{07}bar")
        #expect(throws: PathViolation.self) { try result.get() }
        if case .failure(let violation) = result {
            #expect(violation.message.lowercased().contains("control"))
        }
    }

    // MARK: Session-root (never CWD) relative resolution

    @Test func resolvesRelativePathAgainstSessionRootNotProcessDirectory() throws {
        let sessionRoot = TestSupport.makeTemporaryDirectory(named: "PathGuardTests")
        let file = sessionRoot.appendingPathComponent("relative.txt")
        try "content".write(to: file, atomically: true, encoding: .utf8)

        let guardUnderTest = PathGuard(root: sessionRoot)
        let resolved = try guardUnderTest.validatePath("relative.txt").get()

        // The relative path must resolve under the session root, never the
        // process current directory (which does not contain relative.txt).
        #expect(resolved.path.contains(Self.uniqueName(sessionRoot)))
        #expect(resolved.lastPathComponent == "relative.txt")
    }

    @Test func resolvesNestedRelativePathAgainstSessionRoot() throws {
        let sessionRoot = TestSupport.makeTemporaryDirectory(named: "PathGuardTests")
        let nested = sessionRoot.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try "content".write(to: nested.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)

        let guardUnderTest = PathGuard(root: sessionRoot)
        let resolved = try guardUnderTest.validatePath("nested/file.txt").get()
        #expect(resolved.path.contains(Self.uniqueName(sessionRoot)))
        #expect(resolved.path.hasSuffix("/nested/file.txt"))
    }

    // MARK: Symlink handling

    @Test func rejectsSymlinkBeforeCanonicalizationByDefault() throws {
        // The symlink target does NOT exist: canonicalization would fail, so a
        // rejection here proves the symlink is refused BEFORE canonicalization.
        let directory = TestSupport.makeTemporaryDirectory(named: "PathGuardTests")
        let link = directory.appendingPathComponent("dangling.txt")
        let target = directory.appendingPathComponent("does-not-exist.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let guardUnderTest = PathGuard(root: directory)
        let result = guardUnderTest.validatePath(link.path)
        #expect(throws: PathViolation.self) { try result.get() }
        if case .failure(let violation) = result {
            #expect(violation.message.lowercased().contains("symlink"))
        }
    }

    @Test func acceptsSymlinkWhenOptedIn() throws {
        let directory = TestSupport.makeTemporaryDirectory(named: "PathGuardTests")
        let target = directory.appendingPathComponent("target.txt")
        try "content".write(to: target, atomically: true, encoding: .utf8)
        let link = directory.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let guardUnderTest = PathGuard(root: directory, allowSymlinks: true)
        let resolved = try guardUnderTest.validatePath(link.path).get()
        // The opt-in path resolves the symlink to its real target.
        #expect(resolved.lastPathComponent == "target.txt")
    }

    @Test func rejectsDanglingSymlinkEvenWhenSymlinksAllowed() throws {
        // Even with symlinks opted in, a symlink whose target does not exist
        // must be rejected: it cannot be resolved, so it cannot be confined to
        // the workspace, and a later write would follow it to create a file at
        // its (out-of-workspace) target. This mirrors Rust's
        // `resolve_symlink_securely`, which re-canonicalizes and fails on a
        // dangling link. The symlink lives inside the workspace, so only this
        // re-resolution step — not the boundary check — can catch it.
        let workspace = TestSupport.makeTemporaryDirectory(named: "PathGuardTests")
        let link = workspace.appendingPathComponent("dangling.txt")
        let target = workspace.appendingPathComponent("nowhere/evil.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let guardUnderTest = PathGuard(root: workspace, workspaceRoot: workspace, allowSymlinks: true)
        let result = guardUnderTest.validatePath(link.path)
        #expect(throws: PathViolation.self) { try result.get() }
        if case .failure(let violation) = result {
            #expect(violation.message.lowercased().contains("symlink"))
        }
    }

    // MARK: Workspace-boundary enforcement

    @Test func acceptsNonexistentTargetInsideWorkspace() throws {
        let workspace = TestSupport.makeTemporaryDirectory(named: "PathGuardTests")
        let guardUnderTest = PathGuard(root: workspace, workspaceRoot: workspace)
        // A not-yet-created write target directly under the workspace passes.
        let target = workspace.appendingPathComponent("new-file.txt")
        let resolved = try guardUnderTest.validatePath(target.path).get()
        #expect(resolved.lastPathComponent == "new-file.txt")
    }

    @Test func acceptsNonexistentTargetViaDeepestExistingParentInsideWorkspace() throws {
        let workspace = TestSupport.makeTemporaryDirectory(named: "PathGuardTests")
        // The subdirectory exists but the target file does not, so the boundary
        // check reconstructs the target from its deepest existing parent (the
        // subdirectory) and confirms the reconstructed path is inside.
        let subdirectory = workspace.appendingPathComponent("subdir", isDirectory: true)
        try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)

        let guardUnderTest = PathGuard(root: workspace, workspaceRoot: workspace)
        let target = subdirectory.appendingPathComponent("new-file.txt")
        let resolved = try guardUnderTest.validatePath(target.path).get()
        #expect(resolved.path.hasSuffix("/subdir/new-file.txt"))
    }

    @Test func rejectsExistingTargetOutsideWorkspace() throws {
        let workspace = TestSupport.makeTemporaryDirectory(named: "PathGuardTests")
        let outside = TestSupport.makeTemporaryDirectory(named: "PathGuardTests")
        let outsideFile = outside.appendingPathComponent("secret.txt")
        try "secret".write(to: outsideFile, atomically: true, encoding: .utf8)

        let guardUnderTest = PathGuard(root: workspace, workspaceRoot: workspace)
        let result = guardUnderTest.validatePath(outsideFile.path)
        #expect(throws: PathViolation.self) { try result.get() }
        if case .failure(let violation) = result {
            #expect(violation.message.lowercased().contains("outside workspace"))
        }
    }

    @Test func rejectsNonexistentTargetOutsideWorkspaceViaDeepestExistingParent() throws {
        let workspace = TestSupport.makeTemporaryDirectory(named: "PathGuardTests")
        let outside = TestSupport.makeTemporaryDirectory(named: "PathGuardTests")
        // The subdirectory exists but the target file does not, so the boundary
        // check reconstructs the target from its deepest existing parent (the
        // outside subdirectory) and rejects it for being outside the workspace.
        let subdirectory = outside.appendingPathComponent("subdir", isDirectory: true)
        try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)

        let guardUnderTest = PathGuard(root: workspace, workspaceRoot: workspace)
        let target = subdirectory.appendingPathComponent("new-file.txt")
        let result = guardUnderTest.validatePath(target.path)
        #expect(throws: PathViolation.self) { try result.get() }
        if case .failure(let violation) = result {
            #expect(violation.message.lowercased().contains("outside workspace"))
        }
    }

    // MARK: Filesystem-root walk refusal

    @Test(arguments: ["/", ".", ""])
    func refusesFilesystemRootAndUnresolvedSearchDirectory(searchDirectory: String) {
        let guardUnderTest = PathGuard(root: URL(fileURLWithPath: "/tmp"))
        let result = guardUnderTest.rejectFilesystemRoot(searchDirectory)
        #expect(throws: PathViolation.self) { try result.get() }
    }

    @Test func acceptsNormalDirectoryAsSearchRoot() {
        let directory = TestSupport.makeTemporaryDirectory(named: "PathGuardTests")
        let guardUnderTest = PathGuard(root: directory)
        let result = guardUnderTest.rejectFilesystemRoot(directory.path)
        #expect((try? result.get()) != nil)
    }

    // MARK: Per-operation permission checks

    @Test func rejectsReadOfDirectoryAsNonRegularFile() {
        let directory = TestSupport.makeTemporaryDirectory(named: "PathGuardTests")
        let guardUnderTest = PathGuard(root: directory)
        let result = guardUnderTest.checkPermission(directory, for: .read)
        #expect(throws: PathViolation.self) { try result.get() }
        if case .failure(let violation) = result {
            #expect(violation.message.lowercased().contains("regular file"))
        }
    }

    @Test func rejectsReadOfUnreadableFile() throws {
        let directory = TestSupport.makeTemporaryDirectory(named: "PathGuardTests")
        let file = directory.appendingPathComponent("noread.txt")
        try "content".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }

        let guardUnderTest = PathGuard(root: directory)
        let result = guardUnderTest.checkPermission(file, for: .read)
        #expect(throws: PathViolation.self) { try result.get() }
        if case .failure(let violation) = result {
            #expect(violation.message.lowercased().contains("readable"))
        }
    }

    @Test func rejectsWriteOfReadonlyFile() throws {
        let directory = TestSupport.makeTemporaryDirectory(named: "PathGuardTests")
        let file = directory.appendingPathComponent("readonly.txt")
        try "content".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }

        let guardUnderTest = PathGuard(root: directory)
        let result = guardUnderTest.checkPermission(file, for: .write)
        #expect(throws: PathViolation.self) { try result.get() }
        if case .failure(let violation) = result {
            #expect(violation.message.lowercased().contains("read-only"))
        }
    }

    @Test func rejectsWriteWithMissingParentDirectory() {
        let directory = TestSupport.makeTemporaryDirectory(named: "PathGuardTests")
        let guardUnderTest = PathGuard(root: directory)
        let target = directory.appendingPathComponent("missing-parent/file.txt")
        let result = guardUnderTest.checkPermission(target, for: .write)
        #expect(throws: PathViolation.self) { try result.get() }
        if case .failure(let violation) = result {
            #expect(violation.message.lowercased().contains("parent directory does not exist"))
        }
    }

    @Test func rejectsEditOfNonexistentFile() {
        let directory = TestSupport.makeTemporaryDirectory(named: "PathGuardTests")
        let guardUnderTest = PathGuard(root: directory)
        let target = directory.appendingPathComponent("nope.txt")
        let result = guardUnderTest.checkPermission(target, for: .edit)
        #expect(throws: PathViolation.self) { try result.get() }
        if case .failure(let violation) = result {
            #expect(violation.message.lowercased().contains("non-existent"))
        }
    }

    @Test func rejectsEditOfReadonlyFile() throws {
        let directory = TestSupport.makeTemporaryDirectory(named: "PathGuardTests")
        let file = directory.appendingPathComponent("readonly.txt")
        try "content".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }

        let guardUnderTest = PathGuard(root: directory)
        let result = guardUnderTest.checkPermission(file, for: .edit)
        #expect(throws: PathViolation.self) { try result.get() }
        if case .failure(let violation) = result {
            #expect(violation.message.lowercased().contains("read-only"))
        }
    }

    // MARK: Delete permission checks

    @Test func acceptsDeleteOfExistingRegularFileInWritableDirectory() throws {
        let directory = TestSupport.makeTemporaryDirectory(named: "PathGuardTests")
        let file = directory.appendingPathComponent("victim.txt")
        try "content".write(to: file, atomically: true, encoding: .utf8)

        let guardUnderTest = PathGuard(root: directory)
        let resolved = try guardUnderTest.validate(file.path, for: .delete).get()
        #expect(resolved.lastPathComponent == "victim.txt")
    }

    @Test func rejectsDeleteOfNonexistentFile() {
        let directory = TestSupport.makeTemporaryDirectory(named: "PathGuardTests")
        let guardUnderTest = PathGuard(root: directory)
        let target = directory.appendingPathComponent("nope.txt")
        let result = guardUnderTest.checkPermission(target, for: .delete)
        #expect(throws: PathViolation.self) { try result.get() }
        if case .failure(let violation) = result {
            #expect(violation.message.lowercased().contains("non-existent"))
        }
    }

    @Test func rejectsDeleteOfDirectory() {
        let directory = TestSupport.makeTemporaryDirectory(named: "PathGuardTests")
        let guardUnderTest = PathGuard(root: directory)
        let result = guardUnderTest.checkPermission(directory, for: .delete)
        #expect(throws: PathViolation.self) { try result.get() }
        if case .failure(let violation) = result {
            #expect(violation.message.lowercased().contains("regular file"))
        }
    }

    @Test func rejectsDeleteWhenParentDirectoryIsNotWritable() throws {
        let directory = TestSupport.makeTemporaryDirectory(named: "PathGuardTests")
        let file = directory.appendingPathComponent("locked.txt")
        try "content".write(to: file, atomically: true, encoding: .utf8)
        // POSIX deletion permission lives on the parent directory, so removing
        // its write bits must reject the delete even though the file itself is
        // writable. Restore the write bits in teardown so the OS can reclaim it.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path) }

        let guardUnderTest = PathGuard(root: directory)
        let result = guardUnderTest.checkPermission(file, for: .delete)
        #expect(throws: PathViolation.self) { try result.get() }
        if case .failure(let violation) = result {
            #expect(violation.message.lowercased().contains("parent directory is not writable"))
        }
    }

    @Test(arguments: [FileOperation.read, .write, .edit])
    func acceptsWritableRegularFileForEveryOperation(operation: FileOperation) throws {
        let directory = TestSupport.makeTemporaryDirectory(named: "PathGuardTests")
        let file = directory.appendingPathComponent("ok.txt")
        try "content".write(to: file, atomically: true, encoding: .utf8)

        let guardUnderTest = PathGuard(root: directory)
        let resolved = try guardUnderTest.validate(file.path, for: operation).get()
        #expect(resolved.lastPathComponent == "ok.txt")
    }

    // MARK: FileContext

    @Test func fileContextExposesRootGuardAndReadOnlyFlag() {
        let root = TestSupport.makeTemporaryDirectory(named: "PathGuardTests")
        let context = FileContext(root: root, readOnly: true)
        #expect(context.root == root)
        #expect(context.readOnly)
        // The context's guard enforces the session root as the workspace boundary.
        #expect(context.pathGuard.workspaceRoot == root)
    }

    @Test func fileContextDefaultsToReadWrite() {
        let context = FileContext(root: TestSupport.makeTemporaryDirectory(named: "PathGuardTests"))
        #expect(!context.readOnly)
    }
}
