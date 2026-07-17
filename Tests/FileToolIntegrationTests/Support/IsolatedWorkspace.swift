import Foundation

/// Shared scaffolding for the isolated-directory integration tier: fresh
/// temporary workspaces and a minimal, compiling Swift package a real
/// `sourcekit-lsp` can diagnose.
///
/// This mirrors the unit tier's `TestSupport` temp-directory helper, but is a
/// separate copy on purpose: `TestSupport` lives in the `FileToolTests` target,
/// and a SwiftPM test target is its own module that a sibling test target cannot
/// import, so the shared helper does not "fit" across the target boundary. The
/// one temp-directory primitive is kept byte-identical in spirit (unique name
/// under the process temp directory, operating-system reclaimed) so the two
/// tiers behave the same way on disk.
enum IsolatedWorkspace {
    // MARK: - Temporary directories

    /// Creates a fresh, empty temporary directory and returns its URL.
    ///
    /// The directory is created under the process temporary directory with a
    /// unique name so concurrent tests never collide; the operating system
    /// reclaims the temporary tree regardless of per-test cleanup.
    ///
    /// - Parameter name: a human-readable prefix identifying the caller on disk.
    /// - Returns: the URL of the freshly created temporary directory.
    static func makeTemporaryDirectory(named name: String) throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// Removes a directory tree, ignoring a not-found tree.
    ///
    /// - Parameter directory: the directory to remove.
    static func remove(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Runs `body` against a fresh temporary workspace, removing it afterward.
    ///
    /// The workspace is created before `body` runs and removed on every exit
    /// path (success or throw), so a scoped test never leaves a temporary tree
    /// behind.
    ///
    /// - Parameters:
    ///   - name: a human-readable prefix identifying the caller on disk.
    ///   - body: the work to run against the workspace root.
    /// - Returns: `body`'s result.
    /// - Throws: rethrows whatever creating the workspace or `body` throws.
    @discardableResult
    static func withIsolatedWorkspace<T>(
        named name: String = "IsolatedWorkspace",
        _ body: (URL) async throws -> T
    ) async throws -> T {
        let root = try makeTemporaryDirectory(named: name)
        defer { remove(root) }
        return try await body(root)
    }

    // MARK: - Scaffolded Swift package

    /// Runs `body` against a fresh scaffolded, compiling Swift package, removing
    /// it afterward.
    ///
    /// The package is scaffolded (via ``scaffoldSwiftPackage(named:)``) before
    /// `body` runs and removed on every exit path, so a scoped test never leaves
    /// a package tree behind.
    ///
    /// - Parameters:
    ///   - name: a human-readable prefix identifying the caller on disk.
    ///   - body: the work to run against the scaffolded package.
    /// - Returns: `body`'s result.
    /// - Throws: rethrows whatever scaffolding or `body` throws.
    @discardableResult
    static func withIsolatedSwiftPackage<T>(
        named name: String = "IsolatedSwiftPackage",
        _ body: (ScaffoldedSwiftPackage) async throws -> T
    ) async throws -> T {
        let package = try scaffoldSwiftPackage(named: name)
        defer { remove(package.root) }
        return try await body(package)
    }

    /// Scaffolds a fresh, minimal, compiling Swift package with a `git` history.
    ///
    /// The package is deliberately split into one small library target per
    /// error-detection matrix row (plus one target holding a provider/caller
    /// pair for the dependent-breakage row), so a mutation that breaks one row's
    /// file can never leak errors into another row's target — the suite stays
    /// order-independent and non-flaky even though every row shares one warm
    /// context. Every seed file compiles cleanly, so the whole package builds and
    /// a real `sourcekit-lsp` reports it clean at warm-up.
    ///
    /// The caller owns the returned package's lifetime and must
    /// ``IsolatedWorkspace/remove(_:)`` its ``ScaffoldedSwiftPackage/root`` when
    /// finished (or use ``withIsolatedSwiftPackage(named:_:)`` for scoped
    /// cleanup).
    ///
    /// - Parameter name: a human-readable prefix identifying the package on disk.
    /// - Returns: the scaffolded package's paths.
    /// - Throws: a file-write or `git` error if scaffolding fails.
    static func scaffoldSwiftPackage(named name: String) throws -> ScaffoldedSwiftPackage {
        let root = try makeTemporaryDirectory(named: name)
        try write(PackageSources.manifest, to: root.appendingPathComponent("Package.swift"))
        for seed in PackageSources.seedFiles {
            try write(seed.contents, to: root.appendingPathComponent(seed.relativePath))
        }
        try initializeGitRepository(at: root)
        return ScaffoldedSwiftPackage(root: root)
    }

    // MARK: - File writing

    /// Writes `contents` as UTF-8 to `fileURL`, creating parent directories.
    ///
    /// - Parameters:
    ///   - contents: the UTF-8 text to write.
    ///   - fileURL: the destination file URL.
    /// - Throws: a file-system error if the directory or file cannot be created.
    static func write(_ contents: String, to fileURL: URL) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: fileURL)
    }

    // MARK: - Git

    /// The `git` user identity the initial commit is attributed to.
    ///
    /// A fixed, self-contained identity passed per-invocation with `-c` so the
    /// scaffolding never depends on (or mutates) the machine's global `git`
    /// configuration.
    private static let gitIdentityArguments = [
        "-c", "user.name=FileTool Integration",
        "-c", "user.email=integration@example.invalid",
    ]

    /// Initializes a `git` repository at `root` and records one initial commit.
    ///
    /// The repository is what lets the diagnostics manager discover this package
    /// as a workspace: `context(containing:)` falls back to
    /// `RootDiscovery.gitRoot(containing:)`, which needs a real `.git` directory
    /// at the package root.
    ///
    /// - Parameter root: the package root to initialize.
    /// - Throws: a ``GitError`` if any `git` invocation exits non-zero.
    private static func initializeGitRepository(at root: URL) throws {
        try runGit(["init", "--quiet"], in: root)
        try runGit(gitIdentityArguments + ["add", "--all"], in: root)
        try runGit(gitIdentityArguments + ["commit", "--quiet", "--message", "Initial scaffold"], in: root)
    }

    /// A failed `git` invocation during scaffolding.
    struct GitError: Error {
        /// The arguments the failing `git` process was launched with.
        let arguments: [String]

        /// The process's exit code.
        let exitCode: Int32
    }

    /// Runs `git` with `arguments` in `directory`, throwing on a non-zero exit.
    ///
    /// - Parameters:
    ///   - arguments: the `git` arguments (excluding the `git` executable).
    ///   - directory: the working directory to run in.
    /// - Throws: a ``GitError`` if `git` exits non-zero, or a launch error.
    private static func runGit(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw GitError(arguments: arguments, exitCode: process.terminationStatus)
        }
    }
}

// MARK: - Scaffolded package handle

/// The paths of a scaffolded Swift package: its root and the source files each
/// error-detection matrix row mutates.
///
/// Every path is derived from ``root`` and the fixed relative layout
/// ``PackageSources`` scaffolds, so a test names a row's file by property rather
/// than restating a relative path string.
struct ScaffoldedSwiftPackage {
    /// The package root (also the `git` root and the diagnostics session root).
    let root: URL

    /// Resolves a package-relative path to an absolute URL under ``root``.
    ///
    /// - Parameter relativePath: the path relative to the package root.
    /// - Returns: the absolute file URL.
    func url(_ relativePath: String) -> URL {
        root.appendingPathComponent(relativePath)
    }

    /// The provider file of the dependent-breakage pair (its caller lives in
    /// ``dependentCaller`` in the same target).
    var dependentProvider: URL { url(PackageSources.dependentProviderPath) }

    /// The caller file of the dependent-breakage pair; breaks when
    /// ``dependentProvider``'s signature changes.
    var dependentCaller: URL { url(PackageSources.dependentCallerPath) }

    /// The file the syntax-error row mutates.
    var syntaxRow: URL { url(PackageSources.syntaxRowPath) }

    /// The file the type-error row mutates.
    var typeRow: URL { url(PackageSources.typeRowPath) }

    /// The file the warning-only row mutates.
    var warningRow: URL { url(PackageSources.warningRowPath) }

    /// The file the error-storm (item-cap) row overwrites.
    var stormRow: URL { url(PackageSources.stormRowPath) }

    /// The write-row target file the unresolved-write row overwrites (seeded
    /// clean so sourcekit-lsp knows it as a build-graph source).
    var writeRowFile: URL { url(PackageSources.writeRowFilePath) }
}
