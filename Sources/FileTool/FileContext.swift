import Foundation

/// The live edit-diagnostics bridge handle carried by a ``FileContext``.
///
/// - Important: This is a STUB. The real bridge — which wraps a
///   `FoundationModelsCodeContext` instance and folds compiler
///   errors and warnings into `write file` / `edit file` output after a
///   committed mutation — lands in its own later task. It is declared here only
///   so ``FileContext`` can carry the lazily-created handle the file operations
///   will eventually consume, without pulling the diagnostics engine into this
///   task. Do not build real behavior on this type yet.
///
/// Conforms to `Sendable` trivially: the stub carries no stored state. The
/// real bridge will preserve `Sendable` conformance, isolating any mutable
/// engine state behind an actor or equivalent synchronization.
public final class DiagnosticsBridge: Sendable {
    /// Creates the stub bridge.
    ///
    /// The real initializer will take the diagnostics-engine configuration; this
    /// placeholder takes nothing and does no work.
    public init() {}
}

/// The shared per-session state the five file operations dispatch against.
///
/// A `FileContext` bundles everything one agent session's file tools need: the
/// session ``root`` directory, the ``pathGuard`` that validates every path
/// against it, a ``readOnly`` flag, and the ``diagnostics`` bridge handle. It is
/// a reference type so the operations share one instance — and one diagnostics
/// bridge — for the life of the session.
///
/// The ``pathGuard`` enforces ``root`` as its workspace boundary, so every
/// operation is confined to the session root by default.
///
/// - Note: The operations dispatch through the `Operations` runtime, whose
///   `OperationDefinition` constrains its shared context to `Sendable`. Every
///   stored property is immutable and `Sendable` (``root``, ``pathGuard``,
///   ``readOnly``, and the ``diagnostics`` handle), so the type is a checked
///   `Sendable`. The handle is held eagerly, not lazily: the deferral that
///   matters — starting the (expensive) diagnostics engine only on the first
///   diagnosable mutation — belongs inside the bridge, so holding a cheap
///   handle eagerly keeps the shared context race-free.
public final class FileContext: Sendable {
    /// The session working directory: the boundary and relative-path base.
    public let root: URL

    /// The validator every path passes through before an operation runs.
    ///
    /// Built from ``root`` as both the relative-path base and the workspace
    /// boundary, so operations are confined to the session root.
    public let pathGuard: PathGuard

    /// Whether the session forbids mutating operations (`write` / `edit`).
    ///
    /// The operations consult this to reject mutations up front; path validation
    /// itself is unaffected.
    public let readOnly: Bool

    /// The live edit-diagnostics bridge handle.
    ///
    /// - Important: Currently a ``DiagnosticsBridge`` stub (see that type). The
    ///   handle is held eagerly and is cheap to create; the real bridge defers
    ///   the expensive diagnostics-engine startup to the first diagnosable
    ///   mutation internally, so a session that never mutates a diagnosable file
    ///   never starts that engine.
    public let diagnostics: DiagnosticsBridge

    /// Creates a session context rooted at a working directory.
    ///
    /// - Parameters:
    ///   - root: the session working directory; also the ``pathGuard`` workspace
    ///     boundary and relative-path base.
    ///   - readOnly: whether to forbid mutating operations; defaults to `false`.
    ///   - allowSymlinks: whether the guard resolves symlinks rather than
    ///     rejecting them; defaults to `false` (the secure default).
    public init(root: URL, readOnly: Bool = false, allowSymlinks: Bool = false) {
        self.root = root
        self.readOnly = readOnly
        self.pathGuard = PathGuard(root: root, workspaceRoot: root, allowSymlinks: allowSymlinks)
        self.diagnostics = DiagnosticsBridge()
    }
}
