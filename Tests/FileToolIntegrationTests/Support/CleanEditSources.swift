import Foundation

/// The fixed layout and seed contents of the clean-edit integration package.
///
/// Suite B's edits-OK matrix needs a compiling Swift package whose files a row
/// can rewrite into *still-valid* Swift and see a real `sourcekit-lsp` report
/// `clean` — the opposite of ``PackageSources``, whose seeds are shaped to be
/// broken. Rather than contort the breakage-oriented package, this declares a
/// small package purpose-built for clean-preserving edits, reusing
/// ``IsolatedWorkspace``'s temp-directory, file-write, and `git` primitives (it
/// duplicates none of them).
///
/// The package has three targets so a row's mutation cannot leak diagnostics
/// into another row's build:
///
/// - `CleanRows` — one file per cascade rung that only ever holds valid Swift
///   (the clean-write, anchor, literal, recovered, `replaceAll`, `occurrence`,
///   and multi-pair rows). Every such row rewrites its file to fresh clean
///   content first, so the rows are order-independent and the target always
///   compiles.
/// - `RoundTripRow` — the error-then-fix row, isolated in its own target so its
///   *transient* broken state (before the repair) can never poison another
///   row's diagnostics.
/// - `CrossOpRow` — the single Swift file the cross-op flow (write → read →
///   edit-by-anchor → diagnostics) drives to a real `clean`.
///
/// Every relative path and seed body is declared here as data so
/// ``CleanEditPackage`` scaffolds the tree by iterating ``seedFiles`` and a test
/// names a file by the same path constant it edits through.
enum CleanEditSources {
    // MARK: - Relative paths (CleanRows target)

    /// The clean-write row's file: overwritten wholesale with valid Swift.
    static let cleanWritePath = "Sources/CleanRows/CleanWrite.swift"

    /// The anchor-edit row's file: rewritten, then edited by a lifted hashline anchor.
    static let anchorPath = "Sources/CleanRows/Anchor.swift"

    /// The literal-edit row's file: rewritten, then edited by a byte-exact `find`.
    static let literalPath = "Sources/CleanRows/Literal.swift"

    /// The recovered-edit row's file: rewritten, then edited by a drifted `find`.
    static let recoveredPath = "Sources/CleanRows/Recovered.swift"

    /// The `replaceAll` row's file: rewritten, then every occurrence rewritten.
    static let replaceAllPath = "Sources/CleanRows/ReplaceAll.swift"

    /// The `occurrence` row's file: rewritten, then one selected occurrence edited.
    static let occurrencePath = "Sources/CleanRows/Occurrence.swift"

    /// The multi-pair-batch row's file: rewritten, then edited by parallel arrays.
    static let batchPath = "Sources/CleanRows/Batch.swift"

    // MARK: - Relative paths (isolated targets)

    /// The error-then-fix row's file, in its own target so a transient break is contained.
    static let roundTripPath = "Sources/RoundTripRow/RoundTrip.swift"

    /// The cross-op flow's Swift file, in its own target.
    static let crossOpPath = "Sources/CrossOpRow/CrossOp.swift"

    // MARK: - Manifest

    /// The `Package.swift` manifest declaring the three clean-edit targets.
    static let manifest = """
        // swift-tools-version: 6.1
        import PackageDescription

        let package = Package(
            name: "CleanEditPackage",
            targets: [
                .target(name: "CleanRows"),
                .target(name: "RoundTripRow"),
                .target(name: "CrossOpRow"),
            ]
        )
        """

    // MARK: - Seed table

    /// One seed file: its package-relative path and clean, compiling contents.
    struct SeedFile {
        /// The path relative to the package root.
        let relativePath: String

        /// The clean, compiling UTF-8 contents.
        let contents: String
    }

    /// The trailing newline every seed and every row's fresh content ends with,
    /// so a whole-file rewrite always terminates its last line.
    static let sourceTerminator = "\n"

    /// A clean, compiling placeholder seed body for a package-relative path.
    ///
    /// Derives a unique global constant name from the file's base name so every
    /// file in the shared `CleanRows` module declares a distinct symbol and the
    /// target compiles at warm-up before any row rewrites its file. A bare global
    /// `let` is warning-free in a library target (Swift does not warn on unused
    /// globals), so the whole package is `clean` when a real `sourcekit-lsp`
    /// first settles.
    ///
    /// - Parameter relativePath: the package-relative path of the seed file.
    /// - Returns: the clean placeholder body.
    private static func seedBody(forRelativePath relativePath: String) -> String {
        let baseName = URL(fileURLWithPath: relativePath).deletingPathExtension().lastPathComponent
        return "let \(baseName.prefix(1).lowercased() + baseName.dropFirst())Seed = 0" + sourceTerminator
    }

    /// Every clean-edit package-relative path, one per suite-B file.
    private static let relativePaths = [
        cleanWritePath,
        anchorPath,
        literalPath,
        recoveredPath,
        replaceAllPath,
        occurrencePath,
        batchPath,
        roundTripPath,
        crossOpPath,
    ]

    /// Every seed file scaffolded into the package, each a distinct clean global.
    static let seedFiles: [SeedFile] = relativePaths.map { path in
        SeedFile(relativePath: path, contents: seedBody(forRelativePath: path))
    }
}

// MARK: - Scaffolded clean-edit package

/// The paths of a scaffolded clean-edit package: its root and each row's file.
///
/// Every path is derived from ``root`` and the fixed ``CleanEditSources`` layout,
/// so a test names a row's file by property rather than restating a relative path.
struct ScaffoldedCleanEditPackage {
    /// The package root (also the `git` root and the diagnostics session root).
    let root: URL

    /// Resolves a package-relative path to an absolute URL under ``root``.
    ///
    /// - Parameter relativePath: the path relative to the package root.
    /// - Returns: the absolute file URL.
    func url(_ relativePath: String) -> URL {
        root.appendingPathComponent(relativePath)
    }

    /// The clean-write row's file.
    var cleanWrite: URL { url(CleanEditSources.cleanWritePath) }

    /// The anchor-edit row's file.
    var anchor: URL { url(CleanEditSources.anchorPath) }

    /// The literal-edit row's file.
    var literal: URL { url(CleanEditSources.literalPath) }

    /// The recovered-edit row's file.
    var recovered: URL { url(CleanEditSources.recoveredPath) }

    /// The `replaceAll` row's file.
    var replaceAll: URL { url(CleanEditSources.replaceAllPath) }

    /// The `occurrence` row's file.
    var occurrence: URL { url(CleanEditSources.occurrencePath) }

    /// The multi-pair-batch row's file.
    var batch: URL { url(CleanEditSources.batchPath) }

    /// The error-then-fix row's file.
    var roundTrip: URL { url(CleanEditSources.roundTripPath) }

    /// The cross-op flow's Swift file.
    var crossOp: URL { url(CleanEditSources.crossOpPath) }
}

// MARK: - Scaffolding

/// Scaffolding for the clean-edit integration package, layered on ``IsolatedWorkspace``.
///
/// This owns only the clean-edit package's *layout*; the temp-directory,
/// file-write, and `git`-initialization primitives are ``IsolatedWorkspace``'s,
/// reused verbatim so there is a single implementation of each on disk.
enum CleanEditPackage {
    /// Scaffolds a fresh, compiling clean-edit package with a `git` history.
    ///
    /// Writes the ``CleanEditSources/manifest`` and every ``CleanEditSources/seedFiles``
    /// entry, then git-initializes the tree (so the diagnostics manager discovers
    /// it as a workspace). The caller owns the returned package's lifetime and
    /// must ``IsolatedWorkspace/remove(_:)`` its ``ScaffoldedCleanEditPackage/root``
    /// (or use ``withScaffold(named:_:)`` for scoped cleanup).
    ///
    /// - Parameter name: a human-readable prefix identifying the package on disk.
    /// - Returns: the scaffolded package's paths.
    /// - Throws: a file-write or `git` error if scaffolding fails.
    static func scaffold(named name: String) throws -> ScaffoldedCleanEditPackage {
        let root = try IsolatedWorkspace.makeTemporaryDirectory(named: name)
        try IsolatedWorkspace.write(CleanEditSources.manifest, to: root.appendingPathComponent("Package.swift"))
        for seed in CleanEditSources.seedFiles {
            try IsolatedWorkspace.write(seed.contents, to: root.appendingPathComponent(seed.relativePath))
        }
        try IsolatedWorkspace.initializeGitRepository(at: root)
        return ScaffoldedCleanEditPackage(root: root)
    }

    /// Runs `body` against a fresh scaffolded clean-edit package, removing it afterward.
    ///
    /// The package is scaffolded before `body` runs and removed on every exit
    /// path (success or throw), so a scoped test never leaves a package tree
    /// behind.
    ///
    /// - Parameters:
    ///   - name: a human-readable prefix identifying the package on disk.
    ///   - body: the work to run against the scaffolded package.
    /// - Returns: `body`'s result.
    /// - Throws: rethrows whatever scaffolding or `body` throws.
    @discardableResult
    static func withScaffold<T>(
        named name: String,
        _ body: (ScaffoldedCleanEditPackage) async throws -> T
    ) async throws -> T {
        let package = try scaffold(named: name)
        defer { IsolatedWorkspace.remove(package.root) }
        return try await body(package)
    }
}
