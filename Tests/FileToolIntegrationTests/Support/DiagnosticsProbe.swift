import Foundation
import FoundationModels
import Operations

@testable import FileTool

/// Helpers that drive the fused `files` tool through full `AnyOperation` dispatch
/// and read the compiler diagnostics back out — both from a single dispatched
/// operation's JSON output and by bounded-polling the real bridge until the
/// diagnostics settle.
///
/// Every matrix row mutates through ``callTool(_:arguments:)`` (proving the
/// diagnostics ride back through the operation output), then, because a real
/// language server settles on its own wall-clock and must never be raced with a
/// timing assertion, converges on the settled result through
/// ``awaitDiagnostics(from:fileAt:deadline:pollInterval:until:)`` (which polls the
/// identical production bridge the operation itself used).
enum DiagnosticsProbe {
    // MARK: - Deadlines

    /// The generous overall deadline a warm-context row polls a real language
    /// server to a settled result within.
    ///
    /// Deliberately far larger than any single settle window: the bridge's own
    /// hard timeout bounds one diagnostics pass, while this bounds the *poll* of
    /// repeated passes, so a slow-but-correct server still converges without a
    /// timing assertion.
    static let settleDeadline: Duration = .seconds(120)

    /// The interval between diagnostics polls.
    static let pollInterval: Duration = .milliseconds(500)

    // MARK: - Payload building

    /// Builds a `GeneratedContent` payload from ordered key/value entries.
    ///
    /// - Parameter entries: the payload's properties, in order; a later duplicate
    ///   key wins.
    /// - Returns: the assembled structure payload.
    static func payload(_ entries: [(String, any ConvertibleToGeneratedContent)]) -> GeneratedContent {
        GeneratedContent(properties: entries, uniquingKeysWith: { _, new in new })
    }

    // MARK: - Dispatch

    /// Dispatches `arguments` through the fused tool and returns its JSON output.
    ///
    /// - Parameters:
    ///   - tool: the fused `files` tool to dispatch against.
    ///   - arguments: the operation payload.
    /// - Returns: the operation's JSON-encoded output.
    /// - Throws: rethrows a fatal `OperationError` from the dispatched operation.
    static func callTool(
        _ tool: OperationTool<FileContext>,
        arguments: GeneratedContent
    ) async throws -> String {
        try await tool.call(arguments: arguments)
    }

    /// Decodes the `diagnostics` object folded into a `write file` / `edit file`
    /// operation's JSON output, or `nil` when the output carries none.
    ///
    /// - Parameter toolOutput: the operation's JSON-encoded output.
    /// - Returns: the decoded diagnostics, or `nil` when absent (a corrective
    ///   output, or a decode failure).
    static func diagnostics(fromToolOutput toolOutput: String) -> DecodedDiagnostics? {
        guard let data = toolOutput.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(DecodedMutationOutput.self, from: data).diagnostics
    }

    // MARK: - Polling

    /// Polls the real bridge for `fileURL`'s diagnostics until `predicate` holds
    /// or `deadline` elapses, returning the last observed result.
    ///
    /// The bridge polled is the very one the dispatched operation used, so this
    /// converges on the same production diagnostics path a model would see —
    /// only bounded by a generous wall-clock deadline rather than a timing
    /// assertion, so a slow real language server still settles deterministically.
    ///
    /// - Parameters:
    ///   - bridge: the production diagnostics bridge to poll.
    ///   - fileURL: the mutated file to diagnose.
    ///   - deadline: the overall time budget before giving up.
    ///   - pollInterval: how long to sleep between polls.
    ///   - predicate: the settled condition to poll toward.
    /// - Returns: the last observed diagnostics (satisfying `predicate` if it
    ///   converged within `deadline`), or `nil` if the bridge never produced one.
    static func awaitDiagnostics(
        from bridge: DiagnosticsBridge,
        fileAt fileURL: URL,
        deadline: Duration = DiagnosticsProbe.settleDeadline,
        pollInterval: Duration = DiagnosticsProbe.pollInterval,
        until predicate: (FileDiagnostics) -> Bool
    ) async -> FileDiagnostics? {
        let clock = ContinuousClock()
        let end = clock.now.advanced(by: deadline)
        var lastResult: FileDiagnostics?
        while true {
            if let result = await bridge.diagnose(fileAt: fileURL) {
                lastResult = result
                if predicate(result) {
                    return result
                }
            }
            guard clock.now < end else {
                return lastResult
            }
            try? await Task.sleep(for: pollInterval)
        }
    }
}

// MARK: - Decoded operation output

/// The `diagnostics` object decoded from a `write file` / `edit file` operation's
/// JSON output.
///
/// A `Decodable` mirror of the operation's own `Encodable` output: the operations
/// only encode, so a decode-side mirror is what lets a test read the diagnostics
/// back out of the dispatched JSON and assert the operation actually carried
/// them.
struct DecodedMutationOutput: Decodable {
    /// The folded diagnostics, or `nil` when the output carried none.
    let diagnostics: DecodedDiagnostics?
}

/// A `Decodable` mirror of `FileDiagnostics` for reading an operation's output.
struct DecodedDiagnostics: Decodable {
    /// The whole-result status: `clean`, `errors`, `warnings`, `pending`, or `skipped`.
    let status: String

    /// The true number of error-severity diagnostics.
    let errors: Int

    /// The true number of warning-severity diagnostics.
    let warnings: Int

    /// The per-diagnostic detail, capped to the bridge's item limit.
    let items: [DecodedDiagnosticItem]

    /// The note explaining a `pending` / `skipped` status, or `nil`.
    let note: String?
}

/// A `Decodable` mirror of `DiagnosticItem` for reading an operation's output.
struct DecodedDiagnosticItem: Decodable {
    /// The file the diagnostic applies to, relative to the session root.
    let file: String

    /// The one-based line the diagnostic starts on.
    let line: Int

    /// The one-based column the diagnostic starts on.
    let column: Int

    /// The diagnostic's severity.
    let severity: String

    /// The human-readable diagnostic message.
    let message: String

    /// The language server's diagnostic code, or `nil`.
    let code: String?
}
