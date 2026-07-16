import Foundation
import FoundationModelsCodeContext

/// A no-op ``TextEmbedding`` producing a single-dimension zero vector per input.
///
/// `CodeContextManager.init` requires a ``TextEmbedding`` because a context's
/// full search index embeds chunks as it reconciles. The diagnostics bridge
/// only ever asks a context for compiler diagnostics — never a semantic search —
/// so it has no need of a real embedding model, and paying for one (a GPU-backed
/// model download and load) purely to fold errors into a `write file` / `edit
/// file` result would be wasteful. `NullEmbedder` satisfies the initializer's
/// seam with the cheapest possible conformance: one fixed-length zero vector per
/// input, computed without any model. A diagnostics-only start mode is the
/// intended upstream follow-up (see `plan.md` §4); until then this keeps context
/// creation model-free.
public struct NullEmbedder: TextEmbedding {
    /// The length of every embedding vector this embedder produces.
    ///
    /// One is the smallest valid embedding width: enough to satisfy the
    /// ``TextEmbedding`` contract (a non-empty, fixed-length vector) while
    /// allocating essentially nothing per input.
    private static let vectorDimension = 1

    /// The length of every embedding vector this embedder produces.
    public var dimension: Int { Self.vectorDimension }

    /// Creates a null embedder.
    public init() {}

    /// Returns one ``dimension``-length zero vector per input string.
    ///
    /// - Parameter texts: the strings to (nominally) embed.
    /// - Returns: one ``dimension``-length zero vector per input, in the same
    ///   order as `texts`.
    /// - Throws: Nothing; the signature carries `throws` to satisfy the
    ///   ``TextEmbedding`` protocol requirement.
    public func embed(_ texts: [String]) async throws -> [[Float]] {
        texts.map { _ in [Float](repeating: 0, count: Self.vectorDimension) }
    }
}
