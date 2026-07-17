import Foundation

/// Scaffolding for the multi-project session-root integration suite: one session
/// root sitting *above* two independent git repositories, plus files that belong
/// to no repository at all.
///
/// The multi-project suite proves the `CodeContextManager`-backed bridge routes
/// diagnostics per project when the ``FileContext/root`` is a parent of several
/// git repositories rather than a repository itself. This owns only that suite's
/// *layout*; the temp-directory, canonicalization, file-write, package
/// scaffolding, and `git`-initialization primitives are ``IsolatedWorkspace``'s,
/// reused verbatim (it duplicates none of them). Each package is scaffolded from
/// the shared ``PackageSources`` layout, so a row names a package file by the
/// same ``ScaffoldedSwiftPackage`` property the single-project suites use.
enum MultiProjectWorkspace {
    // MARK: - Layout

    /// The child directory name of the first scaffolded package under the session root.
    static let packageADirectoryName = "PackageA"

    /// The child directory name of the second scaffolded package under the session root.
    static let packageBDirectoryName = "PackageB"

    /// The stray Swift file directly under the session root, enclosed by no repository.
    static let looseSwiftName = "Loose.swift"

    /// The stray Markdown file directly under the session root, enclosed by no repository.
    static let notesMarkdownName = "notes.md"

    /// The child directory name of the nested git repository scaffolded inside a package.
    static let nestedRepositoryDirectoryName = "NestedRepo"

    /// The nested repository's single Swift file, relative to the nested repository root.
    ///
    /// Deliberately *not* under the outer package's `Sources/` tree, so the outer
    /// package's build graph never claims it and the nested repository stands on
    /// its own as an independent, git-initialized sub-package. Built from
    /// ``nestedRepositoryDirectoryName`` (also the nested manifest's target name)
    /// so the directory name is single-sourced rather than restated here.
    static var nestedSwiftRelativePath: String { "Sources/\(nestedRepositoryDirectoryName)/Nested.swift" }

    // MARK: - Stray-file seeds

    /// The stray ``looseSwiftName`` seed: a clean, diagnosable Swift function.
    ///
    /// Diagnosable by extension yet enclosed by no git repository, so a mutation
    /// of it is committed but its diagnostics are `skipped` with the
    /// not-in-a-git-workspace note — the file exists so a row can mutate a real
    /// `find` target and confirm that outcome.
    static let looseSwiftSeed = """
        func looseValue() -> Int {
            let value = 1
            return value
        }

        """

    /// The stray ``notesMarkdownName`` seed: plain Markdown a language server never handles.
    static let notesMarkdownSeed = """
        # Notes

        Scratch notes that live outside any package.

        """

    /// The nested repository's `Package.swift`, declaring one library target so it
    /// is a genuine, self-contained sub-package.
    static let nestedManifest = """
        // swift-tools-version: 6.1
        import PackageDescription

        let package = Package(
            name: "NestedPackage",
            targets: [
                .target(name: "NestedRepo"),
            ]
        )
        """

    /// The nested repository's single clean, compiling Swift file.
    static let nestedSwiftSeed = """
        func nestedValue() -> Int {
            return 1
        }

        """

    // MARK: - Session root

    /// Runs `body` against a fresh multi-project session root, removing it afterward.
    ///
    /// Creates one fresh temporary directory as the session root and populates it
    /// with two independent, compiling, git-initialized packages (each scaffolded
    /// by ``IsolatedWorkspace/scaffoldSwiftPackage(at:)`` into its own child
    /// directory), plus a stray ``looseSwiftName`` and ``notesMarkdownName``
    /// directly under the root and outside any repository. The session root is
    /// canonicalized (``IsolatedWorkspace/canonicalURL(_:)``) so its `realpath`
    /// form matches the paths ``PathGuard`` produces, keeping the bridge's
    /// per-package path rebase intact. The tree is removed on every exit path.
    ///
    /// - Parameters:
    ///   - name: a human-readable prefix identifying the session root on disk.
    ///   - body: the work to run against the session root and its two packages.
    /// - Returns: `body`'s result.
    /// - Throws: rethrows whatever scaffolding or `body` throws.
    @discardableResult
    static func withMultiProjectRoot<T>(
        named name: String = "MultiProjectRoot",
        _ body: (MultiProjectRoot) async throws -> T
    ) async throws -> T {
        let created = try IsolatedWorkspace.makeTemporaryDirectory(named: name)
        defer { IsolatedWorkspace.remove(created) }

        let sessionRoot = IsolatedWorkspace.canonicalURL(created)
        let packageA = try scaffoldPackageDirectory(named: packageADirectoryName, under: sessionRoot)
        let packageB = try scaffoldPackageDirectory(named: packageBDirectoryName, under: sessionRoot)

        try IsolatedWorkspace.write(looseSwiftSeed, to: sessionRoot.appendingPathComponent(looseSwiftName))
        try IsolatedWorkspace.write(notesMarkdownSeed, to: sessionRoot.appendingPathComponent(notesMarkdownName))

        let root = MultiProjectRoot(sessionRoot: sessionRoot, packageA: packageA, packageB: packageB)
        return try await body(root)
    }

    /// Scaffolds one independent package into a fresh child directory of the session root.
    ///
    /// Both packages under a session root are built identically — a `name`-named
    /// child directory scaffolded by ``IsolatedWorkspace/scaffoldSwiftPackage(at:)``
    /// — so this is the single code path they share rather than two near-identical
    /// blocks differing only by directory name.
    ///
    /// - Parameters:
    ///   - name: the child directory name for the package under the session root.
    ///   - sessionRoot: the session root to create the package directory under.
    /// - Returns: the scaffolded package's paths.
    /// - Throws: a file-write or `git` error if scaffolding fails.
    private static func scaffoldPackageDirectory(named name: String, under sessionRoot: URL) throws -> ScaffoldedSwiftPackage {
        let root = sessionRoot.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return try IsolatedWorkspace.scaffoldSwiftPackage(at: root)
    }

    // MARK: - Nested repository

    /// Scaffolds a git-initialized sub-package *inside* an outer package.
    ///
    /// Creates a nested directory under `package`'s root, writes a self-contained
    /// package manifest and one clean Swift file there, and gives it its own `git`
    /// history — a genuine repository nested within another. Placed outside the
    /// outer package's `Sources/` tree so the outer build never claims it, it lets
    /// the nested-repo row prove nearest-open-ancestor routing: once the outer
    /// context is open, a mutation inside this nested repository routes to the
    /// outer context and opens no context for the nested root.
    ///
    /// - Parameter package: the outer package to nest the repository inside.
    /// - Returns: the nested repository's paths.
    /// - Throws: a file-write or `git` error if scaffolding fails.
    static func scaffoldNestedRepository(inside package: ScaffoldedSwiftPackage) throws -> NestedRepository {
        let nestedRoot = package.root.appendingPathComponent(nestedRepositoryDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: nestedRoot, withIntermediateDirectories: true)
        try IsolatedWorkspace.write(nestedManifest, to: nestedRoot.appendingPathComponent("Package.swift"))
        try IsolatedWorkspace.write(nestedSwiftSeed, to: nestedRoot.appendingPathComponent(nestedSwiftRelativePath))
        try IsolatedWorkspace.initializeGitRepository(at: nestedRoot)
        return NestedRepository(root: nestedRoot, swiftFile: nestedRoot.appendingPathComponent(nestedSwiftRelativePath))
    }
}

// MARK: - Handles

/// The paths of a multi-project session root: the root and its two packages.
///
/// The session root sits *above* both packages and is itself enclosed by no git
/// repository, so a stray file directly under it belongs to no workspace.
struct MultiProjectRoot {
    /// The session root: the ``FileContext/root``, above both packages, no repository of its own.
    let sessionRoot: URL

    /// The first scaffolded package (its own git repository).
    let packageA: ScaffoldedSwiftPackage

    /// The second scaffolded package (its own git repository).
    let packageB: ScaffoldedSwiftPackage

    /// The stray Swift file directly under the session root (diagnosable, no enclosing repository).
    var looseSwift: URL { sessionRoot.appendingPathComponent(MultiProjectWorkspace.looseSwiftName) }

    /// The stray Markdown file directly under the session root (non-diagnosable, no enclosing repository).
    var notesMarkdown: URL { sessionRoot.appendingPathComponent(MultiProjectWorkspace.notesMarkdownName) }
}

/// The paths of a nested git repository scaffolded inside an outer package.
struct NestedRepository {
    /// The nested repository root (its own `git` root).
    let root: URL

    /// The nested repository's single Swift file.
    let swiftFile: URL
}
