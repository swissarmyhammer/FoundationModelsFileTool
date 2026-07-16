import Foundation

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

    /// The live edit-diagnostics bridge.
    ///
    /// The handle is held eagerly and is cheap to create; the bridge defers the
    /// expensive work — creating its `CodeContextManager` and starting a
    /// language server — to the first diagnosable mutation internally (unless
    /// `eagerWarmup` warms the enclosing project at creation), so a session that
    /// never mutates a diagnosable file never starts a server.
    public let diagnostics: DiagnosticsBridge

    /// Creates a session context rooted at a working directory.
    ///
    /// - Parameters:
    ///   - root: the session working directory; also the ``pathGuard`` workspace
    ///     boundary and relative-path base.
    ///   - readOnly: whether to forbid mutating operations; defaults to `false`.
    ///   - allowSymlinks: whether the guard resolves symlinks rather than
    ///     rejecting them; defaults to `false` (the secure default).
    ///   - eagerWarmup: whether the diagnostics bridge best-effort warms the
    ///     project enclosing ``root`` at creation rather than lazily on the first
    ///     diagnosable mutation; defaults to `false`.
    public init(root: URL, readOnly: Bool = false, allowSymlinks: Bool = false, eagerWarmup: Bool = false) {
        self.root = root
        self.readOnly = readOnly
        self.pathGuard = PathGuard(root: root, workspaceRoot: root, allowSymlinks: allowSymlinks)
        self.diagnostics = DiagnosticsBridge(root: root, eagerWarmup: eagerWarmup)
    }
}
