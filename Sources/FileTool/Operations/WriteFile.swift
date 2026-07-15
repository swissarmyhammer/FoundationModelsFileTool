import Foundation
import FoundationModels
import Operations

/// The successful result of a `write file` operation: the written bytes' freshness token and hashline-tagged content.
///
/// The ``hash`` is the whole-file freshness token over the bytes just written
/// and the ``taggedContent`` is those bytes tagged with absolute hashline
/// anchors, both computed exactly as a subsequent `read file` of the same path
/// computes them — so a chained `edit file` can resolve the anchors without an
/// intervening read. The ``diagnostics`` are the compiler diagnostics folded in
/// after the mutation; they are always `nil` until the diagnostics-bridge task
/// wires them.
public struct WriteResult: Encodable, Sendable {
    /// The absolute path written.
    public let path: String

    /// The number of bytes written.
    public let bytesWritten: Int

    /// The whole-file freshness token over the written bytes.
    public let hash: String

    /// The written content tagged with absolute `N:HH|text` hashline anchors, one entry per line.
    public let taggedContent: [String]

    /// The compiler diagnostics for the write, or `nil` when none are folded in.
    public let diagnostics: FileDiagnostics?

    /// Creates a write result.
    ///
    /// - Parameters:
    ///   - path: the absolute path written.
    ///   - bytesWritten: the number of bytes written.
    ///   - hash: the whole-file freshness token over the written bytes.
    ///   - taggedContent: the written content tagged with absolute hashline
    ///     anchors, one entry per line.
    ///   - diagnostics: the compiler diagnostics for the write, or `nil`.
    public init(
        path: String,
        bytesWritten: Int,
        hash: String,
        taggedContent: [String],
        diagnostics: FileDiagnostics?
    ) {
        self.path = path
        self.bytesWritten = bytesWritten
        self.hash = hash
        self.taggedContent = taggedContent
        self.diagnostics = diagnostics
    }
}

/// The outcome of a `write file` operation: either the written result or a corrective message.
///
/// The operation follows the upstream *return-don't-throw* convention (the same
/// convention ``ReadOutput`` and ``PathViolation`` embody): an over-cap content,
/// a rejected path, or a failed write is surfaced as a ``corrective(_:)``
/// message the model reads and acts on within the turn, never thrown. Throwing
/// from an operation's `execute(in:)` is fatal to the turn, so every
/// recoverable condition returns a value instead.
public enum WriteOutput: Encodable, Sendable {
    /// A successful write carrying the ``WriteResult``.
    case content(WriteResult)

    /// A recoverable failure carrying a corrective message for the model.
    case corrective(String)

    /// The coding keys for the ``corrective(_:)`` encoding.
    private enum CodingKeys: String, CodingKey {
        /// The corrective-message field.
        case corrective
    }

    /// Encodes the outcome.
    ///
    /// A ``content(_:)`` outcome encodes the ``WriteResult`` inline (its `path`,
    /// `bytesWritten`, `hash`, `taggedContent`, and `diagnostics` fields); a
    /// ``corrective(_:)`` outcome encodes a single `corrective` field carrying
    /// the message.
    ///
    /// - Parameter encoder: the encoder to write the outcome into.
    public func encode(to encoder: Encoder) throws {
        switch self {
        case .content(let result):
            try result.encode(to: encoder)
        case .corrective(let message):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(message, forKey: .corrective)
        }
    }
}

/// Writes content to a file atomically, returning its freshness token and hashline-tagged content.
///
/// The pipeline rejects content over the size cap, validates the path via the
/// context's ``PathGuard`` for a write, and writes the UTF-8 content through
/// ``AtomicWriter`` (temp file in the same directory, permission-preserving
/// atomic rename, single cleanup path on any failure). The write is an
/// unconditional clobber — there is no freshness or hash precondition, matching
/// the upstream `files` tool, where lost-update protection lives in anchored
/// edits rather than in the write. Every recoverable failure is returned as a
/// ``WriteOutput/corrective(_:)`` message; nothing here throws for an over-cap
/// content, a bad path, or a failed write.
@Generable
@Operation(verb: "write", noun: "file", description: "Write content to a file atomically, returning its freshness token and hashline-tagged content")
public struct WriteFile: Sendable {
    /// The path of the file to write.
    public var filePath: String

    /// The content to write.
    public var content: String
}

extension WriteFile {
    // MARK: Content-size cap

    /// The number of bytes in one mebibyte.
    private static let bytesPerMebibyte = 1024 * 1024

    /// The maximum accepted content size in mebibytes, matching the Rust `files` tool.
    private static let maximumContentMebibytes = 10

    /// The maximum accepted content size in UTF-8 bytes (the 10 MiB write cap).
    private static let maximumContentByteCount = maximumContentMebibytes * bytesPerMebibyte

    /// A corrective message when `content` exceeds the size cap, or `nil` when acceptable.
    ///
    /// The size is measured in UTF-8 bytes — the bytes actually written — so a
    /// multi-byte scalar counts as its encoded length. Content exactly at the
    /// cap is accepted; only content strictly larger is rejected.
    ///
    /// - Parameter content: the content to check.
    /// - Returns: the ``overSizeMessage`` when `content` is over the cap, else `nil`.
    private static func contentSizeViolation(_ content: String) -> String? {
        content.utf8.count > maximumContentByteCount ? overSizeMessage : nil
    }

    /// The corrective message naming the content-size cap.
    private static var overSizeMessage: String {
        "The `content` parameter must be at most \(maximumContentMebibytes) MiB (\(maximumContentByteCount) bytes)."
    }

    // MARK: Hashline tagging

    /// The 1-based line number assigned to the first line of tagged content.
    private static let firstLineNumber = 1

    /// Tag `content` with absolute hashline anchors, one entry per line.
    ///
    /// Uses ``Hashline/tag(lines:startingAtLine:)`` from the first line and then
    /// splits into per-line entries, exactly as `read file` renders a whole-file
    /// hashline read, so the write envelope's anchors match a later read of the
    /// same path.
    ///
    /// - Parameter content: the written content.
    /// - Returns: the tagged lines, empty for empty content.
    private static func tagged(content: String) -> [String] {
        let tagged = Hashline.tag(lines: content, startingAtLine: firstLineNumber)
        return Hashline.splitLines(tagged).map(\.text)
    }

    // MARK: Corrective messages

    /// A corrective message for a path that validated but could not be written.
    ///
    /// - Parameter path: the requested path.
    /// - Returns: the corrective message.
    private static func writeFailureMessage(path: String) -> String {
        "The file could not be written: \(path)"
    }

    // MARK: Execution

    /// Writes the content and returns the write result or a corrective message.
    ///
    /// Rejects over-cap content, then validates the path via the context's
    /// ``PathGuard`` for a write, then writes the UTF-8 content through
    /// ``AtomicWriter``. Every recoverable failure is returned as
    /// ``WriteOutput/corrective(_:)``; nothing here throws for an over-cap
    /// content, a bad path, or a failed write.
    ///
    /// - Parameter context: the shared session context supplying the path guard.
    /// - Returns: the ``WriteOutput/content(_:)`` on success, or a
    ///   ``WriteOutput/corrective(_:)`` message the model can act on.
    public func execute(in context: FileContext) async throws -> WriteOutput {
        if let message = Self.contentSizeViolation(content) { return .corrective(message) }

        let url: URL
        switch context.pathGuard.validate(filePath, for: .write) {
        case .success(let resolved):
            url = resolved
        case .failure(let violation):
            return .corrective(violation.message)
        }

        let data = Data(content.utf8)
        do {
            try AtomicWriter.write(data, to: url)
        } catch {
            return .corrective(Self.writeFailureMessage(path: filePath))
        }

        return .content(
            WriteResult(
                path: url.path,
                bytesWritten: data.count,
                hash: Hashline.wholeFileHash(bytes: data),
                taggedContent: Self.tagged(content: content),
                diagnostics: nil
            )
        )
    }
}
