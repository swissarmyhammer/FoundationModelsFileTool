import FileTool
import Foundation
import FoundationModels
import Operations

/// Drives the scripted live-model validation `file-demo --chat` runs, per
/// plan.md §7: it registers the fused `files` tool on a `LanguageModelSession`
/// and walks a real, scripted loop — read a file, edit it by a lifted hashline
/// anchor and see the diagnostics come back `clean`, then deliberately make a
/// type-breaking edit so the model sees the compiler error folded into the tool
/// result and is nudged to fix it — while reporting op-call accuracy, the
/// rendered tool-schema size via `tokenCount(for:)`, and the retry-cap behavior
/// on a denied path (`../../etc/passwd`).
///
/// **Manual-run only, never part of `swift test`.** It needs an Apple
/// Intelligence-enabled device, which continuous integration does not have, so
/// ``run()`` gates on `SystemLanguageModel` availability and degrades to a clear
/// skip message (and a clean exit) off-device rather than failing. Because
/// `FoundationModels` is present at compile time on the macOS 27 SDK, this file
/// builds — and the whole test suite runs — on a machine without Apple
/// Intelligence; only the live walk below is gated at runtime.
///
/// The harness scaffolds its own throwaway Swift package under the process
/// temporary directory and tears it down afterward, so it never touches the
/// caller's working directory.
internal enum ChatValidationHarness {
    // MARK: - Scripted inputs

    /// One scripted prompt and the fused-tool op it should be dispatched to.
    private struct ScriptedPrompt {
        /// The natural-language prompt sent to the model.
        let prompt: String

        /// The `"verb noun"` op string the model is expected to dispatch.
        let expectedOpString: String
    }

    /// The instructions the harness's `LanguageModelSession` runs under.
    private static let sessionInstructions =
        "You edit source files using the files tool. Always use the tool for file operations, "
        + "and prefer editing by the hashline anchors a read returns."

    /// The number of times the denied-path request is repeated to observe the
    /// fused tool's retry cap give way from a corrective to its terminal message.
    private static let retryCapProbeAttempts = 3

    /// A denied relative path that escapes the session root, for the retry-cap probe.
    private static let deniedPath = "../../etc/passwd"

    // MARK: - Entry point

    /// Runs the live-model validation if `SystemLanguageModel` is available on
    /// this device, otherwise prints a skip message explaining why.
    ///
    /// Never throws and always exits cleanly: an unavailable model, or any error
    /// during the live walk, is reported and swallowed so the manual run degrades
    /// gracefully instead of crashing.
    internal static func run() async {
        switch SystemLanguageModel.default.availability {
        case .available:
            await runValidation()
        case .unavailable(let reason):
            print("Foundation Models unavailable on this device (\(describe(reason))); skipping live validation.")
        @unknown default:
            print("Foundation Models availability is unknown on this device; skipping live validation.")
        }
    }

    /// Human-readable phrases describing each reason the system model is
    /// unavailable, keyed on the reason so ``describe(_:)`` is a single table
    /// lookup rather than parallel `switch` arms that differ only by their string.
    private static let unavailabilityDescriptions: [SystemLanguageModel.Availability.UnavailableReason: String] = [
        .deviceNotEligible: "device not eligible",
        .appleIntelligenceNotEnabled: "Apple Intelligence not enabled",
        .modelNotReady: "model not ready",
    ]

    /// A human-readable description of why the model is unavailable.
    ///
    /// - Parameter reason: the unavailability reason reported by the system model.
    /// - Returns: a short phrase naming the reason, or `"unknown reason"` for any
    ///   reason absent from ``unavailabilityDescriptions`` (including future cases).
    private static func describe(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        unavailabilityDescriptions[reason] ?? "unknown reason"
    }

    // MARK: - Validation stages

    /// Scaffolds a workspace, builds the fused tool over it, and runs every
    /// reporting stage in turn, tearing the workspace and context down afterward.
    private static func runValidation() async {
        do {
            let workspace = try Workspace.scaffold()
            defer { workspace.remove() }

            let context = FileContext(root: workspace.root, eagerWarmup: true)
            let tool = try FileTool.make(context: context)
            do {
                try await reportSchemaTokenCount(tool: tool)
                let session = LanguageModelSession(tools: [tool], instructions: sessionInstructions)
                await reportOpCallAccuracy(session: session, tool: tool, workspace: workspace)
                await driveTypeBreakingEditAndFix(session: session, workspace: workspace)
                await probeRetryCapBehavior(session: session, workspace: workspace)
            } catch {
                await context.stop()
                throw error
            }
            await context.stop()
        } catch {
            print("Live validation failed: \(error)")
        }
    }

    /// Prints the fused tool's rendered schema size via `tokenCount(for:)`.
    ///
    /// - Parameter tool: the fused `files` tool whose schema size to measure.
    /// - Throws: rethrows from `SystemLanguageModel.tokenCount(for:)`.
    private static func reportSchemaTokenCount(tool: OperationTool<FileContext>) async throws {
        let tokenCount = try await SystemLanguageModel.default.tokenCount(for: [tool])
        print("Fused '\(tool.name)' tool rendered-schema token count: \(tokenCount)")
    }

    /// Sends the read and edit-by-anchor scripted prompts and reports how many
    /// dispatched their expected op, and whether the edit settled `clean`.
    ///
    /// - Parameters:
    ///   - session: the session to drive.
    ///   - tool: the fused tool, to find its calls in the transcript.
    ///   - workspace: the scaffolded workspace the prompts act on.
    private static func reportOpCallAccuracy(
        session: LanguageModelSession,
        tool: OperationTool<FileContext>,
        workspace: Workspace
    ) async {
        let scriptedPrompts = [
            ScriptedPrompt(
                prompt: "Read the file \(workspace.demoRelativePath) and show me its contents with their anchors.",
                expectedOpString: ReadFile.opString
            ),
            ScriptedPrompt(
                prompt: "In \(workspace.demoRelativePath), change the returned value from 1 to 2 by editing the anchored line.",
                expectedOpString: EditFile.opString
            ),
        ]

        var matched = 0
        for scripted in scriptedPrompts where await evaluate(scripted, session: session, tool: tool) {
            matched += 1
        }
        print("Op-call accuracy: \(matched)/\(scriptedPrompts.count) scripted prompts dispatched the expected op.")
    }

    /// Sends one scripted prompt and reports whether the dispatched op matched.
    ///
    /// - Parameters:
    ///   - scripted: the prompt and its expected op string.
    ///   - session: the session to send the prompt to.
    ///   - tool: the fused tool, to find its call in the transcript.
    /// - Returns: whether the dispatched op matched `scripted.expectedOpString`.
    private static func evaluate(
        _ scripted: ScriptedPrompt,
        session: LanguageModelSession,
        tool: OperationTool<FileContext>
    ) async -> Bool {
        do {
            _ = try await session.respond(to: scripted.prompt)
            let actual = lastToolCallOpString(in: session.transcript, toolName: tool.name)
            let matched = actual == scripted.expectedOpString
            print("[\(matched ? "OK" : "MISS")] \"\(scripted.prompt)\" -> expected '\(scripted.expectedOpString)', got '\(actual ?? "none")'")
            return matched
        } catch {
            print("[ERROR] \"\(scripted.prompt)\" -> \(error)")
            return false
        }
    }

    /// Asks for an edit that breaks the file's type so the model sees the
    /// compiler error folded into the tool result, then nudges it to fix it.
    ///
    /// - Parameters:
    ///   - session: the session to drive.
    ///   - workspace: the scaffolded workspace the edits act on.
    private static func driveTypeBreakingEditAndFix(session: LanguageModelSession, workspace: Workspace) async {
        print("Type-breaking edit: asking for an edit that will not type-check.")
        await respond(
            to: "Read \(workspace.demoRelativePath), then edit it so the line `    return 1` becomes exactly `    return \"two\"`. After the edit, tell me exactly what the tool's diagnostics field reported.",
            with: session
        )
        await respond(
            to: "The compiler reported a type error. Fix \(workspace.demoRelativePath) so it type-checks again and confirm the diagnostics are clean.",
            with: session
        )
    }

    /// Sends the denied-path request `retryCapProbeAttempts` times in a row,
    /// printing each response so a human can watch the corrective messages give
    /// way to the retry cap's terminal message and the model correct course.
    ///
    /// - Parameters:
    ///   - session: the session to send the probe requests to.
    ///   - workspace: the scaffolded workspace the valid follow-up read acts on.
    private static func probeRetryCapBehavior(session: LanguageModelSession, workspace: Workspace) async {
        print("Retry-cap probe: requesting a denied path (\(deniedPath)) \(retryCapProbeAttempts) times in a row.")
        for attempt in 1...retryCapProbeAttempts {
            await respond(to: "Read the file at the path \(deniedPath).", with: session, label: "attempt \(attempt)")
        }
        print("Corrective recovery: asking the model to read an allowed path instead.")
        await respond(to: "That path was denied. Read \(workspace.demoRelativePath) instead.", with: session)
    }

    /// Sends one prompt and prints the model's response (or the error thrown).
    ///
    /// - Parameters:
    ///   - prompt: the natural-language prompt.
    ///   - session: the session to send the prompt to.
    ///   - label: an optional prefix identifying the exchange in the log.
    private static func respond(to prompt: String, with session: LanguageModelSession, label: String? = nil) async {
        let prefix = label.map { "[\($0)] " } ?? ""
        do {
            let response = try await session.respond(to: prompt)
            print("\(prefix)model: \(response)")
        } catch {
            print("\(prefix)session threw: \(error)")
        }
    }

    /// The `op` argument of the most recent call to the tool named `toolName`.
    ///
    /// - Parameters:
    ///   - transcript: the session transcript to search.
    ///   - toolName: the tool name to match against `Transcript.ToolCall.toolName`.
    /// - Returns: the last dispatched op string, or `nil` when the transcript
    ///   holds no matching call.
    private static func lastToolCallOpString(in transcript: Transcript, toolName: String) -> String? {
        var lastMatch: String?
        for entry in transcript {
            guard case .toolCalls(let calls) = entry else { continue }
            for call in calls where call.toolName == toolName {
                lastMatch = try? call.arguments.value(String.self, forProperty: OperationKeys.opFieldName)
            }
        }
        return lastMatch
    }
}

// MARK: - Throwaway workspace

/// A scaffolded, throwaway Swift package the chat harness reads, edits, and
/// diagnoses, so a live model exercises the real read → edit → diagnostics loop
/// against build-graph-resolvable sources without touching the caller's tree.
private struct Workspace {
    /// The package root, also the diagnostics session root and the `git` root.
    let root: URL

    /// The demo source file's path relative to ``root``, as the prompts name it.
    let demoRelativePath: String

    /// The scaffolded package's package and target name, single-sourced so the
    /// manifest and source paths below stay in lockstep.
    private static let targetName = "Demo"

    /// The demo source file's manifest-relative location.
    private static let demoPathComponents = ["Sources", targetName, "\(targetName).swift"]

    /// The `Package.swift` a real `sourcekit-lsp` needs to resolve the build graph.
    private static var manifest: String {
        """
        // swift-tools-version: 6.0
        import PackageDescription

        let package = Package(
            name: "\(targetName)",
            targets: [.target(name: "\(targetName)")]
        )
        """
    }

    /// The seed source file: a single function returning an `Int`, so a later
    /// edit to a `String` is a clear type error a real compiler reports.
    private static let demoSource = """
        func demoValue() -> Int {
            return 1
        }
        """

    /// Scaffolds a fresh package under the process temporary directory.
    ///
    /// - Returns: the scaffolded workspace handle.
    /// - Throws: a file-write or `git` error if scaffolding fails.
    fileprivate static func scaffold() throws -> Workspace {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileDemoChat-\(UUID().uuidString)", isDirectory: true)
        let demoRelativePath = demoPathComponents.joined(separator: "/")
        let demoFile = demoPathComponents.reduce(root) { $0.appendingPathComponent($1) }

        try write(manifest, to: root.appendingPathComponent("Package.swift"))
        try write(demoSource, to: demoFile)
        try initializeGitRepository(at: root)
        return Workspace(root: root, demoRelativePath: demoRelativePath)
    }

    /// Removes the scaffolded package tree, ignoring a not-found tree.
    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    /// Writes `contents` as UTF-8 to `fileURL`, creating parent directories.
    ///
    /// - Parameters:
    ///   - contents: the UTF-8 text to write.
    ///   - fileURL: the destination file URL.
    /// - Throws: a file-system error if the directory or file cannot be created.
    private static func write(_ contents: String, to fileURL: URL) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: fileURL)
    }

    /// Initializes a `git` repository at `root` with one initial commit, so the
    /// diagnostics manager can discover the package as a workspace.
    ///
    /// - Parameter root: the package root to initialize.
    /// - Throws: rethrows a process-launch error.
    private static func initializeGitRepository(at root: URL) throws {
        let identity = ["-c", "user.name=FileDemo Chat", "-c", "user.email=chat@example.invalid"]
        try runGit(["init", "--quiet"], in: root)
        try runGit(identity + ["add", "--all"], in: root)
        try runGit(identity + ["commit", "--quiet", "--message", "Initial scaffold"], in: root)
    }

    /// Runs `git` with `arguments` in `directory`, ignoring its exit status.
    ///
    /// - Parameters:
    ///   - arguments: the `git` arguments, excluding the `git` executable.
    ///   - directory: the working directory to run in.
    /// - Throws: rethrows a process-launch error.
    private static func runGit(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
    }
}
