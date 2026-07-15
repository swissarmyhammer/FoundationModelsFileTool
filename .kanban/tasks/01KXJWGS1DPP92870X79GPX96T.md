---
comments:
- actor: claude-code
  id: 01kxk5mj2mpjtzh93tbysrk941
  text: Picked up by /finish. Scaffolding dep (8n71z1g) is done; build/test green baseline. Algorithm-exact port of ../swissarmyhammer/crates/swissarmyhammer-hashline with golden-vector fixtures. Starting implement→test→commit→review loop.
  timestamp: 2026-07-15T15:17:00.628217+00:00
- actor: claude-code
  id: 01kxk5vxj2mncegbm2tc5xqyr9
  text: 'Research done. Read swissarmyhammer-hashline src (lib.rs, line_ending.rs, properties.rs). Algorithm confirmed: per-line hash = crc32fast (IEEE CRC-32) over the line trimmed of leading/trailing space+tab, masked to low byte (& 0xff), rendered 2-hex lowercase via {:02x}. tag() splits content into (text, terminator) preserving \n/\r\n/\r/"" and emits "N:HH|text"+terminator with absolute 1-based N. parse_anchor strips optional |text suffix, splits on first '':'', requires non-empty numeric line + exactly-2-hex hash. resolve = exact line (1-based, line 0 => no exact), then symmetric proximity search delta 1..=50 (+delta then -delta each step), nearest hash-match wins, text (trimmed compare) preferred over merely-hash-matching. wholeFileHash is NOT in the hashline crate; it lives in swissarmyhammer-tools shared_utils::whole_file_hash = format!("{:x}", md5::compute(bytes)) (MD5 hex, lowercase, 32 chars) -> CryptoKit Insecure.MD5 in Swift. Plan: generate golden vectors via a throwaway example in the hashline crate (uses crate fns + md5 for whole-file), dump JSON, then revert the swissarmyhammer repo. TDD the Swift Hashline.swift against the golden fixtures.'
  timestamp: 2026-07-15T15:21:01.762221+00:00
- actor: claude-code
  id: 01kxk69dnthsv5r52smt53bg45
  text: |-
    Implemented (TDD, red-green). Landed Sources/FileTool/Hashline.swift: hashLine (IEEE CRC-32 table impl over space/tab-trimmed UTF-8 bytes, &0xff), renderHash (%02x), tag(lines:startLine:) (scalar-based split_lines preserving \n/\r\n/\r/mixed + trailing terminator; scalar scan avoids Swift's \r\n grapheme-cluster gotcha), wholeFileHash(bytes:) (CryptoKit Insecure.MD5 -> 32 lowercase hex, matches Rust format!("{:x}", md5::compute)), parseAnchor, resolveAnchor(_:in:) (string form parsing |text) + resolveAnchorIn core mirroring Rust resolve_index (symmetric delta 1..=50, nearest hash, text preferred, line 0 => no exact candidate).

    Golden vectors: wrote a throwaway examples/golden.rs in the Rust hashline crate (dev-deps md5+serde_json), ran `cargo run --example golden`, captured JSON to Tests/FileToolTests/Fixtures/hashline-golden.json, then reverted the swissarmyhammer repo (Cargo.toml, Cargo.lock, example) — swissarmyhammer left byte-clean. Fixture covers hashLine (incl. whitespace/interior/unicode/empty), tag (LF/CRLF/CR/mixed/trailing/startLine), wholeFileHash (incl. empty), parseAnchor (valid + all Rust rejection cases), resolveAnchor (drift, stale, |text tie/relocate, empty, line-0 edge, and the ±50 resolves / ±51 fails window boundary auto-verified in Rust).

    Package.swift: added resources:[.copy("Fixtures")] to FileToolTests; tests load via Bundle.module.

    Tests: `swift test --filter HashlineTests` = 14/14 green. Full `swift test` = 15 tests FileToolTests suite + 1 integration scaffold, all green, no source warnings. Running advisory double-check, then leaving task in doing for /review.
  timestamp: 2026-07-15T15:28:24.250181+00:00
- actor: claude-code
  id: 01kxk777885v29kytygw7q48dg
  text: 'Advisory double-check returned REVISE with two LOW-severity exactness divergences (both outside the tool-emitted [0-9]+:[0-9a-f]{2} dialect, both unpinned): (1) parseAnchor''s digit-only guard rejects a leading ''+'' that Rust usize::parse reportedly accepts; (2) trimHorizontal trims by grapheme (Character) while Rust trim_matches trims by scalar (char) — divergent on whitespace immediately followed by a combining mark. Because the task bar is algorithm-EXACT/bit-for-bit, I''m fixing both rather than logging a justification. Approach: regenerate the golden fixture from the Rust crate WITH new edge cases (sign-prefixed line numbers +42/-42, and a leading-space+combining-mark hashLine case) so Rust — not the double-check''s assertion — is the oracle for what ''+42:a3'' should parse to; then fix Swift trimHorizontal to scalar-level and parseAnchor to match Rust, TDD red->green against the regenerated fixture.'
  timestamp: 2026-07-15T15:44:40.712073+00:00
- actor: claude-code
  id: 01kxk7dz30tcddxw3agdytq4fc
  text: |-
    Both double-check findings FIXED and pinned (not justified away). Regenerated hashline-golden.json from the Rust crate with new edge cases; Rust's actual output confirmed both findings real: parse_anchor("+42:a3") = Some((42,0xa3)) and ("+255:ff")=Some((255,255)) — Rust usize::from_str DOES accept a leading '+' — while "-42:a3", " 42:a3", "42 :a3" all = None; and hash_line(" ́x") == hash_line("́x") == 50, proving Rust trims the leading space scalar (grapheme-trim would not). Fixes: (1) parseAnchor now allows one optional leading '+' then ASCII digits, rejects '-'/whitespace/non-digits — matches Rust; (2) trimHorizontal now scans unicodeScalars (per-scalar, like Rust char and like splitLines) instead of grapheme Characters. Added two named regression tests plus the new golden rows.

    Justification for not re-spawning double-check a second time (bounded-loop contract allows at most one re-check): both findings were resolved using the Rust crate ITSELF as oracle — the regenerated golden vectors ARE Rust's output, which is stronger evidence than a second opinion. A second 14-min adversarial pass would not add signal.

    Fixture now: 28 hashLine, 19 parseAnchor, 14 resolveAnchor, 12 tag, 7 wholeFileHash = 80 golden vectors. Verification: `swift test --filter HashlineTests` = 16/16 green; full `swift test` = 17 (FileToolTests) + 1 (integration) green, no source warnings. swissarmyhammer repo reverted byte-clean (git status empty). Leaving task in doing for /review.
  timestamp: 2026-07-15T15:48:21.728560+00:00
- actor: claude-code
  id: 01kxk7fa1dpgq8jq54sfrryece
  text: 'Iteration 1: implement landed green. Sources/FileTool/Hashline.swift ported bit-exact from the Rust crate. KEY DISCOVERY: the per-line "hash" is NOT a cryptographic hash — it is a table-based IEEE CRC-32 (poly 0xEDB88320) over the line trimmed of leading/trailing space+tab, masked to the low byte, rendered %02x. Whole-file token IS MD5 (CryptoKit Insecure.MD5, 32-char lowercase hex). Line splitter scans Unicode SCALARS (not Characters) so \r\n isn''t collapsed. 80 golden vectors generated from the Rust crate via a throwaway examples/golden.rs (swissarmyhammer repo reverted byte-clean afterward, git status empty). Adversarial double-check caught two exactness divergences (parseAnchor must accept leading ''+'' like Rust usize::from_str; trim must be per-scalar not per-grapheme) — both fixed against the Rust oracle. swift test --filter HashlineTests 16/16; full swift test green. Package.swift FileToolTests target gained resources:[.copy("Fixtures")]. Left in doing → /test → /commit → /review.'
  timestamp: 2026-07-15T15:49:05.709646+00:00
- actor: claude-code
  id: 01kxk86h50dvp3e92d26dcxc7k
  text: 'Iteration 1 review: 11 findings, all confirmed → task in review. Two mechanical themes in Sources/FileTool/Hashline.swift: (1) missing explicit `public` on symbols Package.swift documents as library API (Hashline enum, proximityWindow, renderHash, tag, wholeFileHash, resolveAnchor, resolveAnchorIn — all default internal); (2) forbidden abbreviations: `num`→`number`, three `idx` params in nested helpers hashMatches/textMatches/text(upTo:)→`index`. No contradictions. Looping to /implement iteration 2 to fix at root (make ALL library-API symbols public across the file; eliminate ALL abbreviations, not just cited lines).'
  timestamp: 2026-07-15T16:01:46.656249+00:00
- actor: claude-code
  id: 01kxk8bd1mn8e8gq82ya3ex0wx
  text: |-
    Iteration 2 pickup (review->doing). Working the 11 confirmed findings at root across the whole file.

    Public-visibility audit: all 7 top-level `static func`s in the Hashline enum are intended-public library API (Package.swift documents Hashline as embeddable). The reviewer cited renderHash/tag/wholeFileHash/resolveAnchor/resolveAnchorIn + the enum + proximityWindow, but NOT hashLine/parseAnchor. Cross-checked the Rust crate being ported: hash_line, render_hash, tag, parse_anchor, resolve_anchor_in are ALL `pub`. hashLine is the peer of the already-public renderHash; parseAnchor is the peer of the already-public resolveAnchor. To make a re-review find zero recurrences (per orchestrator instruction to audit the ENTIRE file), marking hashLine and parseAnchor public too. Genuinely-internal helpers (resolveIndex, Line, splitLines, trimHorizontal, crc32Table, crc32) are already `private` and stay private.

    Abbreviations: num->number (3 sites in parseAnchor), idx->index (hashMatches, textMatches, text(upTo:)). Swept rest of file: remaining short names (i, c, n, s, out, crc) are conventional single-letter/idiom/acronym, not idx/num/tmp-style truncations — left as-is (reviewer applied same rule and flagged only num/idx). Pure visibility/naming changes; zero hashing/anchor logic or golden-fixture changes.
  timestamp: 2026-07-15T16:04:26.292901+00:00
- actor: claude-code
  id: 01kxk8q3h570vepxmt0n7dhb9p
  text: |-
    Iteration 2 done, green. All 11 review findings fixed at root in Sources/FileTool/Hashline.swift and flipped to [x]:
    - Visibility: Hashline enum + proximityWindow + all 7 top-level static funcs now explicitly `public` (hashLine/renderHash/tag/wholeFileHash/parseAnchor/resolveAnchor/resolveAnchorIn). Beyond the 7 cited, hashLine and parseAnchor were also marked public (both `pub` in the Rust crate; peers of already-public renderHash/resolveAnchor) so a re-review finds zero recurrences. Internal helpers (resolveIndex, Line, splitLines, trimHorizontal, crc32Table, crc32) stay `private`.
    - Naming: num->number (3 sites), idx->index (hashMatches/textMatches/text(upTo:)). Whole-file sweep confirms no idx/num/tmp-style abbreviations remain.

    Pure visibility/naming diff — no hashing/anchor/CRC/MD5/split-lines/trim logic changed, golden fixture untouched. Verification: `swift test --filter HashlineTests` = 16/16 green; full `swift test` = 17 (FileToolTests) + 1 (integration) green, no source warnings. All 5 golden-vector parity tests (hashLine/tag/wholeFileHash/parseAnchor/resolveAnchor) pass bit-exact. Advisory double-check returned PASS (confirmed pure refactor, no behavioral drift, no scope creep). Leaving in doing for /review.
  timestamp: 2026-07-15T16:10:49.765701+00:00
- actor: claude-code
  id: 01kxk8qpp1t5e8edvz2kxe27cz
  text: 'Iteration 2: all 11 findings fixed at root in Hashline.swift (pure visibility+naming, zero logic change). Made public: Hashline enum, proximityWindow, hashLine, renderHash, tag, wholeFileHash, parseAnchor, resolveAnchor, resolveAnchorIn (added hashLine+parseAnchor beyond the 7 cited — both pub in the Rust crate, so re-review finds zero recurrences). Kept helpers private (resolveIndex, Line, splitLines, trimHorizontal, crc32Table, crc32). Naming: num→number (3), idx→index (3 helpers); whole-file sweep clean. Golden fixture untouched (git diff confirms), all 5 parity tests pass. swift test --filter HashlineTests 16/16, full suite green. Left in doing → /test → /commit → /review.'
  timestamp: 2026-07-15T16:11:09.377276+00:00
- actor: claude-code
  id: 01kxk9d7twbc0ktdgh8zfpsd7a
  text: 'Iteration 2 review: prior 11 findings all verified resolved [x]. 9 NEW findings surfaced (all confirmed), all doc/naming on now-public API in Hashline.swift — exposed BECAUSE iteration 2 made symbols public (public API demands complete DocC): renderHash missing -Returns:/param doc; parseAnchor param `s`→descriptive (e.g. anchorString) + missing -Returns:/param doc; resolveAnchor missing -Returns:/-Parameters:; resolveAnchorIn missing -Returns:/-Parameters:. These are distinct from the prior 11 (guardrail tracks same finding 3× — not tripped). Looping to /implement iteration 3: add complete DocC to all public symbols and rename abbreviated params at root.'
  timestamp: 2026-07-15T16:22:55.068311+00:00
- actor: claude-code
  id: 01kxk9ns1rvz68p13sqm13tg07
  text: |-
    Iteration 3 done, green. All 9 "Review Findings (2026-07-15 11:12)" fixed at root in Sources/FileTool/Hashline.swift and flipped to [x]. Pure DocC + parameter-name diff; zero hashing/anchor/CRC/MD5/split/trim logic changed; golden fixture untouched (git status confirms only Hashline.swift changed).

    Audited EVERY public symbol, not just cited ones. Added complete DocC (summary + per-parameter doc + `- Returns:` on non-Void):
    - renderHash: added `- Parameter hash:` + `- Returns:` (was summary-only).
    - parseAnchor: renamed param `s`→`anchorString` (unlabeled `_`, so no call-site/label change) and updated both internal refs; added `- Parameter anchorString:` + `- Returns:` (moved the "nil for malformed" rule into the Returns block).
    - resolveAnchor: added `- Parameters:` (anchor, content) + `- Returns:`.
    - resolveAnchorIn: added `- Parameters:` (content, line, hash, text) + `- Returns:`.
    Already-complete symbols left as-is: Hashline enum, proximityWindow (no params/return), hashLine, tag, wholeFileHash. Swept for other single-letter/abbreviated params on public API — only `s` qualified; internal helpers (crc32's `c`, tag's `n`/`out`, trimHorizontal's `s`) are private, not public API, left untouched per prior-iteration scope.

    Verification: `swift test --filter HashlineTests` = 16/16 green (all 5 Rust golden-vector parity tests pass bit-exact: hashLine/tag/wholeFileHash/parseAnchor/resolveAnchor). Full `swift test` = 17 (FileToolTests) + 1 (integration) green. No source warnings (the mlx-swift bundle build-system warning is pre-existing/unrelated). Advisory double-check returned PASS (confirmed docs-only + rename, no behavioral drift, golden fixture untouched). Leaving task in doing for /review.
  timestamp: 2026-07-15T16:27:34.840246+00:00
- actor: claude-code
  id: 01kxk9pc53gn8ke51xqy245m81
  text: 'Iteration 3: all 9 doc/naming findings fixed at root in Hashline.swift (DocC + one internal param rename, zero logic change). Added -Parameter/-Returns to renderHash, parseAnchor, resolveAnchor, resolveAnchorIn; renamed unlabeled param s→anchorString (no external label change). Verified Hashline enum/proximityWindow/hashLine/tag/wholeFileHash already fully documented. Remaining short names (c/n/out/s) are all on private helpers, not public API. Golden fixture untouched (git confirms only Hashline.swift + kanban changed); all 5 parity tests pass. swift test --filter HashlineTests 16/16, full suite green, double-check PASS. Left in doing → /test → /commit → /review.'
  timestamp: 2026-07-15T16:27:54.403265+00:00
- actor: claude-code
  id: 01kxka8b5864abfhk62ha13sm2
  text: |-
    Iteration 3 review: all 18 prior findings verified resolved. 9 NEW confirmed findings: (1) 7× DocC first-line rule — summary line on public symbols (Hashline, proximityWindow, renderHash, wholeFileHash, parseAnchor, resolveAnchor, resolveAnchorIn) must be a complete sentence ending in a period before any elaboration (stricter than iter-2's -Returns/-Parameters rule, same symbols); (2) 2× reuse: literal "|" anchor delimiter hardcoded in parseAnchor + resolveAnchor → named constant; 0xFFFF_FFFF hardcoded twice in crc32 → named constant.

    GUARDRAIL WATCH: 3rd review round with findings, but messages are distinct each round (no identical file:line+message recurring 3×) and every iteration makes real progress → guardrail NOT tripped. Doc comments have now been flagged in iter 2 AND iter 3 under different DocC rules. Iteration 4 will make DocC on every public symbol FULLY convention-compliant in one pass (complete-sentence summary ending in period → blank line → -Parameters/-Returns) and extract both magic literals, to converge. If iter-4 re-review surfaces yet more doc nits on these same symbols, I will treat the doc-comment area as effectively recurring and escalate to the user rather than loop further.
  timestamp: 2026-07-15T16:37:43.208507+00:00
- actor: claude-code
  id: 01kxkakjgg57bd2fp1mqh021ec
  text: |-
    Iteration 4 (review->doing). All 9 "Review Findings (2026-07-15 11:29)" fixed at root in Sources/FileTool/Hashline.swift and flipped to [x]. Pure DocC + named-constant-extraction diff; ZERO hashing/anchor/CRC/MD5/split/trim behavior changed; golden fixture untouched (git diff --stat on hashline-golden.json is empty).

    Per orchestrator instruction, brought EVERY public symbol's DocC to full convention compliance in one pass (not just the 7 cited), plus the private helpers, so a re-review is clean:
    - First-line rule (complete sentence ending in a period, then blank ///): Hashline enum, proximityWindow, renderHash, wholeFileHash, parseAnchor, resolveAnchor, resolveAnchorIn (the 7 cited) AND the private resolveIndex, Line, trimHorizontal. hashLine, tag, splitLines already conformed and were left as-is. All public symbols now have complete-sentence summary -> blank /// -> discussion -> `- Parameter(s):` -> `- Returns:` (non-Void) uniformly.
    - Named constants (exact same values, kept private): `anchorTextDelimiter: Character = "|"` replaces the hardcoded "|" in parseAnchor + resolveAnchor; `crc32XorOut: UInt32 = 0xFFFF_FFFF` replaces both hardcoded 0xFFFF_FFFF in crc32 (init seed + final xorout). crc32Table doc now references ``crc32XorOut``.

    Verification: `swift test --filter HashlineTests` = 16/16 green; all 5 Rust golden-vector parity tests (hashLine/tag/wholeFileHash/parseAnchor/resolveAnchor) pass bit-exact. Full `swift test` = 17 (FileToolTests) + 1 (integration) green, no source warnings. git status: only Hashline.swift + kanban files modified. Leaving task in doing for /review.
  timestamp: 2026-07-15T16:43:51.184254+00:00
- actor: claude-code
  id: 01kxkapk3776y5bpncmea5bccn
  text: 'Iteration 4: all 9 findings fixed at root, exhaustively. DocC first-line convention applied to EVERY symbol (7 cited public + private helpers resolveIndex/Line/trimHorizontal for uniformity; hashLine/tag/splitLines already conformed): complete-sentence summary ending in period → blank /// → discussion → -Parameter(s) → -Returns. Extracted private constants (exact same values): anchorTextDelimiter: Character = "|" (replaces hardcoded "|" in parseAnchor+resolveAnchor); crc32XorOut: UInt32 = 0xFFFF_FFFF (replaces both hardcoded uses in crc32). Comment-stripped structural diff (double-check PASS) confirms only 5 intended executable-code deltas, zero behavior change. Golden fixture untouched (git diff --stat empty), all 5 parity tests pass. swift test --filter HashlineTests 16/16, full suite green. Left in doing → /test → /commit → /review.'
  timestamp: 2026-07-15T16:45:30.087317+00:00
- actor: claude-code
  id: 01kxkb526gbbmeajvn4jhr2xm5
  text: 'Iteration 4 review: all prior findings (3 sections: 11/9/9) verified resolved [x]. DocC doc-comment area STABILIZED — 0 doc findings this round; the escalation trigger I set (doc nits recurring on same symbols) did NOT fire. 2 new confirmed findings, both spillover from iteration 4''s own constant extraction: (1) Hashline.swift:56 magic-number `2` (hash hex-digit count) repeated in renderHash format spec + parseAnchor hex.count==2 → extract `private static let hashHexDigits = 2`; (2) Hashline.swift:305 acronym casing crc32XorOut → crc32XOROut (interior acronyms must be all-uppercase in lowerCamelCase, cf entryID/schemaJSON). Distinct from all prior findings, converging. Looping to /implement iteration 5.'
  timestamp: 2026-07-15T16:53:24.304153+00:00
- actor: claude-code
  id: 01kxkbd17jgw67wk61cmj54tww
  text: |-
    Iteration 5 (review->doing). Both "Review Findings (2026-07-15 11:47)" fixed at root in Sources/FileTool/Hashline.swift and flipped to [x]. Pure naming + constant-extraction diff; ZERO hashing/anchor/CRC/MD5/split/trim behavior changed; values identical (2, 0xFFFF_FFFF). Golden fixture untouched.

    Finding 1 (magic-number 2): extracted `private static let hashHexDigits = 2`. renderHash now builds its format string from it (`String(format: "%0\(hashHexDigits)x", hash)`) so the literal `2` is not repeated; parseAnchor uses `hex.count == hashHexDigits`. Swept the file for the same "2 hex digits" coupling: the only other `%02x` is in wholeFileHash, which renders each MD5 digest byte (a 128-bit hash) as 2 hex chars — the universal byte->2-hex rendering, NOT the anchor-hash width. Routing it through hashHexDigits would be a false coupling (if the anchor width changed, MD5 bytes would still be 2 hex each), so it was intentionally left as-is and the constant's doc scopes it to the anchor hash.

    Finding 2 (acronym casing): renamed `crc32XorOut` -> `crc32XOROut` at all four sites (declaration, DocC ``reference``, both uses in crc32()). Grep confirms zero lingering `crc32XorOut`. Swept the file for other interior-acronym-casing violations: none (crc32Table/crc32 use crc as the leading lowercase word, correct in lowerCamelCase; no Md5/Json/Url/Id mixed-case identifiers; Insecure.MD5 is external API).

    Verification: `swift test --filter HashlineTests` = 16/16 green (all 5 Rust golden-vector parity tests pass bit-exact); full `swift test` = 17 (FileToolTests) + 1 (integration) green, no source warnings. git status: only Hashline.swift + kanban files modified; hashline-golden.json diff empty. Advisory double-check running; leaving task in doing for /review.
  timestamp: 2026-07-15T16:57:45.458273+00:00
- actor: claude-code
  id: 01kxkbdsv2ees5ye7g0zbsktyz
  text: 'Iteration 5: both findings fixed at root (pure naming + constant extraction, zero behavior change). (1) Extracted `private static let hashHexDigits = 2`; renderHash builds format via String(format: "%0\(hashHexDigits)x", ...), parseAnchor uses hex.count == hashHexDigits. Correctly LEFT wholeFileHash''s %02x alone — that''s the universal byte→2-hex MD5 digest rendering, not the anchor-hash width; routing it through hashHexDigits would be a false coupling (good judgment). (2) crc32XorOut → crc32XOROut at all 4 sites; grep confirms zero lingering; no other interior-acronym violations. Golden fixture untouched, all 5 parity tests bit-exact. swift test --filter HashlineTests 16/16, full suite green, double-check PASS. Left in doing → /test → /commit → /review.'
  timestamp: 2026-07-15T16:58:10.658469+00:00
depends_on:
- 01KXJWG0E2246T5Y42D8N71Z1G
position_column: doing
position_ordinal: '80'
title: Hashline module (algorithm-exact port)
---
## What
Per plan.md §3 "Hashline". Create `Sources/FileTool/Hashline.swift`, an algorithm-exact port of `../swissarmyhammer/crates/swissarmyhammer-hashline`:
- `tag(lines:startLine:)` → `N:HH|text` (absolute 1-based line + 2-hex-char line-content hash)
- `wholeFileHash(bytes:)` → lowercase-hex MD5 `#hash:` freshness token (CryptoKit `Insecure.MD5`)
- `parseAnchor(_:)` for `N:HH` and `N:HH|text` forms
- `resolveAnchor(_:in:)` — exact line, else nearest line within ±50-line proximity window hashing to `HH`; `|text` suffix verifies/relocates; unresolvable → nil (caller falls through to literal)

Generate golden-vector fixtures from the Rust crate (small program or test dump in ../swissarmyhammer) and check them into `Tests/FileToolTests/Fixtures/hashline-golden.json`.

## Acceptance Criteria
- [x] Line hashes and whole-file tokens are bit-identical to the Rust crate on the golden vectors (cross-tool anchor dialect, plan risk §9.3)
- [x] Anchor resolution honors the ±50 window exactly (resolves at ±50, fails at ±51)

## Tests
- [x] `Tests/FileToolTests/HashlineTests.swift`: golden-vector parity; drift resolution at ±1/±50/±51; stale-anchor fall-through returns nil; `|text` verification and relocation; token stability across repeated hashing; empty file / empty line edge cases
- [x] Run `swift test --filter HashlineTests` — expect: green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

## Review Findings (2026-07-15 10:51)

- [x] `Sources/FileTool/Hashline.swift:5` — The `Hashline` enum is documented in Package.swift as part of the library's public API ("Core library: … `Hashline`, `EditEngine`, `AtomicWriter` … Exposed so downstream tools … can embed the operations directly"), but has no explicit `public` access modifier and defaults to `internal`. Public library symbols must be explicitly marked. Mark the enum `public enum Hashline {`.
- [x] `Sources/FileTool/Hashline.swift:14` — `proximityWindow` is a static member of the public API enum and is referenced in documentation, but has no explicit `public` access modifier. Public library symbols must be explicitly marked. Mark with `public static let proximityWindow = 50`.
- [x] `Sources/FileTool/Hashline.swift:33` — `renderHash(_:)` is part of the public Hashline API but lacks explicit `public` access. Public library functions must be explicitly marked. Mark with `public static func renderHash(_ hash: UInt8) -> String`.
- [x] `Sources/FileTool/Hashline.swift:42` — `tag(lines:startLine:)` is part of the public Hashline API but lacks explicit `public` access. Public library functions must be explicitly marked. Mark with `public static func tag(lines content: String, startLine: Int) -> String`.
- [x] `Sources/FileTool/Hashline.swift:57` — `wholeFileHash(bytes:)` is part of the public Hashline API but lacks explicit `public` access. Public library functions must be explicitly marked. Mark with `public static func wholeFileHash(bytes: Data) -> String`.
- [x] `Sources/FileTool/Hashline.swift:86` — The variable `num` abbreviates 'number' and sacrifices clarity for brevity. The rule explicitly forbids such abbreviations; the full word must be used. Rename to `number` or `numberString`: `let number = anchor[anchor.startIndex..<colon]`.
- [x] `Sources/FileTool/Hashline.swift:89` — `resolveAnchor(_:in:)` is part of the public Hashline API (the public string-form entry point) but lacks explicit `public` access. Public library functions must be explicitly marked. Mark with `public static func resolveAnchor(_ anchor: String, in content: String) -> Int?`.
- [x] `Sources/FileTool/Hashline.swift:101` — `resolveAnchorIn(_:line:hash:text:)` is part of the public Hashline API but lacks explicit `public` access. Public library functions must be explicitly marked. Mark with `public static func resolveAnchorIn(_ content: String, line: Int, hash: UInt8, text: String?) -> Int?`.
- [x] `Sources/FileTool/Hashline.swift:120` — The parameter `idx` in the nested `hashMatches(_:)` function is an abbreviation that violates the naming-clarity rule. The rule explicitly forbids `idx`; the full word `index` must be used for clarity. Rename parameter to `index`: `func hashMatches(_ index: Int) -> Bool { index >= 0 && index < lines.count && hashLine(lines[index]) == hash }`.
- [x] `Sources/FileTool/Hashline.swift:123` — The parameter `idx` in the nested `textMatches(_:)` function is an abbreviation that violates the naming-clarity rule. The rule explicitly forbids `idx`; the full word `index` must be used for clarity. Rename parameter to `index`: `func textMatches(_ index: Int) -> Bool { guard let wanted = text, index >= 0, index < lines.count else { return false } return trimHorizontal(lines[index]) == trimHorizontal(wanted) }`.
- [x] `Sources/FileTool/Hashline.swift:176` — The parameter `idx` in the nested `text(upTo:)` function inside `splitLines(_:)` is an abbreviation that violates the naming-clarity rule. The rule explicitly forbids `idx`; the full word `index` must be used. Rename parameter to `index`: `func text(upTo index: String.UnicodeScalarView.Index) -> String { String(String.UnicodeScalarView(scalars[lineStart..<index])) }`.

## Review Findings (2026-07-15 11:12)

- [x] `Sources/FileTool/Hashline.swift:37` — `renderHash` returns `String` (non-Void) but has no `- Returns:` block; rule states '`- Returns:` appears iff the result is non-`Void`'. Add `- Returns:` section: `- Returns: two lowercase hexadecimal characters.`.
- [x] `Sources/FileTool/Hashline.swift:37` — `renderHash` has parameter `hash` but no formal parameter documentation; inconsistent with `hashLine` and `wholeFileHash` which include parameter docs. Add `- Parameter hash:` documentation.
- [x] `Sources/FileTool/Hashline.swift:68` — Parameter `s` in public API is abbreviated; should be descriptive per refactor goal to 'clarify parameter names'. Rename parameter `s` to `anchorString` or `input`.
- [x] `Sources/FileTool/Hashline.swift:68` — `parseAnchor` returns non-Void `(line: Int, hash: UInt8)?` but has no `- Returns:` block. Add `- Returns:` section describing the returned tuple.
- [x] `Sources/FileTool/Hashline.swift:68` — `parseAnchor` has parameter but no formal parameter documentation; inconsistent with other functions that document parameters. Add parameter documentation for anchor string input.
- [x] `Sources/FileTool/Hashline.swift:86` — `resolveAnchor` returns non-Void `Int?` but has no `- Returns:` block. Add `- Returns:` section.
- [x] `Sources/FileTool/Hashline.swift:86` — `resolveAnchor` has two parameters but no formal `- Parameters:` block; inconsistent with `tag` function (line 42) which documents its parameters. Add `- Parameters:` block documenting both parameters.
- [x] `Sources/FileTool/Hashline.swift:97` — `resolveAnchorIn` returns non-Void `Int?` but has no `- Returns:` block. Add `- Returns:` section.
- [x] `Sources/FileTool/Hashline.swift:97` — `resolveAnchorIn` has four parameters but no formal `- Parameters:` block; inconsistent with other multi-parameter functions. Add `- Parameters:` block documenting all four parameters.

## Review Findings (2026-07-15 11:29)

- [x] `Sources/FileTool/Hashline.swift:14` — Documentation for public enum `Hashline` does not follow the first-line-ending rule — the opening line should be a complete sentence ending with a period before elaboration continues. Rewrite the summary to be concise and complete on the first line with a period: `/// Pure, IO-free hashline anchor primitives for line tagging and drift-tolerant resolution.` Then follow with detailed explanation after a blank line.
- [x] `Sources/FileTool/Hashline.swift:16` — Documentation for public constant `proximityWindow` does not follow the first-line-ending rule — the opening line should be a complete sentence ending with a period before elaboration continues. Rewrite the summary to be concise and complete on the first line, ending with a period: `/// The maximum proximity window used to locate drifted anchors (lines on each side).` Then follow with elaboration after a blank line if needed.
- [x] `Sources/FileTool/Hashline.swift:36` — Documentation for public function `renderHash` does not follow the first-line-ending rule — the opening line should be a complete sentence ending with a period before elaboration continues. Rewrite the summary to be concise and complete on the first line with a period: `/// Render a hash byte as a two-character lowercase hexadecimal string.` Then place examples after a blank line if needed.
- [x] `Sources/FileTool/Hashline.swift:60` — Documentation for public function `wholeFileHash` does not follow the first-line-ending rule — the opening line should be a complete sentence ending with a period before elaboration continues. Rewrite the summary to be concise and complete on the first line with a period: `/// Compute the whole-file MD5 freshness token as a lowercase hex string.` Then follow with elaboration after a blank line.
- [x] `Sources/FileTool/Hashline.swift:71` — Documentation for public function `parseAnchor` does not follow the first-line-ending rule — the opening line should be a complete sentence ending with a period before elaboration continues. Rewrite the summary to be concise and complete on the first line with a period: `/// Parse a hashline anchor in the \`N:HH\` format.` Then follow with details about the return value and suffix handling after a blank line.
- [x] `Sources/FileTool/Hashline.swift:99` — Documentation for public function `resolveAnchor` does not follow the first-line-ending rule — the opening line should be a complete sentence ending with a period before elaboration continues. Rewrite the summary to be concise and complete on the first line with a period: `/// Resolve a hashline anchor against content, tolerating drift.` Then follow with detailed behavior after a blank line.
- [x] `Sources/FileTool/Hashline.swift:108` — The anchor format delimiter `"|"` is hardcoded and repeated across two functions (parseAnchor line 108 and resolveAnchor line 146). This literal should be a named constant so the format's delimiter is centrally defined and changes happen in one place. Extract to a module-level constant: `private static let anchorTextDelimiter = "|"` and use it in both functions.
- [x] `Sources/FileTool/Hashline.swift:116` — Documentation for public function `resolveAnchorIn` does not follow the first-line-ending rule — the opening line should be a complete sentence ending with a period before elaboration continues. Rewrite the summary to be concise and complete on the first line with a period: `/// Resolve a hashline anchor to a 1-based line number, tolerating drift.` Then follow with detailed resolution behavior after a blank line.
- [x] `Sources/FileTool/Hashline.swift:298` — The CRC-32 init/xorout value `0xFFFF_FFFF` is hardcoded and repeated within the crc32 function (lines 298 and 303). This magic number should be a named constant so the algorithm's parameters are defined once. Extract to a private constant: `private static let crc32XorOut: UInt32 = 0xFFFF_FFFF` and use it in both places.

## Review Findings (2026-07-15 11:47)

- [x] `Sources/FileTool/Hashline.swift:56` — The hexadecimal digit count `2` appears in two places (format specifier and parsing check) but should be a named constant. Both `renderHash` and `parseAnchor` enforce that the hash portion of an anchor is exactly 2 hex characters. If this format ever changes, both places must be updated together; extracting a constant makes this coupling explicit and reduces the risk of missing one location during a refactor. Extract `private static let hashHexDigits = 2` and use it in both locations. For the format string, either use conditional formatting or a helper function. For the count check, this is straightforward: `hex.count == hashHexDigits`.
- [x] `Sources/FileTool/Hashline.swift:305` — The acronym XOR in `crc32XorOut` is mixed-case (X upper, or lower), violating the rule that acronyms are never mixed-case. Interior acronyms in lowerCamelCase names should be all-uppercase per the examples provided (`entryID`, `generatedTokenIDs`, `schemaJSON`). Rename `crc32XorOut` to `crc32XOROut` to make the acronym uniformly all-uppercase.