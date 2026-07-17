import Foundation

/// The `sourcekit-lsp` availability gate for the real-LSP integration tier.
///
/// The two-faced gate the acceptance criteria require:
///
/// - **Locally**, when `xcrun --find sourcekit-lsp` fails, the real-LSP matrix
///   *skips* with a clear message (via a Swift Testing `.enabled(if:)` trait,
///   which reports a genuine skip rather than a vacuous pass).
/// - **In continuous integration** (the `CI` environment variable is set), a
///   missing `sourcekit-lsp` is a *failure*, never a silent skip — so the LSP
///   tier can never quietly vanish from CI. ``ContinuousIntegration`` enforces
///   that as an always-enabled test that records an issue when
///   ``isSourceKitLSPAvailable`` is false under CI.
enum LSPGate {
    /// The `xcrun` subcommand and tool name probed for availability.
    private static let sourceKitLSPToolName = "sourcekit-lsp"

    /// The skip message shown when the real-LSP matrix is disabled locally.
    static let skipMessage =
        "sourcekit-lsp not found (xcrun --find sourcekit-lsp failed); skipping the real-LSP integration matrix"

    /// Whether `sourcekit-lsp` resolves via `xcrun --find sourcekit-lsp`.
    ///
    /// Runs the exact probe the acceptance criteria name and treats a zero exit
    /// as available. A launch failure or non-zero exit reads as unavailable.
    ///
    /// - Returns: `true` when `xcrun --find sourcekit-lsp` exits zero.
    static var isSourceKitLSPAvailable: Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["xcrun", "--find", sourceKitLSPToolName]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// Whether the suite is running under continuous integration.
    ///
    /// True when the `CI` environment variable is present and non-empty — the
    /// convention GitHub Actions (and most other providers) set.
    ///
    /// - Returns: `true` when `CI` is set to a non-empty value.
    static var isRunningInContinuousIntegration: Bool {
        guard let value = ProcessInfo.processInfo.environment["CI"] else {
            return false
        }
        return !value.isEmpty
    }
}
