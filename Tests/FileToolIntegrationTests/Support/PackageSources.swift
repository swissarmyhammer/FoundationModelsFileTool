import Foundation

/// The fixed layout and seed contents of the scaffolded Swift package.
///
/// Every relative path and every seed file body the integration package needs is
/// declared here as data, so ``IsolatedWorkspace`` scaffolds the tree by
/// iterating ``seedFiles`` rather than carrying inline literals, and
/// ``ScaffoldedSwiftPackage`` names each row's file by the same path constant a
/// test mutates through.
///
/// The package is split into one library target per error-detection row (plus
/// one target holding the provider/caller pair) so a mutation that breaks one
/// row's file cannot poison another target's build or diagnostics. Every seed
/// compiles cleanly.
enum PackageSources {
    // MARK: - Relative paths

    /// The provider file of the dependent-breakage target.
    static let dependentProviderPath = "Sources/DependentPair/Provider.swift"

    /// The caller file of the dependent-breakage target (it calls the provider).
    static let dependentCallerPath = "Sources/DependentPair/Caller.swift"

    /// The syntax-error row's file.
    static let syntaxRowPath = "Sources/SyntaxRow/SyntaxRow.swift"

    /// The type-error row's file.
    static let typeRowPath = "Sources/TypeRow/TypeRow.swift"

    /// The warning-only row's file.
    static let warningRowPath = "Sources/WarningRow/WarningRow.swift"

    /// The error-storm (item-cap) row's file.
    static let stormRowPath = "Sources/StormRow/StormRow.swift"

    /// The write-row target's seed file (keeps the target non-empty at scaffold).
    static let writeRowSeedPath = "Sources/WriteRow/WriteRowSeed.swift"

    /// The write-row target file the unresolved-write row overwrites.
    ///
    /// Seeded clean at scaffold so sourcekit-lsp already knows it as a build-graph
    /// source when the row rewrites it: a genuinely brand-new `.swift` file is not
    /// in sourcekit-lsp's package graph until a reload, so it reports no semantic
    /// diagnostics (a real-LSP limitation, not a tool bug) — seeding the path lets
    /// the row prove the `write file` op's diagnostics detect the unresolved
    /// identifier in the content it writes.
    static let writeRowFilePath = "Sources/WriteRow/Orphan.swift"

    // MARK: - Manifest

    /// The `Package.swift` manifest declaring one library target per row.
    static let manifest = """
        // swift-tools-version: 6.1
        import PackageDescription

        let package = Package(
            name: "ScaffoldPackage",
            targets: [
                .target(name: "DependentPair"),
                .target(name: "SyntaxRow"),
                .target(name: "TypeRow"),
                .target(name: "WarningRow"),
                .target(name: "StormRow"),
                .target(name: "WriteRow"),
            ]
        )
        """

    // MARK: - Seed file bodies

    /// The provider: a struct whose `compute()` the caller invokes with no
    /// arguments. Changing this signature is what breaks the caller.
    static let dependentProviderSource = """
        public struct Provider {
            public init() {}

            public func compute() -> Int {
                1
            }
        }
        """

    /// The caller: invokes `Provider().compute()` with no arguments, so a
    /// required parameter added to `compute` folds a real error in here.
    static let dependentCallerSource = """
        struct Caller {
            func run() -> Int {
                Provider().compute()
            }
        }
        """

    /// A clean function the syntax-error row edits into an unbalanced-brace parse error.
    static let syntaxRowSource = """
        func syntaxRowValue() -> Int {
            return 1
        }
        """

    /// A clean function the type-error row edits into a `String`-to-`Int` mismatch.
    static let typeRowSource = """
        func typeRowValue() -> Int {
            let value = 1
            return value
        }
        """

    /// A clean function the warning-only row edits to add an unused immutable value.
    static let warningRowSource = """
        func warningRowWork() {
            performWork()
        }

        func performWork() {}
        """

    /// A clean function the error-storm row overwrites with many unresolved references.
    static let stormRowSource = """
        func stormRowValue() -> Int {
            0
        }
        """

    /// The write-row target's seed, so the target exists (and compiles).
    static let writeRowSeedSource = """
        func writeRowSeed() {}
        """

    /// The clean initial contents of the write-row file, seeded so sourcekit-lsp
    /// knows it as a build-graph source before the unresolved-write row rewrites
    /// it with an unresolved identifier.
    static let writeRowFileCleanSource = """
        func orphanPlaceholder() {}
        """

    // MARK: - Seed table

    /// One seed file: its package-relative path and clean, compiling contents.
    struct SeedFile {
        /// The path relative to the package root.
        let relativePath: String

        /// The clean, compiling UTF-8 contents.
        let contents: String
    }

    /// Every seed file scaffolded into the package, each compiling cleanly.
    static let seedFiles: [SeedFile] = [
        SeedFile(relativePath: dependentProviderPath, contents: dependentProviderSource),
        SeedFile(relativePath: dependentCallerPath, contents: dependentCallerSource),
        SeedFile(relativePath: syntaxRowPath, contents: syntaxRowSource),
        SeedFile(relativePath: typeRowPath, contents: typeRowSource),
        SeedFile(relativePath: warningRowPath, contents: warningRowSource),
        SeedFile(relativePath: stormRowPath, contents: stormRowSource),
        SeedFile(relativePath: writeRowSeedPath, contents: writeRowSeedSource),
        SeedFile(relativePath: writeRowFilePath, contents: writeRowFileCleanSource),
    ]

    // MARK: - Error-storm content

    /// The number of distinct unresolved identifiers the error-storm file
    /// references, chosen well above the bridge's item cap so the row proves the
    /// item list is capped while the error count stays true.
    static let errorStormReferenceCount = 150

    /// A Swift file body referencing ``errorStormReferenceCount`` distinct
    /// undefined identifiers, each producing a "cannot find … in scope" error.
    ///
    /// Written whole by the item-cap row (a `write file`), so the file lands with
    /// ``errorStormReferenceCount`` real compiler errors at once.
    static var errorStormSource: String {
        let references = (0 ..< errorStormReferenceCount)
            .map { "    _ = undefinedStormSymbol\($0)" }
            .joined(separator: "\n")
        return """
            func stormRowValue() {
            \(references)
            }
            """
    }
}
