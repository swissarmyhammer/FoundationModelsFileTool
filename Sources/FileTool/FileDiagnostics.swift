import Foundation

/// The compiler diagnostics folded into a `write file` / `edit file` result after a committed mutation.
///
/// - Important: This is a STUB. The real type — mapping a CodeContext
///   `DiagnosticsReport` into a `status` (clean / errors / warnings / pending /
///   skipped), error and warning counts, and capped per-item detail — lands in
///   the later diagnostics-bridge task, which also wires it into
///   ``WriteResult/diagnostics`` (and the edit result). It is declared here,
///   empty, only so a mutation result can carry the optional field now, always
///   `nil`, without pulling the diagnostics engine into the write task. Do not
///   build real behavior on this type yet.
///
/// Conforms to `Encodable` and `Sendable` trivially: the stub carries no stored
/// state. The real type will preserve both conformances.
public struct FileDiagnostics: Encodable, Sendable {
    /// Creates the stub value.
    ///
    /// The real initializer will take the mapped diagnostics; this placeholder
    /// takes nothing and does no work.
    public init() {}
}
