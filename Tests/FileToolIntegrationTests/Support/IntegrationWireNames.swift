/// The wire-name string constants both tier-B suites assert against.
///
/// The `write file` / `edit file` / diagnostics wire vocabulary (status names,
/// `matchedBy` rungs, encodings, line endings, the `read file` format) is shared
/// by ``EditsOKTests`` and ``CrossOpFlowTests``, so it lives here once rather
/// than as duplicated literals in each suite. Each value mirrors a production
/// raw value (``FileDiagnostics`` status, ``EditFile`` `StatusName`,
/// ``AtomicWriter/TextEncoding`` / ``AtomicWriter/LineEnding``), so a test names
/// the outcome it expects instead of restating a bare string.
///
/// - Note: The fused-tool type alias each suite dispatches against stays a
///   per-file `private typealias`, matching suite A's ``ErrorDetectionTests``
///   convention; only the wire-name data is hoisted here.
enum IntegrationWire {
    /// The `clean` diagnostics status: no errors or warnings.
    static let clean = "clean"

    /// The `errors` diagnostics status.
    static let errors = "errors"

    /// The `skipped` diagnostics status: no diagnostics pass ran.
    static let skipped = "skipped"

    /// The `pending` diagnostics status: the report may be incomplete.
    static let pending = "pending"

    /// The whole-batch status of a successfully applied `edit file`.
    static let applied = "applied"

    /// The `matchedBy` name of an anchor-resolved edit.
    static let anchorMatch = "anchor"

    /// The `matchedBy` name of a literal-resolved edit.
    static let literalMatch = "literal"

    /// The `matchedBy` name of a recovery-ladder-resolved edit.
    static let recoveredMatch = "recovered"

    /// The `plain` read format: verbatim line text, no hashline anchor.
    static let plainFormat = "plain"

    /// The `utf-8` encoding wire name.
    static let utf8Encoding = "utf-8"

    /// The `utf-8 bom` encoding wire name.
    static let utf8BomEncoding = "utf-8 bom"

    /// The `crlf` line-ending wire name.
    static let crlfLineEnding = "crlf"
}
