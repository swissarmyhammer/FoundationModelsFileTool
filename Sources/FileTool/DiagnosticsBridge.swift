import Foundation
import FoundationModelsCodeContext

// MARK: - Resolver seam value types

/// A diagnostic's severity, mirrored as a FileTool-owned raw-valued enum.
///
/// A deliberate mirror of the upstream `DiagnosticSeverity`, kept FileTool-owned
/// so the ``DiagnosticsResolving`` seam (and its fake test conformance) never
/// depends on a value only obtainable from a running context. The raw values are
/// the wire severity names a ``DiagnosticItem`` carries, so the mapping is data,
/// not a parallel switch of string literals.
enum ResolvedSeverity: String, Sendable {
    /// An error-severity diagnostic.
    case error

    /// A warning-severity diagnostic.
    case warning

    /// An informational-severity diagnostic.
    case information

    /// A hint-severity diagnostic.
    case hint
}

/// One diagnostic record, decoupled from the upstream `DiagnosticRecord`.
///
/// The ``DiagnosticsResolving`` seam returns these rather than upstream
/// `DiagnosticRecord`s so a fake conformance can construct them directly — the
/// upstream type's initializer is `internal` and the dependency is not built for
/// testing, so it is unconstructable across the package boundary. The
/// ``relativePath`` is relative to the resolved context's root (rebased to the
/// session root only when a ``DiagnosticItem`` is built), and ``line`` /
/// ``column`` are zero-based, exactly as the language server reports them.
struct ResolvedDiagnosticRecord: Sendable {
    /// The file this diagnostic applies to, relative to the resolved context's root.
    let relativePath: String

    /// The zero-based line the diagnostic starts on.
    let line: Int

    /// The zero-based column the diagnostic starts on.
    let column: Int

    /// The diagnostic's severity.
    let severity: ResolvedSeverity

    /// The human-readable diagnostic message.
    let message: String

    /// The language server's diagnostic code, or `nil` when none was reported.
    let code: String?
}

/// The outcome of resolving-then-diagnosing one mutated file.
///
/// Pairs the diagnostic records (and their true counts and pending flag) with
/// the resolved context's root, which the bridge needs to rebase each record's
/// path to session-root-relative. This is the "track resolved root for output
/// rebase" the seam exists to surface — the record paths alone cannot be rebased
/// without knowing which context root they are relative to, and the upstream
/// `DiagnosticsReport` cannot be rebuilt with rewritten paths (its initializer
/// is `internal`).
struct ResolvedDiagnostics: Sendable {
    /// Every diagnostic record, targets first then folded-in broken dependents.
    let records: [ResolvedDiagnosticRecord]

    /// The true number of error-severity records, before any item cap.
    let errorCount: Int

    /// The true number of warning-severity records, before any item cap.
    let warningCount: Int

    /// Whether the report may be incomplete (the server had not settled).
    let pending: Bool

    /// The resolved context's root, which ``records`` paths are relative to.
    let contextRoot: URL
}

// MARK: - Resolver seam

/// The resolve-then-diagnose seam the ``DiagnosticsBridge`` dispatches against.
///
/// One method mirrors the production flow — resolve the `CodeContext` covering a
/// file, ask it for diagnostics, and hand back the records plus the resolved
/// root — returning `nil` when no workspace covers the file. Two lifecycle
/// methods warm a project and shut everything down, and one query reports the
/// currently open roots (for `@testable` integration assertions).
///
/// The seam takes no dependency on `CodeContext` internals: it trades only in
/// FileTool-owned value types and the public `DiagnosticSeverity`. Production
/// code wires it to ``ManagerDiagnosticsResolver`` (which owns the real
/// `CodeContextManager`); unit tests inject a fake keyed by path prefix, so
/// ``DiagnosticsBridge`` can be tested without a manager, a language server, or
/// the filesystem.
protocol DiagnosticsResolving: Sendable {
    /// Resolves the workspace covering `fileURL` and returns its diagnostics.
    ///
    /// - Parameters:
    ///   - fileURL: the absolute path of the mutated, already-validated file.
    ///   - severity: the minimum severity to report.
    ///   - includeDependents: whether to fold in broken one-hop dependents.
    ///   - settleWindow: the quiescence window the settle engine waits for.
    ///   - hardTimeout: the hard cap on the settle wait.
    ///   - perReportCap: the upstream per-report record cap.
    /// - Returns: the resolved diagnostics, or `nil` when no workspace covers `fileURL`.
    /// - Throws: any error opening or querying the covering workspace.
    func diagnostics(
        forFileAt fileURL: URL,
        severity: DiagnosticSeverity,
        includeDependents: Bool,
        settleWindow: Duration,
        hardTimeout: Duration,
        perReportCap: Int
    ) async throws -> ResolvedDiagnostics?

    /// Best-effort warms the workspace enclosing `root`, ignoring failures.
    ///
    /// - Parameter root: the directory whose enclosing workspace to warm.
    func warmUp(root: URL) async

    /// The workspace roots currently open.
    ///
    /// - Returns: the open roots, in no particular order.
    func openRootDirectories() async -> [URL]

    /// Closes every open workspace.
    func shutdown() async
}

// MARK: - Production resolver

/// The production ``DiagnosticsResolving`` backed by one lazily-created `CodeContextManager`.
///
/// Owns a single `CodeContextManager<ProcessLanguageServerConnection>`, created
/// on the first resolve (or warm-up) and reused thereafter. Each resolve routes
/// through `context(containing:openIfNeeded:)` (longest-prefix over open roots,
/// else git-root discovery and open), asks the resolved context for diagnostics,
/// and maps the upstream `DiagnosticsReport` into a ``ResolvedDiagnostics``
/// carrying the resolved root for the bridge's path rebase.
actor ManagerDiagnosticsResolver: DiagnosticsResolving {
    /// The embedder handed to the manager (and thus every context it opens).
    private let embedder: TextEmbedding

    /// The manager, created lazily on the first resolve or warm-up.
    private var manager: CodeContextManager<ProcessLanguageServerConnection>?

    /// Creates a resolver that will lazily build its manager from `embedder`.
    ///
    /// - Parameter embedder: the embedder handed to every context the manager opens.
    init(embedder: TextEmbedding) {
        self.embedder = embedder
    }

    /// Returns the manager, creating it on first use.
    ///
    /// - Returns: the lazily-created, reused manager.
    private func ensureManager() async -> CodeContextManager<ProcessLanguageServerConnection> {
        if let manager {
            return manager
        }
        let created = await CodeContextManager(embedder: embedder)
        manager = created
        return created
    }

    func diagnostics(
        forFileAt fileURL: URL,
        severity: DiagnosticSeverity,
        includeDependents: Bool,
        settleWindow: Duration,
        hardTimeout: Duration,
        perReportCap: Int
    ) async throws -> ResolvedDiagnostics? {
        let manager = await ensureManager()
        guard let context = try await manager.context(containing: fileURL, openIfNeeded: true) else {
            return nil
        }
        let report = try await context.diagnostics(
            scope: .file(fileURL.path),
            severity: severity,
            includeDependents: includeDependents,
            settleWindow: settleWindow,
            hardTimeout: hardTimeout,
            perReportCap: perReportCap
        )
        return Self.resolved(from: report, contextRoot: context.rootDirectory)
    }

    func warmUp(root: URL) async {
        let manager = await ensureManager()
        _ = try? await manager.context(containing: root, openIfNeeded: true)
    }

    func openRootDirectories() async -> [URL] {
        guard let manager else {
            return []
        }
        // `ManagerState.roots` is main-actor-isolated (it drives SwiftUI), so
        // read it by hopping onto the main actor.
        let state = manager.state
        return await MainActor.run { state.roots }
    }

    func shutdown() async {
        await manager?.shutdown()
    }

    /// Maps an upstream `DiagnosticsReport` into a ``ResolvedDiagnostics``.
    ///
    /// The error/warning counts are read from the report's own counts (true up
    /// to the per-report cap the bridge passes), so the bridge's own item cap
    /// never undercounts.
    ///
    /// - Parameters:
    ///   - report: the report to map.
    ///   - contextRoot: the resolved context's root, carried through for rebase.
    /// - Returns: the mapped resolved diagnostics.
    private static func resolved(from report: DiagnosticsReport, contextRoot: URL) -> ResolvedDiagnostics {
        ResolvedDiagnostics(
            records: report.records.map { record in mappedRecord(record: record) },
            errorCount: report.counts.errors,
            warningCount: report.counts.warnings,
            pending: report.pending,
            contextRoot: contextRoot
        )
    }

    /// Maps one upstream `DiagnosticRecord` into a ``ResolvedDiagnosticRecord``.
    ///
    /// - Parameter record: the upstream record to map.
    /// - Returns: the FileTool-owned record.
    private static func mappedRecord(record: DiagnosticRecord) -> ResolvedDiagnosticRecord {
        ResolvedDiagnosticRecord(
            relativePath: record.path,
            line: record.range.start.line,
            column: record.range.start.character,
            severity: mappedSeverity(record.severity),
            message: record.message,
            code: record.code
        )
    }

    /// The data-driven upstream-to-FileTool severity correspondence.
    ///
    /// Expresses the mapping as data rather than parallel switch arms a human
    /// must keep in lockstep, covering all four fixed `DiagnosticSeverity`
    /// cases. A severity absent from the table (which the fixed upstream enum
    /// cannot currently produce) falls back to ``ResolvedSeverity/error`` — the
    /// most conservative reading — in ``mappedSeverity(_:)``.
    private static let severityMapping: [DiagnosticSeverity: ResolvedSeverity] = [
        .error: .error,
        .warning: .warning,
        .information: .information,
        .hint: .hint,
    ]

    /// Maps an upstream `DiagnosticSeverity` to a ``ResolvedSeverity``.
    ///
    /// - Parameter severity: the upstream severity.
    /// - Returns: the mirrored FileTool severity, defaulting to ``ResolvedSeverity/error``.
    private static func mappedSeverity(_ severity: DiagnosticSeverity) -> ResolvedSeverity {
        severityMapping[severity] ?? .error
    }
}

// MARK: - Bridge

/// The live edit-diagnostics bridge: folds compiler errors and warnings into a `write file` / `edit file` result.
///
/// After a committed mutation of a diagnosable file, ``diagnose(fileAt:)``
/// resolves the `CodeContext` covering that file and maps its diagnostics into a
/// ``FileDiagnostics`` the operation carries back to the model. The bridge owns
/// one lazily-created `CodeContextManager<ProcessLanguageServerConnection>` (via
/// its production ``DiagnosticsResolving``), created on the first mutation of a
/// diagnosable file; a ``Mode/disabled`` bridge never creates it.
///
/// Because ``FileContext/root`` may sit *above* several git projects, resolution
/// is per-file: each mutated file routes to the longest-prefix open root, else
/// its enclosing git repository is discovered and opened. Diagnostic item paths
/// are rebased from the resolved context's root to session-root-relative, so the
/// model can feed them straight back into an `edit file`.
///
/// - Note: Nested-repo semantics are nearest-open-ancestor-wins. Once an outer
///   repository's context is open, files in a nested repository or submodule
///   route to the outer context by longest-prefix match. Conversely, if an inner
///   repository opened first, a later attempt to open the outer root throws
///   `CodeContextError.overlappingRoot`, which degrades to `pending` — the
///   mutation is already committed and is never failed by the bridge.
///
/// - Important: Diagnostics never gate a mutation. Any failure to produce them —
///   a resolver exception, an overlapping-root error, a not-yet-settled server —
///   degrades to a `pending` (or `skipped`) ``FileDiagnostics`` with a note; the
///   op has already succeeded and its success never depends on the bridge.
public final class DiagnosticsBridge: Sendable {
    // MARK: Mode

    /// Whether the bridge produces diagnostics at all.
    public enum Mode: Sendable {
        /// The bridge resolves and reports diagnostics (the default).
        case enabled

        /// The bridge produces nothing and never creates a manager — for a pure file tool.
        case disabled
    }

    // MARK: Tuning defaults

    /// The default settle-engine quiescence window.
    public static let defaultSettleWindow: Duration = .milliseconds(300)

    /// The default hard cap on the settle wait.
    public static let defaultHardTimeout: Duration = .seconds(5)

    /// The per-report record cap passed to upstream so error/warning counts stay true.
    ///
    /// Upstream truncates a report's records to the per-report cap *before*
    /// deriving its counts, so a small cap would undercount. The bridge passes
    /// this deliberately large value and applies its own smaller
    /// ``maximumReportedItemCount`` only when building ``FileDiagnostics/items``,
    /// keeping ``FileDiagnostics/errors`` / ``FileDiagnostics/warnings`` true.
    /// A run with more than this many records would still be truncated — a
    /// residual upstream limit, far above any realistic single-file diagnostics
    /// count.
    public static let defaultCountingPerReportCap = 10_000

    // MARK: Reporting policy

    /// The minimum severity the bridge reports: warnings and errors.
    private static let severityFloor: DiagnosticSeverity = .warning

    /// Whether the bridge folds in broken one-hop dependents.
    private static let includeDependents = true

    /// The offset applied to a zero-based language-server line/column to make it one-based.
    private static let lineColumnOriginOffset = 1

    /// The maximum number of ``DiagnosticItem``s a ``FileDiagnostics`` carries.
    ///
    /// The detail list is capped here while the error/warning counts remain
    /// true, so a mutation that breaks a great many sites still reports accurate
    /// totals alongside a bounded, useful detail list.
    ///
    /// Deliberately `internal` (not `private`, unlike the reporting-policy
    /// constants above): `DiagnosticsBridgeTests` reads it via `@testable` to
    /// generate an over-cap report and assert the capped item count against it
    /// rather than hard-coding `100` in the test. Narrowing it to `private`
    /// breaks that test.
    static let maximumReportedItemCount = 100

    /// The glob metacharacters, in the order the skip note lists them.
    ///
    /// The single source of truth behind both ``globMetacharacters`` — the set
    /// the gate checks — and ``globMetacharacterList`` — the human-readable list
    /// the skip note renders — so the two can never drift apart.
    private static let globMetacharacterStrings = ["*", "?", "["]

    /// The glob metacharacters a mutated file's absolute path must not contain.
    ///
    /// Upstream treats a `.file` scope containing any of these as a glob, which
    /// can silently resolve to zero targets and read as a false `clean`. A path
    /// carrying one — in the filename or any ancestor directory — is skipped
    /// before resolution instead. Built from ``globMetacharacterStrings``.
    private static let globMetacharacters: Set<Character> = Set(globMetacharacterStrings.flatMap { $0 })

    /// The glob metacharacters rendered as a human-readable list for the skip note.
    ///
    /// Derived from ``globMetacharacterStrings`` so the note's parenthetical and
    /// the gate's ``globMetacharacters`` set are always the same characters.
    private static var globMetacharacterList: String {
        guard let last = globMetacharacterStrings.last else {
            return ""
        }
        guard globMetacharacterStrings.count > 1 else {
            return last
        }
        return globMetacharacterStrings.dropLast().joined(separator: ", ") + ", or " + last
    }

    /// Every lowercased file extension handled by an LSP-backed language module.
    ///
    /// Derived from `Languages.all`, exactly mirroring upstream's own
    /// diagnosable-extension filter (`languageServer != nil`), so the bridge's
    /// gate can never drift from the set of files a running context would
    /// actually diagnose — a non-diagnosable file would otherwise resolve to
    /// zero targets upstream and read as a false `clean`.
    private static let diagnosableExtensions: Set<String> = Set(
        Languages.all
            .filter { module in module.languageServer != nil }
            .flatMap { module in module.fileExtensions.map { $0.lowercased() } }
    )

    // MARK: Notes

    // The model-facing note constants below (``nonDiagnosableNote``,
    // ``globMetacharacterNote``, ``notInWorkspaceNote``, ``pendingReportNote``)
    // are deliberately `internal`, not `private`: `DiagnosticsBridgeTests`
    // asserts a skipped/pending result carries exactly one of them, reading the
    // constant via `@testable` rather than duplicating the literal string in the
    // test. Narrowing any of them to `private` breaks those assertions. The
    // note *fragments* they are composed from (``noDiagnosticsPassNote``,
    // ``degradedNotePrefix``, ``degradedNoteSuffix``) are never referenced by a
    // test and so stay `private`.

    /// The shared suffix every skip note ends with: no diagnostics pass ran.
    ///
    /// Extracted so the three skip notes below carry byte-identical wording and
    /// a change to the phrasing happens in exactly one place.
    private static let noDiagnosticsPassNote = "— no diagnostics pass"

    /// The note on a file skipped because its type has no language server.
    static let nonDiagnosableNote = "no language server handles this file type \(noDiagnosticsPassNote)"

    /// The note on a file skipped because its name contains a glob metacharacter.
    static let globMetacharacterNote =
        "the path contains a glob metacharacter (\(globMetacharacterList)), so it cannot be diagnosed as a single file \(noDiagnosticsPassNote)"

    /// The note on a file skipped because it is not inside any git workspace.
    static let notInWorkspaceNote = "not inside a git workspace \(noDiagnosticsPassNote)"

    /// The note on a report the language server had not finished settling.
    static let pendingReportNote =
        "the language server is still warming up — re-check the diagnostics with a later read or diagnose pass"

    /// The note prefix on a report the bridge could not complete.
    private static let degradedNotePrefix = "diagnostics could not complete ("

    /// The note suffix on a report the bridge could not complete.
    private static let degradedNoteSuffix = "); the change was committed regardless"

    // MARK: Stored state

    /// Whether the bridge is enabled.
    private let mode: Mode

    /// The session root every item path is rebased against (the ``FileContext/root``).
    private let sessionRoot: URL

    /// The resolve-then-diagnose seam (production manager, or an injected fake).
    private let resolver: any DiagnosticsResolving

    /// The injected settle-engine quiescence window.
    private let settleWindow: Duration

    /// The injected hard cap on the settle wait.
    private let hardTimeout: Duration

    /// The injected per-report record cap passed to upstream.
    private let perReportCap: Int

    /// The best-effort eager warm-up task, or `nil` when lazy (or disabled).
    ///
    /// Non-`nil` only for an enabled, eagerly-warmed bridge. Exposed so tests
    /// can deterministically await the warm-up that ``init`` fires; production
    /// callers never need it (the mutation path does not depend on warm-up
    /// having completed).
    let warmUpTask: Task<Void, Never>?

    // MARK: Initialization

    /// Creates a production bridge owning a lazily-created `CodeContextManager`.
    ///
    /// - Parameters:
    ///   - root: the session root; also the base every item path is rebased against.
    ///   - mode: whether the bridge produces diagnostics; defaults to ``Mode/enabled``.
    ///   - eagerWarmup: whether to best-effort warm the enclosing project at creation; defaults to `false` (lazy).
    ///   - embedder: the embedder handed to every context; defaults to ``NullEmbedder``.
    ///   - settleWindow: the settle-engine quiescence window; defaults to ``defaultSettleWindow``.
    ///   - hardTimeout: the hard cap on the settle wait; defaults to ``defaultHardTimeout``.
    public convenience init(
        root: URL,
        mode: Mode = .enabled,
        eagerWarmup: Bool = false,
        embedder: TextEmbedding = NullEmbedder(),
        settleWindow: Duration = DiagnosticsBridge.defaultSettleWindow,
        hardTimeout: Duration = DiagnosticsBridge.defaultHardTimeout
    ) {
        self.init(
            root: root,
            mode: mode,
            eagerWarmup: eagerWarmup,
            resolver: ManagerDiagnosticsResolver(embedder: embedder),
            settleWindow: settleWindow,
            hardTimeout: hardTimeout,
            perReportCap: DiagnosticsBridge.defaultCountingPerReportCap
        )
    }

    /// Creates a bridge against an injected resolver.
    ///
    /// The designated initializer; unit tests use it to inject a fake
    /// ``DiagnosticsResolving`` and exact settle parameters, and the public
    /// convenience initializer uses it with a production resolver.
    ///
    /// - Parameters:
    ///   - root: the session root; also the base every item path is rebased against.
    ///   - mode: whether the bridge produces diagnostics.
    ///   - eagerWarmup: whether to best-effort warm the enclosing project at creation.
    ///   - resolver: the resolve-then-diagnose seam.
    ///   - settleWindow: the settle-engine quiescence window.
    ///   - hardTimeout: the hard cap on the settle wait.
    ///   - perReportCap: the per-report record cap passed to upstream.
    init(
        root: URL,
        mode: Mode,
        eagerWarmup: Bool,
        resolver: any DiagnosticsResolving,
        settleWindow: Duration,
        hardTimeout: Duration,
        perReportCap: Int
    ) {
        self.mode = mode
        self.sessionRoot = root
        self.resolver = resolver
        self.settleWindow = settleWindow
        self.hardTimeout = hardTimeout
        self.perReportCap = perReportCap

        if mode == .enabled, eagerWarmup {
            self.warmUpTask = Task { await resolver.warmUp(root: root) }
        } else {
            self.warmUpTask = nil
        }
    }

    /// Best-effort shuts the resolver's open workspaces down when the bridge is released.
    deinit {
        let resolver = self.resolver
        Task { await resolver.shutdown() }
    }

    // MARK: Diagnosing

    /// Diagnoses a just-mutated file, folding the result into a ``FileDiagnostics``.
    ///
    /// Gates before any resolution (so a ``Mode/disabled`` bridge and a
    /// non-diagnosable or glob-named file never touch the manager): a disabled
    /// bridge returns `nil`; a file whose extension has no language server or
    /// whose name carries a glob metacharacter returns a `skipped`
    /// ``FileDiagnostics``. Otherwise it resolves the covering workspace — `nil`
    /// resolution is `skipped` ("not inside a git workspace"), a resolver failure
    /// degrades to `pending` — and maps the diagnostics into `clean` / `errors` /
    /// `warnings` / `pending`, with item paths rebased to session-root-relative.
    ///
    /// Never throws: the mutation is already committed, so every failure degrades
    /// to a status-and-note rather than surfacing an error.
    ///
    /// - Parameter fileURL: the absolute path of the just-mutated, already-validated file.
    /// - Returns: the folded diagnostics, or `nil` when the bridge is ``Mode/disabled``.
    public func diagnose(fileAt fileURL: URL) async -> FileDiagnostics? {
        guard mode == .enabled else {
            return nil
        }
        guard Self.isDiagnosableExtension(fileURL) else {
            return Self.skipped(note: Self.nonDiagnosableNote)
        }
        guard !Self.containsGlobMetacharacter(fileURL) else {
            return Self.skipped(note: Self.globMetacharacterNote)
        }

        do {
            let resolved = try await resolver.diagnostics(
                forFileAt: fileURL,
                severity: Self.severityFloor,
                includeDependents: Self.includeDependents,
                settleWindow: settleWindow,
                hardTimeout: hardTimeout,
                perReportCap: perReportCap
            )
            guard let resolved else {
                return Self.skipped(note: Self.notInWorkspaceNote)
            }
            return mapped(resolved)
        } catch {
            return Self.degraded(error: error)
        }
    }

    /// The workspace roots the resolver currently has open.
    ///
    /// Exposed for `@testable` integration assertions over which contexts a real
    /// manager opened (and which it did not).
    ///
    /// - Returns: the open roots, in no particular order.
    func openRootDirectories() async -> [URL] {
        await resolver.openRootDirectories()
    }

    /// Closes every workspace the resolver has open.
    public func stop() async {
        await resolver.shutdown()
    }

    // MARK: Mapping

    /// Maps a ``ResolvedDiagnostics`` into a ``FileDiagnostics``.
    ///
    /// - Parameter resolved: the resolved diagnostics to map.
    /// - Returns: the folded diagnostics.
    private func mapped(_ resolved: ResolvedDiagnostics) -> FileDiagnostics {
        let status = Self.status(
            errorCount: resolved.errorCount,
            warningCount: resolved.warningCount,
            pending: resolved.pending
        )
        let items = resolved.records
            .prefix(Self.maximumReportedItemCount)
            .map { record in item(from: record, contextRoot: resolved.contextRoot) }
        return FileDiagnostics(
            status: status.rawValue,
            errors: resolved.errorCount,
            warnings: resolved.warningCount,
            items: Array(items),
            note: Self.note(for: status)
        )
    }

    /// The status of a resolved report from its counts and pending flag.
    ///
    /// Pending wins first (the report may be incomplete), then errors, then
    /// warnings, else clean.
    ///
    /// - Parameters:
    ///   - errorCount: the true error count.
    ///   - warningCount: the true warning count.
    ///   - pending: whether the report may be incomplete.
    /// - Returns: the mapped status.
    private static func status(errorCount: Int, warningCount: Int, pending: Bool) -> DiagnosticsStatus {
        if pending {
            return .pending
        }
        if errorCount > 0 {
            return .errors
        }
        if warningCount > 0 {
            return .warnings
        }
        return .clean
    }

    /// The note that accompanies a mapped status, or `nil` when none applies.
    ///
    /// - Parameter status: the mapped status.
    /// - Returns: the pending note for ``DiagnosticsStatus/pending``, else `nil`.
    private static func note(for status: DiagnosticsStatus) -> String? {
        status == .pending ? pendingReportNote : nil
    }

    /// Builds one ``DiagnosticItem`` from a resolved record, rebasing its path.
    ///
    /// - Parameters:
    ///   - record: the resolved record to project.
    ///   - contextRoot: the resolved context's root the record path is relative to.
    /// - Returns: the item, with a session-root-relative path and one-based line/column.
    private func item(from record: ResolvedDiagnosticRecord, contextRoot: URL) -> DiagnosticItem {
        DiagnosticItem(
            file: sessionRelativePath(forRecordPath: record.relativePath, contextRoot: contextRoot),
            line: record.line + Self.lineColumnOriginOffset,
            column: record.column + Self.lineColumnOriginOffset,
            severity: record.severity.rawValue,
            message: record.message,
            code: record.code
        )
    }

    /// Rebases a context-root-relative record path to session-root-relative.
    ///
    /// Joins the record path onto the resolved context root to recover the
    /// absolute path, then relativizes it against the session root.
    ///
    /// The record path is **untrusted input** from the upstream language server,
    /// so it is validated by ``isTraversalSafeRecordPath(_:)`` before any join.
    /// A path that fails that check — one that is absolute or carries a `.` or
    /// `..` component — is *not* joined: joining a `..`-laden path and
    /// standardizing it would collapse the `..` and escape the resolved context
    /// (and thus the session) root, and the escaped *absolute* path would then
    /// be handed to the model for a later file operation. Instead the path is
    /// reduced by ``sanitizedRelativePath(_:)`` to a leading-slash-free,
    /// traversal-free relative string that — appended to any base — can never
    /// resolve outside it. This upholds the invariant that **no item path this
    /// method returns is absolute or resolves outside the session root**, even
    /// for a hostile input such as `/etc/passwd` or `../../etc/passwd`.
    ///
    /// The same sanitizing fallback also covers the (architecturally impossible
    /// for a mutation confined to the session) case where a traversal-safe path
    /// nonetheless does not resolve under the session root, so no branch ever
    /// emits an escaping path.
    ///
    /// - Parameters:
    ///   - recordPath: the untrusted record path, relative to `contextRoot`.
    ///   - contextRoot: the resolved context's root.
    /// - Returns: the path relative to the session root, or — for an unsafe or
    ///   non-session-rooted path — a sanitized, traversal-free relative path.
    private func sessionRelativePath(forRecordPath recordPath: String, contextRoot: URL) -> String {
        guard Self.isTraversalSafeRecordPath(recordPath) else {
            return Self.sanitizedRelativePath(recordPath)
        }
        let absolute = contextRoot.appendingPathComponent(recordPath).standardizedFileURL
        let sessionComponents = sessionRoot.standardizedFileURL.pathComponents
        let absoluteComponents = absolute.pathComponents
        guard absoluteComponents.count > sessionComponents.count,
              Array(absoluteComponents.prefix(sessionComponents.count)) == sessionComponents
        else {
            return Self.sanitizedRelativePath(recordPath)
        }
        return absoluteComponents.suffix(from: sessionComponents.count).joined(separator: "/")
    }

    /// The path components that make a record path unsafe to join and rebase.
    ///
    /// A relative record path is safe to join onto the context root only when it
    /// contains none of these components: `..` (parent traversal, the escape
    /// vector) and `.` (current-directory reference). Both are rejected because
    /// a legitimate workspace-relative path from the language server contains
    /// neither, so their presence signals an untrusted or malformed path.
    private static let unsafeRecordPathComponents: Set<Substring> = ["..", "."]

    /// Whether an untrusted context-relative record path is safe to rebase.
    ///
    /// A record path is safe only when it is genuinely relative and stays within
    /// its context root: it must not be absolute (a leading `/`), and must
    /// contain no ``unsafeRecordPathComponents`` — a `.` or `..` component that,
    /// once joined and standardized, could resolve outside the context (and thus
    /// the session) root. This is a pure string check with no filesystem access:
    /// it deliberately does not reuse ``PathGuard``'s validation, which
    /// canonicalizes against the filesystem and rejects symlinks, because the
    /// rebase must stay a side-effect-free path transformation.
    ///
    /// - Parameter recordPath: the untrusted context-relative record path.
    /// - Returns: `true` when the path is a safe relative path, `false` otherwise.
    private static func isTraversalSafeRecordPath(_ recordPath: String) -> Bool {
        guard !recordPath.hasPrefix("/") else { return false }
        let components = recordPath.split(separator: "/", omittingEmptySubsequences: true)
        return !components.contains { unsafeRecordPathComponents.contains($0) }
    }

    /// Reduces an untrusted record path to a traversal-free relative string.
    ///
    /// Splits on `/` (dropping the leading slash of an absolute path and every
    /// empty component) and discards every ``unsafeRecordPathComponents`` (`.`
    /// and `..`), keeping only ordinary name components joined by `/`. The
    /// result is therefore never absolute and carries no `..`, so appended to
    /// any base directory it can never resolve outside that base — the safe
    /// fallback the session-root rebase relies on for hostile input. An input
    /// with no ordinary components (for example a bare `..`) reduces to the
    /// empty string, which resolves to the session root itself and so is still
    /// contained. Downstream this defused value is additionally bounded by
    /// ``PathGuard``'s workspace-boundary check, but its safety does not depend
    /// on that second layer.
    ///
    /// - Parameter recordPath: the untrusted record path to sanitize.
    /// - Returns: a leading-slash-free, `..`-free relative path.
    private static func sanitizedRelativePath(_ recordPath: String) -> String {
        recordPath
            .split(separator: "/", omittingEmptySubsequences: true)
            .filter { component in !unsafeRecordPathComponents.contains(component) }
            .joined(separator: "/")
    }

    // MARK: Skipped / degraded results

    /// An item-free ``FileDiagnostics`` carrying only `status` and `note`.
    ///
    /// The shared builder behind every result that reports no diagnostic items:
    /// a `skipped` gate outcome and a `pending` degraded outcome differ only in
    /// their status and note, so both route through here with zero errors, zero
    /// warnings, and no items.
    ///
    /// - Parameters:
    ///   - status: the wire status the result carries.
    ///   - note: the explanatory note for the status.
    /// - Returns: the item-free result.
    private static func emptyResult(status: DiagnosticsStatus, note: String) -> FileDiagnostics {
        FileDiagnostics(status: status.rawValue, errors: 0, warnings: 0, items: [], note: note)
    }

    /// A `skipped` ``FileDiagnostics`` carrying `note`.
    ///
    /// - Parameter note: the reason the file was skipped.
    /// - Returns: the skipped result.
    private static func skipped(note: String) -> FileDiagnostics {
        emptyResult(status: .skipped, note: note)
    }

    /// A `pending` ``FileDiagnostics`` degrading a failed diagnostics pass.
    ///
    /// - Parameter error: the error that prevented completion.
    /// - Returns: the degraded, pending result.
    private static func degraded(error: any Error) -> FileDiagnostics {
        let note = degradedNotePrefix + error.localizedDescription + degradedNoteSuffix
        return emptyResult(status: .pending, note: note)
    }

    // MARK: Gates

    /// Whether `fileURL`'s extension is handled by an LSP-backed language module.
    ///
    /// - Parameter fileURL: the file to check.
    /// - Returns: `true` when a running context could diagnose the file.
    private static func isDiagnosableExtension(_ fileURL: URL) -> Bool {
        let fileExtension = fileURL.pathExtension.lowercased()
        guard !fileExtension.isEmpty else {
            return false
        }
        return diagnosableExtensions.contains(fileExtension)
    }

    /// Whether the absolute path the bridge would hand upstream contains a glob metacharacter.
    ///
    /// Checks the *whole* path, not just the filename: the bridge passes
    /// `scope: .file(fileURL.path)` and upstream's glob detection scans the
    /// entire pattern string, so a metacharacter in any ancestor directory would
    /// trip the same glob expansion (and its false-`clean` hazard) as one in the
    /// filename.
    ///
    /// - Parameter fileURL: the file to check.
    /// - Returns: `true` when the absolute path carries `*`, `?`, or `[`.
    private static func containsGlobMetacharacter(_ fileURL: URL) -> Bool {
        fileURL.path.contains { character in globMetacharacters.contains(character) }
    }
}

// MARK: - Status wire names

/// The model-facing wire names of a ``FileDiagnostics`` status, as data.
///
/// A `String`-raw-valued enum so the status names live in one declaration and
/// are read via ``rawValue`` — matching the codebase's ``EditFile`` `StatusName`
/// and `ChangeName` idiom — rather than as string literals repeated across the
/// mapping.
private enum DiagnosticsStatus: String {
    /// No errors or warnings.
    case clean

    /// One or more errors.
    case errors

    /// Warnings but no errors.
    case warnings

    /// The report may be incomplete, or a diagnostics pass could not complete.
    case pending

    /// No diagnostics pass ran at all.
    case skipped
}
