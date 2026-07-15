---
depends_on:
- 01KXJWG0E2246T5Y42D8N71Z1G
position_column: todo
position_ordinal: '8280'
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
- [ ] Line hashes and whole-file tokens are bit-identical to the Rust crate on the golden vectors (cross-tool anchor dialect, plan risk §9.3)
- [ ] Anchor resolution honors the ±50 window exactly (resolves at ±50, fails at ±51)

## Tests
- [ ] `Tests/FileToolTests/HashlineTests.swift`: golden-vector parity; drift resolution at ±1/±50/±51; stale-anchor fall-through returns nil; `|text` verification and relocation; token stability across repeated hashing; empty file / empty line edge cases
- [ ] Run `swift test --filter HashlineTests` — expect: green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.