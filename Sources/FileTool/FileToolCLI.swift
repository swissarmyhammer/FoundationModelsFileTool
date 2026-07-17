import Foundation
import Operations
import OperationsCLI

/// The `file-demo` command-line wiring over the fused ``FileTool`` `files` tool.
///
/// This is the importable home for the CLI driver's convergence and
/// exit-code logic, so `main.swift` stays a thin entry point and the same code
/// path is exercised by the tests. The default `<noun> <verb>` grammar, the
/// argument parsing, and the dispatch are all the upstream
/// `OperationCLIDriver`'s — this type only supplies the fused tool, names the
/// executable, and adds the one behavior the stock driver leaves to its host:
/// mapping a corrective outcome to a non-zero exit code.
///
/// The driver reports every successful dispatch (including a corrective) with a
/// zero exit code and the dispatched op's output text. A typed operation output
/// encodes a corrective as a single `corrective` string field, so
/// ``resolveOutcome(output:exitCode:)`` recognizes that shape and re-maps it to
/// a non-zero exit carrying just the message; an ArgumentParser parse failure
/// (unknown noun/verb, missing or malformed parameter) already carries a
/// non-zero exit code and passes straight through.
public enum FileToolCLI {
    // MARK: Identity

    /// The executable name shown in usage and help text.
    public static let executableName = "file-demo"

    // MARK: Outcome

    /// The resolved result of one CLI invocation: the text to emit, whether it
    /// is an error (and so belongs on standard error), and the process exit code.
    public struct Outcome: Sendable, Equatable {
        /// The text to emit: an operation's JSON output, a corrective message,
        /// or ArgumentParser's own help/usage/error text.
        public let output: String

        /// Whether ``output`` is an error that belongs on standard error and
        /// pairs with a non-zero ``exitCode``.
        public let isError: Bool

        /// The process exit code a real executable should return.
        public let exitCode: Int32

        /// Creates a resolved outcome.
        ///
        /// - Parameters:
        ///   - output: the text to emit.
        ///   - isError: whether the outcome is an error.
        ///   - exitCode: the process exit code.
        public init(output: String, isError: Bool, exitCode: Int32) {
            self.output = output
            self.isError = isError
            self.exitCode = exitCode
        }
    }

    // MARK: Corrective mapping

    /// The single `corrective` field a typed operation output encodes a
    /// corrective outcome as — the marker ``resolveOutcome(output:exitCode:)``
    /// recognizes to re-map a zero-exit corrective to a non-zero exit.
    private static let correctiveKey = "corrective"

    /// The exit code returned for a corrective operation outcome.
    private static let correctiveExitCode: Int32 = 1

    // MARK: Running

    /// Drives `arguments` through an `OperationCLIDriver` over
    /// ``FileTool/make(context:)`` and resolves the driver result into an
    /// ``Outcome``.
    ///
    /// - Parameters:
    ///   - arguments: the command's arguments, excluding the executable name
    ///     (i.e. `CommandLine.arguments.dropFirst()`).
    ///   - context: the session context the operations dispatch against; its
    ///     ``FileContext/root`` bounds every path.
    /// - Returns: the resolved ``Outcome`` to print and exit with.
    /// - Throws: `OperationCLIDriverError` if the fused tool cannot be assembled
    ///   into a driver (not expected for this fixed five-op tool); rethrows any
    ///   error ``FileTool/make(context:)`` throws while fusing the schema.
    public static func run(arguments: [String], context: FileContext) async throws -> Outcome {
        let tool = try FileTool.make(context: context)
        let driver = try OperationCLIDriver(tool: tool, executableName: executableName)
        let result = await driver.run(arguments: arguments)
        return resolveOutcome(output: result.output, exitCode: result.exitCode)
    }

    /// Resolves a driver result into a printable ``Outcome``, mapping a
    /// corrective operation output to a non-zero exit.
    ///
    /// An already-non-zero exit code (an ArgumentParser parse failure) passes
    /// through as an error unchanged. A zero exit whose `output` is a typed
    /// corrective (a JSON object carrying a ``correctiveKey`` string) becomes an
    /// error at ``correctiveExitCode`` carrying just the message. Any other
    /// zero-exit output — a successful op's JSON, help, usage, or a completion
    /// script — passes through as a success.
    ///
    /// - Parameters:
    ///   - output: the driver's output text.
    ///   - exitCode: the driver's exit code.
    /// - Returns: the resolved ``Outcome``.
    ///
    /// - Note: `OperationTool.call` has a *second* corrective channel — plain,
    ///   non-JSON strings for `unknownOperation`, `missingRequired`,
    ///   `decodingFailed`, and its retry-cap terminal message — that this
    ///   mapping does not re-map to a non-zero exit. That channel is structurally
    ///   unreachable through this CLI for the fused ``FileTool`` ops: every op is
    ///   macro-generated, so ArgumentParser enforces each required parameter
    ///   (a missing one is a parse failure with a non-zero exit *before*
    ///   dispatch), builds a correctly typed payload (no `decodingFailed`), and
    ///   only ever produces a leaf for a registered op (no `unknownOperation`,
    ///   so no retry-cap terminal message). Each op routes its own recoverable
    ///   failures through the typed ``correctiveKey`` output instead. A future op
    ///   that reaches the string channel (e.g. a macro-less fallback leaf) would
    ///   need this mapping extended.
    static func resolveOutcome(output: String, exitCode: Int32) -> Outcome {
        guard exitCode == 0 else {
            return Outcome(output: output, isError: true, exitCode: exitCode)
        }
        if let message = correctiveMessage(in: output) {
            return Outcome(output: message, isError: true, exitCode: correctiveExitCode)
        }
        return Outcome(output: output, isError: false, exitCode: 0)
    }

    /// The corrective message carried by `output`, or `nil` when `output` is not
    /// a typed corrective.
    ///
    /// `output` is a corrective exactly when it parses as a JSON object with a
    /// ``correctiveKey`` string value; no successful operation output encodes
    /// such a top-level field, and non-JSON text (help, usage) never parses,
    /// so this cleanly separates correctives from every other zero-exit output.
    ///
    /// - Parameter output: the driver's output text.
    /// - Returns: the corrective message, or `nil` when `output` is not a
    ///   corrective.
    private static func correctiveMessage(in output: String) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any],
            let message = object[correctiveKey] as? String
        else {
            return nil
        }
        return message
    }
}
