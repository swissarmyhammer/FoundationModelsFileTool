import CryptoKit
import Foundation

/// Pure, IO-free hashline anchor primitives — an algorithm-exact port of the
/// Rust `swissarmyhammer-hashline` crate (plus the `md5`-based whole-file
/// freshness token from `swissarmyhammer-tools`' `shared_utils::whole_file_hash`).
///
/// A *hashline anchor* tags a line of text with its 1-based line number and a
/// short content hash, rendered as `N:HH` (for example `42:a3`). `read file`
/// tags content so the model can reference specific lines; `edit file` resolves
/// those anchors back to lines, tolerating small drift (a few lines moved) and
/// rejecting stale edits (the referenced line's content changed).
///
/// The hash algorithm is ported byte-for-byte so anchors emitted by the Rust
/// `files` tool resolve here and vice versa — one anchor dialect across the
/// ecosystem. Parity is pinned by golden vectors generated from the Rust crate
/// (`Tests/FileToolTests/Fixtures/hashline-golden.json`).
enum Hashline {
    /// How far from the exact line number proximity search looks for a drifted
    /// anchor. The search expands symmetrically outward (`+1, -1, +2, -2, …`) up
    /// to this many lines on each side. Matches the Rust `PROXIMITY_WINDOW`.
    static let proximityWindow = 50

    // MARK: Per-line hash

    /// Compute the staleness hash of a single line.
    ///
    /// The line is hashed with leading and trailing *horizontal* whitespace
    /// (spaces and tabs) stripped but interior whitespace preserved, then reduced
    /// `mod 256`. The result is a coarse fingerprint: 256 distinct values are
    /// enough to detect that a line's content changed, not to uniquely identify
    /// it; the line number disambiguates hash collisions.
    ///
    /// Re-indenting a line (changing only leading/trailing horizontal
    /// whitespace) yields the same hash; changing interior content differs.
    ///
    /// - Parameter line: the line text (line terminator excluded).
    /// - Returns: the low byte of the CRC-32 of the trimmed line bytes.
    static func hashLine(_ line: String) -> UInt8 {
        let trimmed = trimHorizontal(line)
        return UInt8(crc32(Array(trimmed.utf8)) & 0xff)
    }

    /// Render a hash byte as two lowercase hexadecimal characters
    /// (`0xa3` -> `"a3"`, `0x0f` -> `"0f"`).
    static func renderHash(_ hash: UInt8) -> String {
        String(format: "%02x", hash)
    }

    // MARK: Tagging

    /// Annotate each line of `content` with a hashline anchor.
    ///
    /// Each line becomes `N:HH|line`, where `N` is the absolute 1-based line
    /// number (the first line is `startLine`) and `HH` is ``renderHash(_:)`` of
    /// ``hashLine(_:)``. Line endings present in `content` (`\n`, `\r\n`, `\r`,
    /// or a mix) are preserved exactly.
    ///
    /// - Parameters:
    ///   - content: the raw file content, terminators intact.
    ///   - startLine: the 1-based line number assigned to the first line.
    /// - Returns: the tagged content as a single string.
    static func tag(lines content: String, startLine: Int) -> String {
        var out = ""
        for (offset, line) in splitLines(content).enumerated() {
            let n = startLine + offset
            out += "\(n):\(renderHash(hashLine(line.text)))|\(line.text)\(line.terminator)"
        }
        return out
    }

    // MARK: Whole-file freshness token

    /// Compute the whole-file freshness token: the lowercase-hex MD5 digest of
    /// the full file bytes.
    ///
    /// This is the `#hash:` token the `read file` tool surfaces and the write /
    /// edit guards re-derive from on-disk bytes to detect whole-file staleness.
    /// MD5 is used purely for change detection (not security), mirroring the Rust
    /// `whole_file_hash` (`format!("{:x}", md5::compute(bytes))`).
    ///
    /// - Parameter bytes: the full on-disk file bytes.
    /// - Returns: a 32-character lowercase hex string.
    static func wholeFileHash(bytes: Data) -> String {
        Insecure.MD5.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Anchor parsing

    /// Parse a hashline anchor `N:HH`, returning the 1-based line number and
    /// hash.
    ///
    /// An optional `|text` suffix is tolerated and ignored here (the caller uses
    /// the text for verification or fallback; see ``resolveAnchor(_:in:)``).
    /// Returns `nil` for anything that is not a well-formed anchor: the line must
    /// parse as a Rust `usize` (an optional single leading `+` then a non-empty
    /// run of ASCII decimal digits — `-` and whitespace rejected) and the hash
    /// must be exactly two hex digits.
    static func parseAnchor(_ s: String) -> (line: Int, hash: UInt8)? {
        // Strip an optional `|text` suffix; the text is ignored here.
        let anchor: Substring = s.firstIndex(of: "|").map { s[s.startIndex..<$0] } ?? Substring(s)
        guard let colon = anchor.firstIndex(of: ":") else { return nil }
        let num = anchor[anchor.startIndex..<colon]
        let hex = anchor[anchor.index(after: colon)...]
        guard !num.isEmpty, hex.count == 2 else { return nil }
        // Match Rust `usize::from_str`: allow one optional leading `+`, then a
        // non-empty ASCII digit run. `-`, whitespace, and non-digits are rejected.
        var digits = num
        if digits.first == "+" { digits = digits.dropFirst() }
        guard !digits.isEmpty,
            digits.allSatisfy({ $0.isASCII && ("0"..."9").contains($0) }),
            let line = Int(digits)
        else { return nil }
        guard let hash = UInt8(hex, radix: 16) else { return nil }
        return (line, hash)
    }

    // MARK: Anchor resolution

    /// Resolve a hashline anchor string against `content`, returning the
    /// **1-based** line number whose content hashes to the anchor's hash,
    /// tolerating small drift, or `nil` when the anchor is stale/unresolvable.
    ///
    /// The `anchor` carries the dialect `N:HH` with an optional `|text` suffix;
    /// the suffix (when present) is used to verify/relocate — see
    /// ``resolveAnchorIn(_:line:hash:text:)`` for the exact rule. A caller that
    /// gets `nil` should fall through to literal interpretation rather than
    /// misapply.
    static func resolveAnchor(_ anchor: String, in content: String) -> Int? {
        guard let (line, hash) = parseAnchor(anchor) else { return nil }
        let text: String? = anchor.firstIndex(of: "|").map { String(anchor[anchor.index(after: $0)...]) }
        return resolveAnchorIn(content, line: line, hash: hash, text: text)
    }

    /// Resolve a hashline anchor against `content`, returning the **1-based**
    /// line number whose content hashes to `hash`, tolerating small drift.
    ///
    /// Resolution order:
    /// 1. The exact 1-based `line`, if its content hashes to `hash`.
    /// 2. A proximity search expanding symmetrically outward from `line` (deltas
    ///    `+1, -1, +2, -2, …` up to ``proximityWindow`` lines on each side),
    ///    taking the first line that hashes to `hash`.
    ///
    /// The optional `text` is a verification/tie-breaker: when present, a
    /// candidate (exact or in-window) whose trimmed line text equals the trimmed
    /// `text` is preferred over a merely-hash-matching candidate, scanning
    /// outward from `line`. If `text` matches no in-window candidate, resolution
    /// falls back to the nearest hash-matching line (text is a fallback, not a
    /// hard gate). When **nothing** in the window hashes to `hash`, returns `nil`.
    ///
    /// `line == 0` (or any non-positive line) is treated as "no exact candidate"
    /// and the search proceeds from the first line. Performs no IO.
    static func resolveAnchorIn(_ content: String, line: Int, hash: UInt8, text: String?) -> Int? {
        let lines = splitLines(content).map(\.text)
        return resolveIndex(lines, line: line, hash: hash, text: text).map { $0 + 1 }
    }

    /// Resolve a hashline anchor to a **0-based** index into `lines` (the
    /// per-line texts of the content, terminators excluded). Shared core for the
    /// public resolution entry points; mirrors the Rust `resolve_index`.
    private static func resolveIndex(_ lines: [String], line: Int, hash: UInt8, text: String?) -> Int? {
        func hashMatches(_ idx: Int) -> Bool {
            idx >= 0 && idx < lines.count && hashLine(lines[idx]) == hash
        }
        func textMatches(_ idx: Int) -> Bool {
            guard let wanted = text, idx >= 0, idx < lines.count else { return false }
            return trimHorizontal(lines[idx]) == trimHorizontal(wanted)
        }

        // The exact line as a 0-based index; `line <= 0` -> no exact candidate.
        let exact: Int? = line >= 1 ? line - 1 : nil
        let center = exact ?? 0

        // Visit candidates in proximity order, recording the nearest hash match
        // and the nearest text-confirmed hash match. The exact line is delta 0.
        var nearestHash: Int?
        var nearestText: Int?
        func consider(_ candidate: Int) {
            guard candidate >= 0, hashMatches(candidate) else { return }
            if nearestHash == nil { nearestHash = candidate }
            if nearestText == nil, textMatches(candidate) { nearestText = candidate }
        }

        if exact != nil { consider(center) }
        for delta in 1...proximityWindow {
            consider(center + delta)
            consider(center - delta)
        }

        // Prefer a text-confirmed candidate; otherwise the nearest hash match.
        return nearestText ?? nearestHash
    }

    // MARK: Internals

    /// A single line of content: its text (terminator excluded) and the original
    /// terminator that followed it (`\n`, `\r\n`, `\r`, or `""` for a final
    /// unterminated line).
    private struct Line {
        let text: String
        let terminator: String
    }

    /// Split `content` into lines preserving each line's original terminator.
    ///
    /// Mirrors the Rust `split_lines`: scans over Unicode scalars (not
    /// graphemes, so `\r\n` is treated as two scalars — a bare `\r` and a `\n` —
    /// exactly as the Rust byte scan does, rather than as a single grapheme
    /// cluster). Empty content yields no lines; content ending in a terminator
    /// yields no phantom trailing empty line.
    private static func splitLines(_ content: String) -> [Line] {
        var result: [Line] = []
        let scalars = content.unicodeScalars
        let end = scalars.endIndex
        var i = scalars.startIndex
        var lineStart = i

        func text(upTo idx: String.UnicodeScalarView.Index) -> String {
            String(String.UnicodeScalarView(scalars[lineStart..<idx]))
        }

        while i < end {
            let scalar = scalars[i]
            if scalar == "\n" {
                result.append(Line(text: text(upTo: i), terminator: "\n"))
                i = scalars.index(after: i)
                lineStart = i
            } else if scalar == "\r" {
                let next = scalars.index(after: i)
                if next < end, scalars[next] == "\n" {
                    result.append(Line(text: text(upTo: i), terminator: "\r\n"))
                    i = scalars.index(after: next)
                } else {
                    result.append(Line(text: text(upTo: i), terminator: "\r"))
                    i = next
                }
                lineStart = i
            } else {
                i = scalars.index(after: i)
            }
        }
        if lineStart < end {
            result.append(Line(text: text(upTo: end), terminator: ""))
        }
        return result
    }

    /// Trim leading and trailing horizontal whitespace (spaces and tabs) from a
    /// string, preserving interior content. Mirrors Rust's
    /// `trim_matches([' ', '\t'])`, which trims per *scalar* (`char`), not per
    /// grapheme cluster — so a leading space immediately followed by a combining
    /// mark trims the space and keeps the bare mark. Scanning scalars keeps this
    /// consistent with ``splitLines(_:)``'s character model.
    private static func trimHorizontal<S: StringProtocol>(_ s: S) -> String {
        var scalars = Substring(s).unicodeScalars
        while let first = scalars.first, first == " " || first == "\t" { scalars = scalars.dropFirst() }
        while let last = scalars.last, last == " " || last == "\t" { scalars = scalars.dropLast() }
        var out = ""
        out.unicodeScalars.append(contentsOf: scalars)
        return out
    }

    /// Standard IEEE CRC-32 (reflected, polynomial `0xEDB88320`, init/xorout
    /// `0xFFFFFFFF`) — the algorithm `crc32fast` implements, so ``hashLine(_:)``
    /// matches the Rust crate bit-for-bit.
    private static let crc32Table: [UInt32] = (0..<256).map { index in
        var c = UInt32(index)
        for _ in 0..<8 {
            c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
        }
        return c
    }

    private static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            let index = Int((crc ^ UInt32(byte)) & 0xff)
            crc = crc32Table[index] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}
