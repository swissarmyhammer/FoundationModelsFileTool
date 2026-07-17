// `file-demo` — example executable exercising the fused `files` tool through
// the upstream `OperationCLIDriver`'s default `<noun> <verb>` command grammar.
//
// The convergence and exit-code logic lives in `FileToolCLI` (in the `FileTool`
// library) so it stays importable and testable; this entry point only builds
// the session context, forwards the arguments, and prints/exits with the
// resolved outcome. The scripted `--chat` / `--script` modes are a later task.
import FileTool
import Foundation

// The exit code for a fatal failure the CLI could not turn into a resolved
// outcome — the driver could not be assembled or the fused tool's schema failed
// to build. Distinct from `FileToolCLI`'s own corrective/parse exit codes, which
// ride on a resolved `Outcome`.
let fatalExitCode: Int32 = 1

let arguments = Array(CommandLine.arguments.dropFirst())

// The session root is the current working directory: every operation's paths
// are bounded to it by the `FileContext`'s `PathGuard`, matching how a shell
// user expects `file-demo file read --path …` to resolve against where they
// invoked it.
let context = FileContext(root: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))

do {
    let outcome = try await FileToolCLI.run(arguments: arguments, context: context)
    if !outcome.output.isEmpty {
        if outcome.isError {
            FileHandle.standardError.write(Data((outcome.output + "\n").utf8))
        } else {
            print(outcome.output)
        }
    }
    if outcome.exitCode != 0 {
        exit(outcome.exitCode)
    }
} catch {
    FileHandle.standardError.write(Data("\(FileToolCLI.executableName): \(error)\n".utf8))
    exit(fatalExitCode)
}
