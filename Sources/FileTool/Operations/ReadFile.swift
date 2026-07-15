import Foundation
import FoundationModels
import Operations

/// The successful result of a `read file` operation: the whole-file freshness token and the windowed lines.
///
/// The ``hash`` is computed over the full on-disk bytes regardless of any
/// offset or limit window, so it is stable across reads of the same file and a
/// later `write file` / `edit file` can re-derive it to detect staleness. The
/// ``lines`` are the selected window, each carrying an absolute hashline anchor
/// (`hashline` format) or the raw text (`plain` format). The ``note`` describes
/// the window when the returned lines are a strict subset of the file.
public struct ReadResult: Encodable, Sendable {
    /// The whole-file freshness token over the full on-disk bytes.
    public let hash: String

    /// The selected window of lines, tagged (`hashline`) or verbatim (`plain`).
    public let lines: [String]

    /// A human-readable description of the window, or `nil` for a whole-file read.
    public let note: String?

    /// Creates a read result.
    ///
    /// - Parameters:
    ///   - hash: the whole-file freshness token over the full on-disk bytes.
    ///   - lines: the selected window of lines.
    ///   - note: the window description, or `nil` for a whole-file read.
    public init(hash: String, lines: [String], note: String?) {
        self.hash = hash
        self.lines = lines
        self.note = note
    }
}

/// The outcome of a `read file` operation: either the windowed content or a corrective message.
///
/// The operation follows the upstream *return-don't-throw* convention (the same
/// convention ``PathViolation`` embodies for path validation): a bound
/// violation, a binary (non-UTF-8) file, or an unreadable path is surfaced as a
/// ``corrective(_:)`` message the model reads and acts on within the turn,
/// never thrown. Throwing from an operation's `execute(in:)` is fatal to the
/// turn, so every recoverable condition returns a value instead.
public enum ReadOutput: Encodable, Sendable {
    /// A successful read carrying the windowed ``ReadResult``.
    case content(ReadResult)

    /// A recoverable failure carrying a corrective message for the model.
    case corrective(String)

    /// The coding keys for the ``corrective(_:)`` encoding.
    private enum CodingKeys: String, CodingKey {
        /// The corrective-message field.
        case corrective
    }

    /// Encodes the outcome.
    ///
    /// A ``content(_:)`` outcome encodes the ``ReadResult`` inline (its `hash`,
    /// `lines`, and `note` fields); a ``corrective(_:)`` outcome encodes a
    /// single `corrective` field carrying the message.
    ///
    /// - Parameter encoder: the encoder to write the outcome into.
    public func encode(to encoder: Encoder) throws {
        switch self {
        case .content(let result):
            try result.encode(to: encoder)
        case .corrective(let message):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(message, forKey: .corrective)
        }
    }
}

/// Reads a file's contents, windowed by line and tagged with hashline anchors.
///
/// The pipeline validates the parameter bounds and the path, reads the full
/// on-disk bytes, rejects a non-UTF-8 (binary) file rather than ever decoding
/// it, windows the decoded text by ``offset`` / ``limit`` over lines, and — in
/// the default `hashline` format — tags each windowed line with an absolute
/// hashline anchor via ``Hashline/tag(lines:startingAtLine:)``. The whole-file
/// freshness token is the lowercase-hex MD5 over the full bytes regardless of
/// the window, so it never changes with the offset or limit.
@Generable
@Operation(verb: "read", noun: "file", description: "Read a file's contents, windowed by line and tagged with hashline anchors")
public struct ReadFile: Sendable {
    /// The path of the file to read.
    public var path: String

    /// The 1-based line number to start reading from.
    public var offset: Int?

    /// The maximum number of lines to return.
    public var limit: Int?

    /// The output format: `hashline` anchors (the default) or `plain` text.
    public var format: String?
}

extension ReadFile {
    // MARK: Bounds

    /// A bounded integer parameter: its name, the kind of value it expects, and its inclusive range.
    ///
    /// Bound checking is data, not control flow: ``offsetBound`` and
    /// ``limitBound`` are two instances of this one type, and ``violation(_:)``
    /// is the single code path that validates a value and builds its corrective
    /// message. There is no per-parameter validation function or message string
    /// to keep in lockstep — a parameter's whole identity lives in its spec.
    private struct BoundSpec {
        /// The parameter name, as it appears in backticks in a corrective message (`offset`).
        let parameterName: String

        /// The kind of value expected, as it reads in a corrective message (`1-based line number`).
        let typeDescription: String

        /// The smallest acceptable value.
        let minimum: Int

        /// The largest acceptable value.
        let maximum: Int

        /// The corrective message naming this parameter's valid, inclusive range.
        var correctiveMessage: String {
            "The `\(parameterName)` parameter must be a \(typeDescription) between \(minimum) and \(maximum)."
        }

        /// A corrective message when `value` is present and out of range, or `nil` when acceptable.
        ///
        /// An absent value is acceptable (the parameter was omitted); an in-range
        /// value is acceptable; an out-of-range value yields ``correctiveMessage``.
        ///
        /// - Parameter value: the requested value, or `nil` when the parameter was omitted.
        /// - Returns: ``correctiveMessage`` when `value` is present and out of
        ///   range, else `nil`.
        func violation(_ value: Int?) -> String? {
            guard let value else { return nil }
            return (minimum...maximum).contains(value) ? nil : correctiveMessage
        }
    }

    /// The bound on ``offset``: a 1-based line number in `1 ... 1_000_000`, matching the Rust `files` tool.
    private static let offsetBound = BoundSpec(
        parameterName: "offset",
        typeDescription: "1-based line number",
        minimum: 1,
        maximum: 1_000_000
    )

    /// The bound on ``limit``: a line count in `1 ... 100_000`, matching the Rust `files` tool.
    private static let limitBound = BoundSpec(
        parameterName: "limit",
        typeDescription: "line count",
        minimum: 1,
        maximum: 100_000
    )

    // MARK: Format names

    /// The format name selecting hashline-anchored output.
    private static let hashlineFormatName = "hashline"

    /// The format name selecting plain, untagged output.
    private static let plainFormatName = "plain"

    /// The format used when the ``format`` parameter is absent.
    private static let defaultFormatName = hashlineFormatName

    // MARK: Window-note text

    /// The leading text of a window note (before the start line number).
    private static let windowNotePrefix = "showing lines "

    /// The separator between the window's start and end line numbers (an en dash).
    private static let windowNoteRangeSeparator = "\u{2013}"

    /// The text between the window's end line number and the file's total.
    private static let windowNoteTotalPrefix = " of "

    // MARK: Output format

    /// The resolved output format of a `read file` operation.
    private enum ReadFormat {
        /// Each line carries an absolute `N:HH|text` hashline anchor.
        case hashline

        /// Each line is the raw text, with no anchor or per-line tag.
        case plain
    }

    /// The mapping from an accepted ``format`` name to its resolved ``ReadFormat``.
    ///
    /// Format resolution is data, not control flow: this table is the single
    /// place that enumerates the accepted names, so ``resolveFormat(_:)`` is one
    /// lookup and the valid names in ``unknownFormatMessage`` cannot drift out of
    /// step with what the operation actually accepts.
    private static let formatMap: [String: ReadFormat] = [
        hashlineFormatName: .hashline,
        plainFormatName: .plain
    ]

    // MARK: Execution

    /// Reads the file and returns the windowed content or a corrective message.
    ///
    /// Validates the ``offset`` / ``limit`` / ``format`` bounds, then the path
    /// via the context's ``PathGuard``, then reads and UTF-8-decodes the full
    /// bytes (rejecting a binary file), and finally windows and tags the text.
    /// Every recoverable failure is returned as ``ReadOutput/corrective(_:)``;
    /// nothing here throws for a bad parameter, path, or file.
    ///
    /// - Parameter context: the shared session context supplying the path guard.
    /// - Returns: the windowed ``ReadOutput/content(_:)`` on success, or a
    ///   ``ReadOutput/corrective(_:)`` message the model can act on.
    public func execute(in context: FileContext) async throws -> ReadOutput {
        if let message = Self.offsetBound.violation(offset) { return .corrective(message) }
        if let message = Self.limitBound.violation(limit) { return .corrective(message) }
        guard let resolvedFormat = Self.resolveFormat(format) else {
            return .corrective(Self.unknownFormatMessage)
        }

        let url: URL
        switch context.pathGuard.validate(path, for: .read) {
        case .success(let resolved):
            url = resolved
        case .failure(let violation):
            return .corrective(violation.message)
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return .corrective(Self.pathErrorMessage(Self.unreadableDescription, path: path))
        }

        guard let content = String(data: data, encoding: .utf8) else {
            return .corrective(Self.pathErrorMessage(Self.binaryDescription, path: path))
        }

        let hash = Hashline.wholeFileHash(bytes: data)
        return .content(Self.window(content: content, hash: hash, offset: offset, limit: limit, format: resolvedFormat))
    }

    // MARK: Format resolution

    /// Resolves the requested format name to a ``ReadFormat``, or `nil` when unknown.
    ///
    /// An absent name resolves to the default (`hashline`); any other name is
    /// looked up in ``formatMap``, so the accepted set lives in exactly one place.
    ///
    /// - Parameter name: the requested format name, or `nil`.
    /// - Returns: the resolved format, or `nil` when the name is unrecognized.
    private static func resolveFormat(_ name: String?) -> ReadFormat? {
        formatMap[name ?? defaultFormatName]
    }

    // MARK: Windowing

    /// Windows the decoded content by line and tags it in the requested format.
    ///
    /// Splits the content into physical lines, selects the ``offset`` / ``limit``
    /// window (clamped to the file's bounds), and renders each windowed line —
    /// as an absolute hashline anchor via ``Hashline/tag(lines:startingAtLine:)`` for
    /// the `hashline` format, or verbatim for `plain`. The ``ReadResult/hash`` is
    /// carried through unchanged so it reflects the full file, not the window.
    ///
    /// - Parameters:
    ///   - content: the full UTF-8 file content.
    ///   - hash: the whole-file freshness token over the full on-disk bytes.
    ///   - offset: the requested 1-based start line, or `nil` for the first line.
    ///   - limit: the requested maximum line count, or `nil` for the whole tail.
    ///   - format: the resolved output format.
    /// - Returns: the windowed ``ReadResult``.
    private static func window(
        content: String,
        hash: String,
        offset: Int?,
        limit: Int?,
        format: ReadFormat
    ) -> ReadResult {
        let physicalLines = Hashline.splitLines(content)
        let total = physicalLines.count
        let startIndex = min(max((offset ?? 1) - 1, 0), total)
        let requestedCount = limit ?? (total - startIndex)
        let endIndex = min(startIndex + max(requestedCount, 0), total)
        let windowSlice = physicalLines[startIndex..<endIndex]

        let lines: [String]
        switch format {
        case .plain:
            lines = windowSlice.map(\.text)
        case .hashline:
            let windowContent = windowSlice.map { $0.text + $0.terminator }.joined()
            let tagged = Hashline.tag(lines: windowContent, startingAtLine: startIndex + 1)
            lines = Hashline.splitLines(tagged).map(\.text)
        }

        let note = windowNote(startIndex: startIndex, endIndex: endIndex, total: total)
        return ReadResult(hash: hash, lines: lines, note: note)
    }

    /// Builds the window note, or `nil` when the window is the whole file.
    ///
    /// Returns `nil` for a whole-file read (the window covers every line). For a
    /// non-empty subset it reports the inclusive 1-based line range and total; a
    /// window that begins past the end of the file reports that instead.
    ///
    /// - Parameters:
    ///   - startIndex: the 0-based index of the window's first line.
    ///   - endIndex: the 0-based index one past the window's last line.
    ///   - total: the total number of lines in the file.
    /// - Returns: the window note, or `nil` for a whole-file read.
    private static func windowNote(startIndex: Int, endIndex: Int, total: Int) -> String? {
        if startIndex == 0 && endIndex == total { return nil }
        if endIndex == startIndex { return pastEndMessage(total: total) }
        return "\(windowNotePrefix)\(startIndex + 1)\(windowNoteRangeSeparator)\(endIndex)\(windowNoteTotalPrefix)\(total)"
    }

    // MARK: Corrective messages

    /// The corrective message naming the valid ``format`` values.
    ///
    /// The valid names are derived from the authoritative ``formatMap`` keys, so
    /// the message cannot drift out of step with the set of formats the
    /// operation actually accepts; adding a format requires editing only the map.
    private static var unknownFormatMessage: String {
        let names = formatMap.keys.sorted().joined(separator: ", ")
        return "The `format` parameter must be one of: \(names)."
    }

    /// The description of a path that exists in bounds but cannot be read, before the `: path` suffix.
    private static let unreadableDescription = "The file could not be read"

    /// The description of a non-UTF-8 (binary) file, which is never decoded, before the `: path` suffix.
    private static let binaryDescription =
        "The file is not valid UTF-8 text and appears to be binary, so it cannot be read as text"

    /// A corrective message for a failed path, formatted as `<description>: <path>`.
    ///
    /// The single template behind the unreadable-path and binary-file messages:
    /// the two conditions differ only by ``unreadableDescription`` versus
    /// ``binaryDescription``, so the shared `<description>: <path>` shape lives in
    /// one place and cannot drift between them.
    ///
    /// - Parameters:
    ///   - description: the leading description of what went wrong.
    ///   - path: the requested path.
    /// - Returns: the corrective message.
    private static func pathErrorMessage(_ description: String, path: String) -> String {
        "\(description): \(path)"
    }

    /// The window note for a window that begins past the end of the file.
    ///
    /// - Parameter total: the total number of lines in the file.
    /// - Returns: the window note.
    private static func pastEndMessage(total: Int) -> String {
        "\(windowNotePrefix)none; the window begins past the end of the file\(windowNoteTotalPrefix)\(total)"
    }
}
