// `file-demo` — example executable exercising the fused `files` tool in three
// modes selected by the first argument:
//
// - default (no mode flag): the upstream `OperationCLIDriver`'s `<noun> <verb>`
//   command grammar, e.g. `file-demo file read --path …`. Convergence and
//   exit-code logic live in `FileToolCLI` (in the `FileTool` library).
// - `--script`: reads op lines (JSON payloads) from standard input and executes
//   them sequentially in one process against the demo's `FileContext`, printing
//   each op's typed JSON output — the human-driven twin of the integration
//   tests. The loop lives in `FileTool.FileToolScript` so it stays importable
//   and testable; this entry point only reads stdin, calls it, and prints.
// - `--chat`: a `LanguageModelSession` with the fused tool, availability-gated so
//   it skips cleanly (and never fails the build or tests) on a machine without
//   Apple Intelligence — see `ChatValidationHarness`.
//
// Every mode roots its `FileContext` at the current working directory: the
// `PathGuard` bounds each operation's paths to it, matching how a shell user
// expects paths to resolve against where they invoked the tool.
import FileTool
import Foundation

// The mode-selecting first-argument flags are single-sourced on `FileToolCLI`
// (alongside `executableName`), so this dispatch and the tests that spawn the
// executable name the same strings.

// The exit code for a fatal failure a mode could not turn into a resolved
// outcome — the driver could not be assembled, the fused tool's schema failed to
// build, or a script line could not be parsed or dispatched. Distinct from
// `FileToolCLI`'s own corrective/parse exit codes, which ride on a resolved
// `Outcome`.
let fatalExitCode: Int32 = 1

let arguments = Array(CommandLine.arguments.dropFirst())
let context = FileContext(root: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))

switch arguments.first {
case FileToolCLI.scriptModeFlag:
    await runScriptMode(context: context)
case FileToolCLI.chatModeFlag:
    // Chat mode scaffolds its own throwaway workspace, so it never mutates the
    // caller's working directory (unlike the CLI/script modes, which act on it).
    await ChatValidationHarness.run()
default:
    await runCLIMode(arguments: arguments, context: context)
}

/// Reads JSON op lines from standard input, executes them against `context`, and
/// prints each op's typed JSON output; a fatal failure exits non-zero.
///
/// - Parameter context: the session context every op dispatches against.
func runScriptMode(context: FileContext) async {
    let input = readStandardInput()
    let lines = input.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    do {
        try await FileToolScript.run(lines: lines, context: context) { output in
            print(output)
        }
    } catch {
        writeStandardError("\(FileToolCLI.executableName): \(error)")
        exit(fatalExitCode)
    }
}

/// Drives `arguments` through the `FileToolCLI` command-line grammar, printing
/// its resolved outcome and exiting with its code.
///
/// - Parameters:
///   - arguments: the command's arguments; no mode flag is present (the dispatch
///     above already routed those away), so these are the plain `<noun> <verb>`
///     grammar arguments.
///   - context: the session context every op dispatches against.
func runCLIMode(arguments: [String], context: FileContext) async {
    do {
        let outcome = try await FileToolCLI.run(arguments: arguments, context: context)
        if !outcome.output.isEmpty {
            if outcome.isError {
                writeStandardError(outcome.output)
            } else {
                print(outcome.output)
            }
        }
        if outcome.exitCode != 0 {
            exit(outcome.exitCode)
        }
    } catch {
        writeStandardError("\(FileToolCLI.executableName): \(error)")
        exit(fatalExitCode)
    }
}

/// Reads all of standard input as UTF-8 text.
///
/// - Returns: the decoded standard-input contents.
func readStandardInput() -> String {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    return String(decoding: data, as: UTF8.self)
}

/// Writes `message` and a trailing newline to standard error.
///
/// - Parameter message: the text to write.
func writeStandardError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}
