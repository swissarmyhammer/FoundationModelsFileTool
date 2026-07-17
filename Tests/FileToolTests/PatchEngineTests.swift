import Darwin
import Foundation
import Testing

@testable import FileTool

/// Behavioral tests for the ``PatchEngine`` two-phase multi-file patch applier.
///
/// Each acceptance criterion from the PatchEngine card is exercised through the
/// real engine against files in a fresh temporary directory, following the
/// `EditFileTests` temp-dir fixture pattern: a combined add+update+delete+move
/// patch landing all four in one call; an unresolved update aborting the whole
/// patch byte-identical; the phase-1 correctives (add-onto-existing, delete of a
/// missing file, a binary update target); per-file encoding/line-ending
/// preservation; a phase-2 stage failure leaving every destination untouched
/// with no temporary files behind; a pure rename moving byte-identical content;
/// and the cross-file conflict rules (move-destination collisions and same-final-path
/// duplicates abort, while legal swaps and rotations are allowed).
@Suite struct PatchEngineTests {
    // MARK: Fixture

    /// A fresh temporary directory and a guard rooted at it.
    ///
    /// - Returns: the temporary root URL and a ``PathGuard`` bounded to it.
    private static func makeFixture() -> (root: URL, pathGuard: PathGuard) {
        let root = TestSupport.makeTemporaryDirectory(named: "PatchEngineTests")
        return (root, PathGuard(root: root, workspaceRoot: root))
    }

    /// Seed a file with `data` at `name` inside `root`.
    ///
    /// - Parameters:
    ///   - data: the bytes to write.
    ///   - name: the file name within `root`.
    ///   - root: the directory to seed within.
    /// - Returns: the seeded file's absolute path.
    @discardableResult
    private static func seed(_ data: Data, named name: String, in root: URL) throws -> String {
        let url = root.appendingPathComponent(name, isDirectory: false)
        try data.write(to: url)
        return url.path
    }

    /// The raw on-disk bytes of a file, or `nil` when it does not exist.
    private static func bytes(_ path: String) -> Data? {
        try? Data(contentsOf: URL(fileURLWithPath: path))
    }

    /// Whether a file exists on disk.
    private static func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    /// Set or clear the user-immutable (`UF_IMMUTABLE`) flag on a file.
    ///
    /// Locking a file immutable makes a later `removeItem` fail with `EPERM`
    /// while leaving its mode bits — and its parent directory's writability —
    /// untouched, so the ``PathGuard`` `.delete`/`.edit` checks still pass in
    /// phase 1. That is how a phase-2 *unlink* failure is provoked without a
    /// phase-1 rejection. The owner may toggle the user flag without root.
    ///
    /// - Parameters:
    ///   - path: the file to lock or unlock.
    ///   - immutable: `true` to lock, `false` to unlock.
    /// - Returns: `true` when the flag change succeeded.
    @discardableResult
    private static func setImmutable(_ path: String, _ immutable: Bool) -> Bool {
        chflags(path, immutable ? UInt32(UF_IMMUTABLE) : 0) == 0
    }

    /// The outcome whose reported path ends with `suffix`.
    ///
    /// - Parameters:
    ///   - outcomes: the outcomes to search.
    ///   - suffix: the path suffix identifying the wanted outcome.
    /// - Returns: the first matching outcome, or `nil` when none matches.
    private static func outcome(
        in outcomes: [PatchEngine.FileOutcome],
        endingWith suffix: String
    ) -> PatchEngine.FileOutcome? {
        outcomes.first { $0.path.hasSuffix(suffix) }
    }

    // MARK: Combined patch

    @Test func combinedPatchAppliesAddUpdateDeleteAndMove() throws {
        let (root, pathGuard) = Self.makeFixture()
        try Self.seed(Data("one\ntwo\nthree\n".utf8), named: "update.txt", in: root)
        try Self.seed(Data("obsolete\n".utf8), named: "delete.txt", in: root)
        try Self.seed(Data("keep me\n".utf8), named: "source.txt", in: root)

        let hunks: [PatchParser.Hunk] = [
            .addFile(path: TestSupport.path("added.txt", in: root), contents: "added\n"),
            .updateFile(path: TestSupport.path("update.txt", in: root), movePath: nil, pairs: [(find: "two", replace: "TWO")]),
            .deleteFile(path: TestSupport.path("delete.txt", in: root)),
            .updateFile(path: TestSupport.path("source.txt", in: root), movePath: TestSupport.path("dest.txt", in: root), pairs: []),
        ]

        let outcomes = try Self.apply(hunks, using: pathGuard)

        // Add
        #expect(Self.bytes(TestSupport.path("added.txt", in: root)) == Data("added\n".utf8))
        let add = try #require(Self.outcome(in: outcomes, endingWith: "added.txt"))
        #expect(add.action == .added)
        #expect(add.appliedPairs == 0)
        #expect(add.bytesWritten == Data("added\n".utf8).count)
        #expect(add.hash == Hashline.wholeFileHash(bytes: Data("added\n".utf8)))

        // Update
        #expect(Self.bytes(TestSupport.path("update.txt", in: root)) == Data("one\nTWO\nthree\n".utf8))
        let update = try #require(Self.outcome(in: outcomes, endingWith: "update.txt"))
        #expect(update.action == .modified)
        #expect(update.appliedPairs == 1)
        #expect(update.hash == Hashline.wholeFileHash(bytes: Data("one\nTWO\nthree\n".utf8)))

        // Delete
        #expect(!Self.exists(TestSupport.path("delete.txt", in: root)))
        let delete = try #require(Self.outcome(in: outcomes, endingWith: "delete.txt"))
        #expect(delete.action == .deleted)
        #expect(delete.bytesWritten == nil)
        #expect(delete.hash == nil)

        // Move
        #expect(!Self.exists(TestSupport.path("source.txt", in: root)))
        #expect(Self.bytes(TestSupport.path("dest.txt", in: root)) == Data("keep me\n".utf8))
        let move = try #require(Self.outcome(in: outcomes, endingWith: "source.txt"))
        #expect(move.action == .moved)
        #expect(move.movedTo?.hasSuffix("dest.txt") == true)
        #expect(move.hash == Hashline.wholeFileHash(bytes: Data("keep me\n".utf8)))

        #expect(TestSupport.temporaryFileLeftovers(in: root).isEmpty)
    }

    // MARK: Abort-all on an unresolved update

    @Test func unresolvedUpdateAbortsEntirePatchLeavingFilesByteIdentical() throws {
        let (root, pathGuard) = Self.makeFixture()
        let updateBytes = Data("alpha\nbeta\n".utf8)
        let editBytes = Data("gamma\ndelta\n".utf8)
        try Self.seed(updateBytes, named: "will-edit.txt", in: root)
        try Self.seed(editBytes, named: "no-match.txt", in: root)

        let hunks: [PatchParser.Hunk] = [
            .addFile(path: TestSupport.path("new.txt", in: root), contents: "new\n"),
            .updateFile(path: TestSupport.path("will-edit.txt", in: root), movePath: nil, pairs: [(find: "beta", replace: "BETA")]),
            .updateFile(
                path: TestSupport.path("no-match.txt", in: root),
                movePath: nil,
                pairs: [(find: "nowhere-to-be-found", replace: "x")]
            ),
        ]

        let failure = Self.failure(PatchEngine.apply(hunks, using: pathGuard))
        guard case .unresolved(let path, _, let resolution) = failure else {
            Issue.record("expected .unresolved, got \(failure)")
            return
        }
        #expect(path.hasSuffix("no-match.txt"))
        if case .noMatch = resolution {} else { Issue.record("expected .noMatch resolution, got \(resolution)") }

        // Every file byte-identical; nothing added.
        #expect(Self.bytes(TestSupport.path("will-edit.txt", in: root)) == updateBytes)
        #expect(Self.bytes(TestSupport.path("no-match.txt", in: root)) == editBytes)
        #expect(!Self.exists(TestSupport.path("new.txt", in: root)))
        #expect(TestSupport.temporaryFileLeftovers(in: root).isEmpty)
    }

    // MARK: Phase-1 correctives

    @Test func addTargetingExistingFileAborts() throws {
        let (root, pathGuard) = Self.makeFixture()
        let existingBytes = Data("already here\n".utf8)
        try Self.seed(existingBytes, named: "exists.txt", in: root)
        try Self.seed(Data("victim\n".utf8), named: "other.txt", in: root)

        let hunks: [PatchParser.Hunk] = [
            .deleteFile(path: TestSupport.path("other.txt", in: root)),
            .addFile(path: TestSupport.path("exists.txt", in: root), contents: "clobber\n"),
        ]

        let failure = Self.failure(PatchEngine.apply(hunks, using: pathGuard))
        guard case .corrective = failure else {
            Issue.record("expected .corrective, got \(failure)")
            return
        }
        // Nothing was touched: the existing file is intact and the delete did not happen.
        #expect(Self.bytes(TestSupport.path("exists.txt", in: root)) == existingBytes)
        #expect(Self.exists(TestSupport.path("other.txt", in: root)))
    }

    @Test func deleteOfNonexistentFileAborts() throws {
        let (root, pathGuard) = Self.makeFixture()
        let hunks: [PatchParser.Hunk] = [.deleteFile(path: TestSupport.path("ghost.txt", in: root))]
        guard case .corrective = Self.failure(PatchEngine.apply(hunks, using: pathGuard)) else {
            Issue.record("expected .corrective for a missing delete target")
            return
        }
    }

    @Test func binaryUpdateTargetAborts() throws {
        let (root, pathGuard) = Self.makeFixture()
        let binary = Data([0xFF, 0xFE, 0x00, 0x01, 0x80])
        try Self.seed(binary, named: "image.bin", in: root)
        let hunks: [PatchParser.Hunk] = [
            .updateFile(path: TestSupport.path("image.bin", in: root), movePath: nil, pairs: [(find: "a", replace: "b")])
        ]
        guard case .corrective = Self.failure(PatchEngine.apply(hunks, using: pathGuard)) else {
            Issue.record("expected .corrective for a binary update target")
            return
        }
        #expect(Self.bytes(TestSupport.path("image.bin", in: root)) == binary)
    }

    // MARK: Encoding / line-ending preservation

    @Test func updatePreservesEncodingAndLineEndingsPerFile() throws {
        let (root, pathGuard) = Self.makeFixture()
        let byteOrderMark = Data([0xEF, 0xBB, 0xBF])
        let crlfOriginal = byteOrderMark + Data("alpha\r\nbeta\r\ngamma\r\n".utf8)
        let lfOriginal = Data("one\ntwo\nthree\n".utf8)
        try Self.seed(crlfOriginal, named: "crlf.txt", in: root)
        try Self.seed(lfOriginal, named: "lf.txt", in: root)

        let hunks: [PatchParser.Hunk] = [
            .updateFile(path: TestSupport.path("crlf.txt", in: root), movePath: nil, pairs: [(find: "beta", replace: "BETA")]),
            .updateFile(path: TestSupport.path("lf.txt", in: root), movePath: nil, pairs: [(find: "two", replace: "TWO")]),
        ]

        _ = try Self.apply(hunks, using: pathGuard)

        #expect(Self.bytes(TestSupport.path("crlf.txt", in: root)) == byteOrderMark + Data("alpha\r\nBETA\r\ngamma\r\n".utf8))
        #expect(Self.bytes(TestSupport.path("lf.txt", in: root)) == Data("one\nTWO\nthree\n".utf8))
    }

    // MARK: Phase-2 stage failure

    @Test func stageFailureLeavesDestinationsUntouchedAndNoTempFiles() throws {
        let (root, pathGuard) = Self.makeFixture()
        let lockedDirectory = root.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: lockedDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: lockedDirectory.path) }

        let hunks: [PatchParser.Hunk] = [
            .addFile(path: TestSupport.path("a.txt", in: root), contents: "a\n"),
            .addFile(path: TestSupport.path("b.txt", in: root), contents: "b\n"),
            .addFile(path: lockedDirectory.appendingPathComponent("c.txt").path, contents: "c\n"),
        ]

        // The parent directory exists (so the path validates) but is not writable,
        // so staging the third write fails after the first two have staged.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: lockedDirectory.path)

        guard case .corrective = Self.failure(PatchEngine.apply(hunks, using: pathGuard)) else {
            Issue.record("expected .corrective for an unwritable stage target")
            return
        }

        #expect(!Self.exists(TestSupport.path("a.txt", in: root)))
        #expect(!Self.exists(TestSupport.path("b.txt", in: root)))
        #expect(!Self.exists(lockedDirectory.appendingPathComponent("c.txt").path))
        #expect(TestSupport.temporaryFileLeftovers(in: root).isEmpty)
        #expect(TestSupport.temporaryFileLeftovers(in: lockedDirectory).isEmpty)
    }

    // MARK: Phase-2 removal failure

    @Test func deleteWhoseUnlinkFailsAbortsRatherThanReportingAFalseDeletion() throws {
        let (root, pathGuard) = Self.makeFixture()
        let stillHere = Data("still here\n".utf8)
        let doomed = try Self.seed(stillHere, named: "immutable.txt", in: root)

        // Lock the file so `.delete` validation passes in phase 1 (the parent
        // stays writable) but the phase-2 unlink is denied.
        #expect(Self.setImmutable(doomed, true))
        defer { Self.setImmutable(doomed, false) }

        let hunks: [PatchParser.Hunk] = [.deleteFile(path: doomed)]
        guard case .failure(.corrective) = PatchEngine.apply(hunks, using: pathGuard) else {
            Issue.record("expected .corrective when a delete target cannot be unlinked")
            return
        }
        // The unlink failure was surfaced, not swallowed behind a `.deleted`
        // outcome: the file is still on disk and no false success was reported.
        #expect(Self.bytes(doomed) == stillHere)
    }

    @Test func moveWhoseSourceUnlinkFailsAbortsRatherThanReportingAFalseMove() throws {
        let (root, pathGuard) = Self.makeFixture()
        let payload = Data("payload\n".utf8)
        let source = try Self.seed(payload, named: "locked-source.txt", in: root)
        let destination = TestSupport.path("moved-dest.txt", in: root)

        // Lock the source so `.edit` validation and the decode both pass, but
        // the post-commit unlink of the move source is denied.
        #expect(Self.setImmutable(source, true))
        defer { Self.setImmutable(source, false) }

        let hunks: [PatchParser.Hunk] = [
            .updateFile(path: source, movePath: destination, pairs: [])
        ]
        guard case .failure(.corrective) = PatchEngine.apply(hunks, using: pathGuard) else {
            Issue.record("expected .corrective when a move source cannot be unlinked")
            return
        }
        // Removals run after commits, so the destination was written — but the
        // source still exists, so the engine must not have claimed a completed
        // move; it reports the failure instead.
        #expect(Self.bytes(source) == payload)
        #expect(Self.bytes(destination) == payload)
    }

    // MARK: Pure rename

    @Test func pureRenameMovesFileWithByteIdenticalContent() throws {
        let (root, pathGuard) = Self.makeFixture()
        let original = Data([0xEF, 0xBB, 0xBF]) + Data("keep\r\nthese\r\nbytes\r\n".utf8)
        try Self.seed(original, named: "before.txt", in: root)

        let hunks: [PatchParser.Hunk] = [
            .updateFile(path: TestSupport.path("before.txt", in: root), movePath: TestSupport.path("after.txt", in: root), pairs: [])
        ]
        let outcomes = try Self.apply(hunks, using: pathGuard)

        #expect(!Self.exists(TestSupport.path("before.txt", in: root)))
        #expect(Self.bytes(TestSupport.path("after.txt", in: root)) == original)
        let move = try #require(outcomes.first)
        #expect(move.action == .moved)
        #expect(move.appliedPairs == 0)
    }

    // MARK: Cross-file conflicts

    @Test func moveDestinationCollidingWithAddAborts() throws {
        let (root, pathGuard) = Self.makeFixture()
        try Self.seed(Data("payload\n".utf8), named: "src.txt", in: root)

        let hunks: [PatchParser.Hunk] = [
            .updateFile(path: TestSupport.path("src.txt", in: root), movePath: TestSupport.path("collide.txt", in: root), pairs: []),
            .addFile(path: TestSupport.path("collide.txt", in: root), contents: "new\n"),
        ]
        guard case .corrective = Self.failure(PatchEngine.apply(hunks, using: pathGuard)) else {
            Issue.record("expected .corrective for a move-destination/add collision")
            return
        }
        // No write happened: the source is intact and the collision target absent.
        #expect(Self.exists(TestSupport.path("src.txt", in: root)))
        #expect(!Self.exists(TestSupport.path("collide.txt", in: root)))
    }

    @Test func twoMovesToSameDestinationAbort() throws {
        let (root, pathGuard) = Self.makeFixture()
        try Self.seed(Data("first\n".utf8), named: "one.txt", in: root)
        try Self.seed(Data("second\n".utf8), named: "two.txt", in: root)

        let hunks: [PatchParser.Hunk] = [
            .updateFile(path: TestSupport.path("one.txt", in: root), movePath: TestSupport.path("merged.txt", in: root), pairs: []),
            .updateFile(path: TestSupport.path("two.txt", in: root), movePath: TestSupport.path("merged.txt", in: root), pairs: []),
        ]
        guard case .corrective = Self.failure(PatchEngine.apply(hunks, using: pathGuard)) else {
            Issue.record("expected .corrective for two moves to the same destination")
            return
        }
        #expect(Self.exists(TestSupport.path("one.txt", in: root)))
        #expect(Self.exists(TestSupport.path("two.txt", in: root)))
    }

    @Test func deleteAndMoveToSamePathAborts() throws {
        let (root, pathGuard) = Self.makeFixture()
        try Self.seed(Data("mover\n".utf8), named: "a.txt", in: root)
        try Self.seed(Data("doomed\n".utf8), named: "b.txt", in: root)

        let hunks: [PatchParser.Hunk] = [
            .updateFile(path: TestSupport.path("a.txt", in: root), movePath: TestSupport.path("b.txt", in: root), pairs: []),
            .deleteFile(path: TestSupport.path("b.txt", in: root)),
        ]
        guard case .corrective = Self.failure(PatchEngine.apply(hunks, using: pathGuard)) else {
            Issue.record("expected .corrective when a move destination is also deleted")
            return
        }
    }

    @Test func swapOfTwoFilesIsAllowed() throws {
        let (root, pathGuard) = Self.makeFixture()
        let alphaBytes = Data("alpha\n".utf8)
        let betaBytes = Data("beta\n".utf8)
        try Self.seed(alphaBytes, named: "alpha.txt", in: root)
        try Self.seed(betaBytes, named: "beta.txt", in: root)

        // A filename swap: each section renames onto the other's path. Distinct
        // final paths, so the patch is legal and content is swapped.
        let hunks: [PatchParser.Hunk] = [
            .updateFile(path: TestSupport.path("alpha.txt", in: root), movePath: TestSupport.path("beta.txt", in: root), pairs: []),
            .updateFile(path: TestSupport.path("beta.txt", in: root), movePath: TestSupport.path("alpha.txt", in: root), pairs: []),
        ]
        _ = try Self.apply(hunks, using: pathGuard)

        #expect(Self.bytes(TestSupport.path("alpha.txt", in: root)) == betaBytes)
        #expect(Self.bytes(TestSupport.path("beta.txt", in: root)) == alphaBytes)
        #expect(TestSupport.temporaryFileLeftovers(in: root).isEmpty)
    }

    @Test func rotationOfThreeFilesIsAllowed() throws {
        let (root, pathGuard) = Self.makeFixture()
        let aBytes = Data("A\n".utf8)
        let bBytes = Data("B\n".utf8)
        let cBytes = Data("C\n".utf8)
        try Self.seed(aBytes, named: "a.txt", in: root)
        try Self.seed(bBytes, named: "b.txt", in: root)
        try Self.seed(cBytes, named: "c.txt", in: root)

        // a→b, b→c, c→a: distinct final paths, a legal rotation.
        let hunks: [PatchParser.Hunk] = [
            .updateFile(path: TestSupport.path("a.txt", in: root), movePath: TestSupport.path("b.txt", in: root), pairs: []),
            .updateFile(path: TestSupport.path("b.txt", in: root), movePath: TestSupport.path("c.txt", in: root), pairs: []),
            .updateFile(path: TestSupport.path("c.txt", in: root), movePath: TestSupport.path("a.txt", in: root), pairs: []),
        ]
        _ = try Self.apply(hunks, using: pathGuard)

        #expect(Self.bytes(TestSupport.path("b.txt", in: root)) == aBytes)
        #expect(Self.bytes(TestSupport.path("c.txt", in: root)) == bBytes)
        #expect(Self.bytes(TestSupport.path("a.txt", in: root)) == cBytes)
        #expect(TestSupport.temporaryFileLeftovers(in: root).isEmpty)
    }

    // MARK: Result helpers

    /// The `[FileOutcome]` of a successful apply, or a recorded failure.
    private static func apply(
        _ hunks: [PatchParser.Hunk],
        using pathGuard: PathGuard
    ) throws -> [PatchEngine.FileOutcome] {
        switch PatchEngine.apply(hunks, using: pathGuard) {
        case .success(let outcomes):
            return outcomes
        case .failure(let failure):
            Issue.record("expected success, got failure: \(failure)")
            throw failure
        }
    }

    /// The failure of an apply that is expected to fail.
    private static func failure(
        _ result: Result<[PatchEngine.FileOutcome], PatchEngine.Failure>
    ) -> PatchEngine.Failure {
        switch result {
        case .success:
            Issue.record("expected failure, got success")
            return .corrective("unexpected success")
        case .failure(let failure):
            return failure
        }
    }
}
