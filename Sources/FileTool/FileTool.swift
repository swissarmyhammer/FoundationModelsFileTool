import FoundationModels
import Operations

/// The fused `files` tool: the five file operations presented to a model and a
/// CLI as one `OperationTool`, plus a read-only variant.
///
/// ``make(context:)`` fuses ``ReadFile``, ``WriteFile``, ``EditFile``,
/// ``GlobFiles``, and ``GrepFiles`` into a single ``OperationTool`` named
/// `files`; ``makeReadOnly(context:)`` fuses the read/glob/grep trio for real
/// and stubs `write file` / `edit file` so they return a corrective, porting the
/// Rust `FileOperationSubset::ReadOnly` surface.
///
/// The fusion, the flat-union schema, the forgiving op/parameter resolution, and
/// the return-don't-throw retry cap are all inherited from the upstream
/// `Operations` runtime — this type only supplies the operation set, the
/// missing-`op` inference hook, and the read-only stubs. Two forms of "forgiving
/// input" are configured here as data:
///
/// - **Parameter aliases** live on the operations themselves as
///   `@OperationParam(aliases:)` (the resolver's only source of per-parameter
///   aliases), so a sah-style `file_path` / native-Edit `old_string` /
///   `new_string` payload resolves onto the canonical `filePath` / `find` /
///   `replace`.
/// - **Missing-`op` inference** is the ordered ``inferenceRules`` table, whose
///   key sets are derived from those same operation aliases (plus the standalone
///   `edits` marker) so no alias literal is duplicated between the two.
public enum FileTool {
    // MARK: Tool identity

    /// The fused tool's model- and CLI-facing name.
    private static let toolName = "files"

    /// A human- and model-facing summary of the fused tool.
    private static let toolDescription = "File operations for reading, writing, editing, and searching files."

    // MARK: Public factories

    /// Builds the read/write `files` tool fusing all five file operations.
    ///
    /// The operations dispatch through ``AnyOperation`` against the shared
    /// `context`, in the order `read` / `write` / `edit` / `glob` / `grep` (the
    /// order the fused schema's `op` enum and any unknown-operation corrective
    /// list them in). The resolver carries the missing-`op` inference hook.
    ///
    /// - Parameter context: the shared session context every operation's
    ///   `execute(in:)` runs against.
    /// - Returns: the fused `files` tool, ready to register on a
    ///   `LanguageModelSession` or drive from the CLI.
    /// - Throws: `SchemaFusionError.reservedParameterName` if an operation
    ///   declares a parameter colliding with the `op` discriminator (not
    ///   expected for this fixed operation set, but propagated per
    ///   `OperationTool.init`'s contract); rethrows `GenerationSchema.SchemaError`
    ///   on any other schema-fusion failure.
    public static func make(context: FileContext) throws -> OperationTool<FileContext> {
        try makeOperationTool(
            context: context,
            operations: [
                AnyOperation(ReadFile.self),
                AnyOperation(WriteFile.self),
                AnyOperation(EditFile.self),
                AnyOperation(GlobFiles.self),
                AnyOperation(GrepFiles.self),
            ]
        )
    }

    /// Builds the read-only `files` tool for validator and inspector sessions.
    ///
    /// The read/glob/grep operations are fused for real; `write file` and
    /// `edit file` are fused as stubs (``ReadOnlyWriteFile`` /
    /// ``ReadOnlyEditFile``) that always return the ``readOnlyRejectionMessage``
    /// corrective and never touch the filesystem. The rejection is therefore
    /// structural — it does not depend on `context.readOnly` being set — while
    /// still surfacing the specific "not available in read-only mode" corrective
    /// (rather than an unknown-operation message) so the model can act on it.
    ///
    /// - Parameter context: the shared session context the read operations run
    ///   against.
    /// - Returns: the fused read-only `files` tool.
    /// - Throws: `SchemaFusionError.reservedParameterName` if an operation
    ///   declares a parameter colliding with the `op` discriminator (not
    ///   expected for this fixed operation set, but propagated per
    ///   `OperationTool.init`'s contract); rethrows `GenerationSchema.SchemaError`
    ///   on any other schema-fusion failure.
    public static func makeReadOnly(context: FileContext) throws -> OperationTool<FileContext> {
        try makeOperationTool(
            context: context,
            operations: [
                AnyOperation(ReadFile.self),
                AnyOperation(ReadOnlyWriteFile.self),
                AnyOperation(ReadOnlyEditFile.self),
                AnyOperation(GlobFiles.self),
                AnyOperation(GrepFiles.self),
            ]
        )
    }

    /// Builds a fused `files` ``OperationTool`` over the given operation set.
    ///
    /// ``make(context:)`` and ``makeReadOnly(context:)`` differ only in which
    /// operations they fuse; this helper owns the shared identity, context, and
    /// resolver wiring so that construction pattern lives in exactly one place.
    ///
    /// - Parameters:
    ///   - context: the shared session context every operation's `execute(in:)`
    ///     runs against.
    ///   - operations: the operation set to fuse, in schema order.
    /// - Returns: the fused `files` tool over `operations`.
    /// - Throws: `SchemaFusionError.reservedParameterName` if an operation
    ///   declares a parameter colliding with the `op` discriminator (not
    ///   expected for this fixed operation set, but propagated per
    ///   `OperationTool.init`'s contract); rethrows `GenerationSchema.SchemaError`
    ///   on any other schema-fusion failure.
    private static func makeOperationTool(
        context: FileContext,
        operations: [AnyOperation<FileContext>]
    ) throws -> OperationTool<FileContext> {
        try OperationTool(
            name: toolName,
            description: toolDescription,
            context: context,
            operations: operations,
            resolver: makeResolver()
        )
    }

    /// Builds the forgiving resolver both factories share.
    ///
    /// Layers the missing-`op` inference hook and the ``fileVerbSelfAliases``
    /// neutralizer onto the upstream resolver; every other resolution rule is the
    /// upstream default.
    ///
    /// - Returns: a resolver wired to ``inferOperation(from:)`` and
    ///   ``fileVerbSelfAliases``.
    private static func makeResolver() -> OperationResolver {
        OperationResolver(verbAliases: fileVerbSelfAliases, inferOp: { inferOperation(from: $0) })
    }

    /// Identity verb aliases neutralizing any upstream default that would rewrite
    /// a file op's verb before matching.
    ///
    /// `OperationResolver.defaultVerbAliases` maps `read` → `get` (among others);
    /// left in place it rewrites this tool's `read` verb away from itself so
    /// `read file` never matches. Mapping every file verb to itself keeps the
    /// canonical op strings matchable while leaving the unrelated defaults
    /// (`create` / `show` / …) intact, and guards the other file verbs against
    /// any future default addition that would collide. Derived from the
    /// operations' own `verb` statics so it cannot drift from them.
    private static let fileVerbSelfAliases: [String: String] = Dictionary(
        uniqueKeysWithValues: [ReadFile.verb, WriteFile.verb, EditFile.verb, GlobFiles.verb, GrepFiles.verb]
            .map { ($0, $0) }
    )

    // MARK: Read-only rejection

    /// The corrective returned when a mutating op is invoked on the read-only tool.
    ///
    /// - Parameter operation: the op string of the rejected mutation
    ///   (`write file` or `edit file`).
    /// - Returns: the corrective message naming the operation.
    static func readOnlyRejectionMessage(forOperation operation: String) -> String {
        "The `\(operation)` operation is not available in read-only mode."
    }

    // MARK: Missing-`op` inference

    /// A single missing-`op` inference rule: an op string proposed when the
    /// payload's keys satisfy the rule's conditions.
    ///
    /// A rule fires when at least one ``triggerKeys`` member is present and —
    /// when ``alsoRequiringAnyOf`` is non-`nil` — at least one of its members is
    /// present too. The ordered ``inferenceRules`` table encodes the Rust
    /// precedence; ``matches(presentKeys:)`` is the single predicate that
    /// interprets every rule, so precedence is data, not a branch ladder.
    private struct InferenceRule: Sendable {
        /// The op string this rule proposes when it fires.
        let operationString: String

        /// The normalized keys, any one of which triggers the rule.
        let triggerKeys: Set<String>

        /// Normalized keys, at least one of which must also be present for the
        /// rule to fire, or `nil` when a trigger alone suffices.
        let alsoRequiringAnyOf: Set<String>?

        /// Whether this rule fires for the given present payload keys.
        ///
        /// - Parameter presentKeys: the payload's normalized property keys.
        /// - Returns: `true` when a trigger key is present and any additional
        ///   requirement is satisfied.
        func matches(presentKeys: Set<String>) -> Bool {
            guard !presentKeys.isDisjoint(with: triggerKeys) else { return false }
            guard let alsoRequiringAnyOf else { return true }
            return !presentKeys.isDisjoint(with: alsoRequiringAnyOf)
        }
    }

    /// The `edits` object-array key: an edit-dialect marker with no operation
    /// parameter of its own (``EditFile`` models edits as parallel `find` /
    /// `replace` arrays), so it is the one inference marker not derived from an
    /// operation's aliases.
    private static let editsMarkerKey = "edits"

    /// Normalized keys that mark an edit-dialect payload: ``EditFile``'s `find`
    /// and `replace` names and aliases, plus the standalone ``editsMarkerKey``.
    private static let editMarkerKeys: Set<String> =
        markerKeys(of: EditFile.parameterMetadata, forParametersNamed: ["find", "replace"])
        .union([normalizedKey(editsMarkerKey)])

    /// Normalized keys that mark a write payload: ``WriteFile``'s `content`.
    private static let writeMarkerKeys: Set<String> =
        markerKeys(of: WriteFile.parameterMetadata, forParametersNamed: ["content"])

    /// Normalized keys that mark a glob/grep search: the shared `pattern`.
    private static let patternMarkerKeys: Set<String> =
        markerKeys(of: GlobFiles.parameterMetadata, forParametersNamed: ["pattern"])

    /// Normalized keys that distinguish a grep from a glob: ``GrepFiles``'s
    /// grep-only `caseInsensitive` / `contextLines` / `outputMode` markers.
    private static let grepMarkerKeys: Set<String> =
        markerKeys(
            of: GrepFiles.parameterMetadata,
            forParametersNamed: ["caseInsensitive", "contextLines", "outputMode"]
        )

    /// Normalized keys that mark a read: ``ReadFile``'s `path` name and aliases.
    private static let pathMarkerKeys: Set<String> =
        markerKeys(of: ReadFile.parameterMetadata, forParametersNamed: ["path"])

    /// The ordered inference precedence, first match winning: edit-ish keys →
    /// `edit file`; `content` → `write file`; `pattern` plus a grep marker →
    /// `grep files`; `pattern` alone → `glob files`; `path` alone → `read file`.
    private static let inferenceRules: [InferenceRule] = [
        InferenceRule(operationString: EditFile.opString, triggerKeys: editMarkerKeys, alsoRequiringAnyOf: nil),
        InferenceRule(operationString: WriteFile.opString, triggerKeys: writeMarkerKeys, alsoRequiringAnyOf: nil),
        InferenceRule(
            operationString: GrepFiles.opString,
            triggerKeys: patternMarkerKeys,
            alsoRequiringAnyOf: grepMarkerKeys
        ),
        InferenceRule(operationString: GlobFiles.opString, triggerKeys: patternMarkerKeys, alsoRequiringAnyOf: nil),
        InferenceRule(operationString: ReadFile.opString, triggerKeys: pathMarkerKeys, alsoRequiringAnyOf: nil),
    ]

    /// Proposes an op string for an `op`-less payload from the keys it carries.
    ///
    /// Extracts the payload's property keys, normalizes them, and returns the
    /// first ``inferenceRules`` entry that fires; an undeterminable payload (no
    /// rule fires, or the payload is not a structure) returns `nil`, which the
    /// fused tool surfaces as its unknown-operation corrective naming every
    /// registered op.
    ///
    /// - Parameter content: the `op`-less payload to inspect.
    /// - Returns: the proposed op string, or `nil` when no rule matches.
    static func inferOperation(from content: GeneratedContent) -> String? {
        guard case let .structure(properties, _) = content.kind else { return nil }
        let presentKeys = Set(properties.keys.map(normalizedKey))
        return inferenceRules.first { $0.matches(presentKeys: presentKeys) }?.operationString
    }

    /// The normalized name and alias keys of the named parameters in `metadata`.
    ///
    /// Gathers each selected parameter's canonical name and every declared alias
    /// (normalized via ``normalizedKey(_:)``), so the inference markers are
    /// derived from the operations' own alias declarations rather than restated.
    ///
    /// - Parameters:
    ///   - metadata: the operation's parameter metadata.
    ///   - names: the canonical parameter names to collect keys for.
    /// - Returns: the normalized name and alias keys of the selected parameters.
    private static func markerKeys(of metadata: [ParamMeta], forParametersNamed names: Set<String>) -> Set<String> {
        var keys: Set<String> = []
        for parameter in metadata where names.contains(parameter.name) {
            keys.insert(normalizedKey(parameter.name))
            for alias in parameter.aliases {
                keys.insert(normalizedKey(alias))
            }
        }
        return keys
    }

    /// Normalizes a key for case- and separator-insensitive comparison:
    /// lowercased with `_` and `-` removed.
    ///
    /// Mirrors the upstream resolver's `OperationKeys.normalized(_:)` — which is
    /// `internal` to the `Operations` module and so unreachable here — so an
    /// inference marker derived from an alias compares equal to the same key
    /// however the payload spells it (`file_path` / `filePath`). If the upstream
    /// normalization algorithm changes, this must change with it.
    ///
    /// - Parameter name: the raw key to normalize.
    /// - Returns: the normalized key.
    private static func normalizedKey(_ name: String) -> String {
        name.lowercased().filter { $0 != "_" && $0 != "-" }
    }
}

// MARK: - Read-only mutation stubs

/// The `write file` stub for the read-only tool: accepts the op but always
/// returns the read-only corrective without touching the filesystem.
///
/// A unit struct — it declares no parameters, so the read-only schema carries no
/// write fields, yet a `write file` payload still resolves to it (dispatch
/// matches on the `verb`/`noun` pair) and is rejected with the specific
/// corrective rather than an unknown-operation message.
@Generable
@Operation(verb: "write", noun: "file", description: "Rejected: writing is not available in a read-only session")
struct ReadOnlyWriteFile: Sendable {
}

extension ReadOnlyWriteFile {
    /// Rejects the write with the read-only corrective.
    ///
    /// - Parameter context: the shared session context (unused; the rejection is
    ///   structural).
    /// - Returns: a ``WriteOutput/corrective(_:)`` naming this operation.
    /// - Throws: Nothing; the signature carries `throws` to satisfy the
    ///   `OperationDefinition` protocol requirement.
    func execute(in context: FileContext) async throws -> WriteOutput {
        .corrective(FileTool.readOnlyRejectionMessage(forOperation: Self.opString))
    }
}

/// The `edit file` stub for the read-only tool: accepts the op but always
/// returns the read-only corrective without touching the filesystem.
///
/// A unit struct, for the same reason as ``ReadOnlyWriteFile``.
@Generable
@Operation(verb: "edit", noun: "file", description: "Rejected: editing is not available in a read-only session")
struct ReadOnlyEditFile: Sendable {
}

extension ReadOnlyEditFile {
    /// Rejects the edit with the read-only corrective.
    ///
    /// - Parameter context: the shared session context (unused; the rejection is
    ///   structural).
    /// - Returns: an ``EditOutput/corrective(_:)`` naming this operation.
    /// - Throws: Nothing; the signature carries `throws` to satisfy the
    ///   `OperationDefinition` protocol requirement.
    func execute(in context: FileContext) async throws -> EditOutput {
        .corrective(FileTool.readOnlyRejectionMessage(forOperation: Self.opString))
    }
}
