import Foundation

/// One compiler diagnostic folded into a `write file` / `edit file` result: where it is, and what it says.
///
/// The `Encodable` projection of a single diagnostic record, flattened into the
/// shape the model consumes. The ``file`` is relative to the session root and
/// the ``line`` / ``column`` are one-based (matching the tool's one-based
/// hashline convention), so the model can feed them straight back into an
/// `edit file` without an intervening `read file`.
public struct DiagnosticItem: Encodable, Sendable {
    /// The file this diagnostic applies to, relative to the session root.
    public let file: String

    /// The one-based line the diagnostic starts on.
    public let line: Int

    /// The one-based column the diagnostic starts on.
    public let column: Int

    /// The diagnostic's severity: `error`, `warning`, `information`, or `hint`.
    public let severity: String

    /// The human-readable diagnostic message.
    public let message: String

    /// The language server's diagnostic code (for example `E0308`), or `nil` when none was reported.
    public let code: String?

    /// Creates a diagnostic item.
    ///
    /// - Parameters:
    ///   - file: the file this diagnostic applies to, relative to the session root.
    ///   - line: the one-based line the diagnostic starts on.
    ///   - column: the one-based column the diagnostic starts on.
    ///   - severity: the diagnostic's severity.
    ///   - message: the human-readable diagnostic message.
    ///   - code: the language server's diagnostic code, or `nil`.
    public init(file: String, line: Int, column: Int, severity: String, message: String, code: String?) {
        self.file = file
        self.line = line
        self.column = column
        self.severity = severity
        self.message = message
        self.code = code
    }
}

/// The compiler diagnostics folded into a `write file` / `edit file` result after a committed mutation.
///
/// Produced by ``DiagnosticsBridge`` from the diagnostics a resolved
/// `CodeContext` reports for the mutated file (and its one-hop broken
/// dependents). The ``status`` names the whole result:
///
/// - `clean` — the file (and its dependents) compiled with no errors or
///   warnings; an *edit-was-OK* signal the model can trust.
/// - `errors` / `warnings` — the mutation left errors (or only warnings); the
///   ``items`` carry the messages with one-based line/column so the model can
///   fix them with the very next `edit file`.
/// - `pending` — the language server had not settled before the hard timeout,
///   or the bridge could not complete a diagnostics pass; the mutation is still
///   committed, so this never blocks the op. The ``note`` explains it.
/// - `skipped` — no diagnostics pass ran at all: the file's extension has no
///   language server, the path contained a glob metacharacter, or the file is
///   not inside any git workspace. The ``note`` says which.
///
/// The ``errors`` / ``warnings`` counts are the true counts across the resolved
/// records; ``items`` is capped to a bridge-owned maximum, so a run with more
/// diagnostics than the cap still reports accurate counts alongside a truncated
/// detail list.
public struct FileDiagnostics: Encodable, Sendable {
    /// The whole-result status: `clean`, `errors`, `warnings`, `pending`, or `skipped`.
    public let status: String

    /// The number of error-severity diagnostics across the resolved records.
    public let errors: Int

    /// The number of warning-severity diagnostics across the resolved records.
    public let warnings: Int

    /// The per-diagnostic detail, capped to the bridge's item limit.
    public let items: [DiagnosticItem]

    /// A human-readable note explaining a `pending` or `skipped` status, or `nil` for `clean` / `errors` / `warnings`.
    public let note: String?

    /// Creates a file-diagnostics result.
    ///
    /// - Parameters:
    ///   - status: the whole-result status.
    ///   - errors: the number of error-severity diagnostics.
    ///   - warnings: the number of warning-severity diagnostics.
    ///   - items: the per-diagnostic detail, already capped.
    ///   - note: a human-readable note for a `pending` / `skipped` status, or `nil`.
    public init(status: String, errors: Int, warnings: Int, items: [DiagnosticItem], note: String?) {
        self.status = status
        self.errors = errors
        self.warnings = warnings
        self.items = items
        self.note = note
    }
}
