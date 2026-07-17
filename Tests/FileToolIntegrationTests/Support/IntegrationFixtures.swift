import Foundation

/// Byte-level fixture builders for the cross-op integration flows.
///
/// The edits-OK matrix works in valid UTF-8 Swift, but the cross-op suite must
/// prove the operations preserve *bytes* the ``IsolatedWorkspace/write(_:to:)``
/// UTF-8 helper cannot express: a CRLF-terminated file, a byte-order-mark file,
/// and an executable script. These builders seed such files raw and read them
/// back raw, so a test asserts on the exact on-disk bytes and permission bits
/// after an edit rather than on a decoded, convention-normalized string.
///
/// The primitives are kept in the shared Support directory (rather than inlined
/// per test) so the raw-byte write, the executable-bit application, and the
/// permission read have a single implementation across the suite.
enum IntegrationFixtures {
    /// The UTF-8 byte-order-mark bytes (`EF BB BF`).
    ///
    /// The marker ``AtomicWriter`` detects and preserves; a test seeds a file with
    /// it and asserts it survives an edit byte-for-byte.
    static let utf8ByteOrderMark = Data([0xEF, 0xBB, 0xBF])

    /// The executable permission bits (`0o755`) an executable fixture is seeded with.
    ///
    /// A test asserts these exact bits survive an edit, proving ``AtomicWriter``
    /// re-applies the original mode across its permission-preserving rename.
    static let executablePermissionBits: mode_t = 0o755

    /// Writes raw bytes to a file, creating parent directories.
    ///
    /// The raw counterpart to ``IsolatedWorkspace/write(_:to:)``: it writes the
    /// exact bytes given (a CRLF body, a byte-order-mark body) rather than
    /// UTF-8-encoding a string, so a byte-preservation test controls every byte
    /// on disk.
    ///
    /// - Parameters:
    ///   - data: the exact bytes to write.
    ///   - fileURL: the destination file URL.
    /// - Throws: a file-system error if the directory or file cannot be created.
    static func writeBytes(_ data: Data, to fileURL: URL) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL)
    }

    /// Reads a file's raw on-disk bytes.
    ///
    /// - Parameter fileURL: the file URL to read.
    /// - Returns: the file's exact bytes.
    /// - Throws: a file-system error if the file cannot be read.
    static func readBytes(_ fileURL: URL) throws -> Data {
        try Data(contentsOf: fileURL)
    }

    /// Marks a file executable (`0o755`).
    ///
    /// Used to seed an executable-script fixture so a test can prove the bit is
    /// preserved across an edit's permission-preserving atomic rewrite.
    ///
    /// - Parameter fileURL: the file URL to mark executable.
    /// - Throws: an error if the permission bits cannot be applied.
    static func makeExecutable(at fileURL: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: executablePermissionBits)],
            ofItemAtPath: fileURL.path
        )
    }

    /// The POSIX permission bits (`mode & 0o777`) of a file.
    ///
    /// - Parameter fileURL: the file URL to inspect.
    /// - Returns: the permission bits, or `nil` when the attributes are unreadable.
    static func permissionBits(of fileURL: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.posixPermissions] as? Int) ?? nil
    }
}
