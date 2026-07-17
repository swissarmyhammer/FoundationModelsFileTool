import FoundationModels
import Foundation

/// The `file-demo --script` mode: executes a sequence of JSON operation payloads
/// against a shared ``FileContext`` in one process, emitting each operation's
/// typed JSON output as it is produced.
///
/// This is the human-driven twin of the integration suite. Where those tests
/// build a `GeneratedContent` payload in Swift and dispatch it through the fused
/// ``FileTool`` `files` tool, script mode reads the identical payloads as JSON
/// lines — from a human, or piped in — and routes each through the same
/// `OperationTool.call(arguments:)` dispatch a `LanguageModelSession` and the CLI
/// driver use. A scripted `read → edit → read` sequence therefore exercises the
/// exact `AnyOperation` convergence path a live model would, without an Apple
/// Intelligence device.
///
/// The logic lives here in the `FileTool` library, not the `file-demo`
/// executable, so it is importable and testable directly (the executable's
/// `main` only reads standard input, calls ``run(lines:context:emit:)``, and
/// prints each emitted output).
public enum FileToolScript {
    /// Executes each JSON operation line in `lines` sequentially against
    /// `context`, passing the fused tool's output for each to `emit` as it is
    /// produced.
    ///
    /// Blank and whitespace-only lines are ignored, so a piped heredoc's trailing
    /// newline never produces a spurious output. Every other line is parsed as a
    /// `GeneratedContent` operation payload and dispatched through
    /// ``FileTool/make(context:)``'s fused `files` tool — the same `AnyOperation`
    /// path the CLI driver and a `LanguageModelSession` use — so each string
    /// handed to `emit` is that operation's JSON-encoded typed output, or the
    /// corrective message the tool returns in place of one.
    ///
    /// `emit` is called for each output *before the next line is dispatched*, so a
    /// caller that prints from it sees every completed operation's result even
    /// when a later line aborts the run — the ops already applied are never
    /// silently swallowed. A malformed line therefore aborts the run only after
    /// the preceding operations' outputs have been emitted (and their side
    /// effects committed).
    ///
    /// - Parameters:
    ///   - lines: the operation payload lines, one JSON object per line.
    ///   - context: the shared session context every operation dispatches
    ///     against; its ``FileContext/root`` bounds every path.
    ///   - emit: invoked with each non-blank line's output, in input order, as it
    ///     is produced.
    /// - Throws: ``ScriptModeError/malformedPayload(line:underlyingError:)`` when a
    ///   line is not parseable as a JSON operation payload; rethrows
    ///   `OperationError` when a dispatched operation's own execution or output
    ///   encoding fails; rethrows whatever ``FileTool/make(context:)`` throws while
    ///   fusing the tool.
    public static func run(lines: [String], context: FileContext, emit: (String) -> Void) async throws {
        let tool = try FileTool.make(context: context)
        for line in lines {
            guard let payload = try parsePayload(from: line) else {
                continue
            }
            emit(try await tool.call(arguments: payload))
        }
    }

    /// Parses one stdin line into an operation payload, skipping blank lines.
    ///
    /// - Parameter line: the raw stdin line.
    /// - Returns: the parsed payload, or `nil` when `line` is blank or
    ///   whitespace-only.
    /// - Throws: ``ScriptModeError/malformedPayload(line:underlyingError:)`` when a
    ///   non-blank line is not parseable as a JSON operation payload.
    private static func parsePayload(from line: String) throws -> GeneratedContent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        do {
            return try GeneratedContent(json: trimmed)
        } catch {
            throw ScriptModeError.malformedPayload(line: line, underlyingError: error)
        }
    }
}

/// A failure running the `file-demo --script` mode.
public enum ScriptModeError: Error, CustomStringConvertible {
    /// A standard-input line was not parseable as a JSON operation payload.
    ///
    /// - Parameters:
    ///   - line: the offending line, verbatim.
    ///   - underlyingError: the JSON-parsing error `GeneratedContent(json:)` threw.
    case malformedPayload(line: String, underlyingError: any Error)

    /// A human-readable description naming the offending line and its cause.
    public var description: String {
        switch self {
        case .malformedPayload(let line, let underlyingError):
            return "Malformed operation payload (expected one JSON object per line): \(line) — \(underlyingError)"
        }
    }
}
