---
depends_on:
- 01KXJWHHWPYHXD78T104RVX7K6
- 01KXJWKBK3F6QH05RQS0EFWS09
- 01KXJWJCQ18DR0R8TQJKA3VK4W
- 01KXJWJMT7M4ZND37N6RJ50YX5
- 01KXJWKVHSPFD5TYG8B1CRX7KF
position_column: todo
position_ordinal: 8b80
title: 'Tool fusion: FileTool.make(), op inference hook, aliases, read-only variant'
---
## What
Per plan.md §3 vocabulary + §6 decisions 1–2. Create `Sources/FileTool/FileTool.swift`:
- `FileTool.make(context:)` fusing the five `@Operation` structs into one `OperationTool` named `"files"` (description: "File operations for reading, writing, editing, and searching files.")
- `FileTool.makeReadOnly(context:)` — fuses read/glob/grep only; `write file`/`edit file` → corrective "not available in read-only mode" (Rust `FileOperationSubset::ReadOnly` parity)
- Missing-`op` inference hook (upstream's opt-in closure), Rust precedence: edit-ish keys (`edits`, find-ish, replace-ish) → `edit file`; `content` → `write file`; `pattern` + grep-marker key (`caseInsensitive`/`contextLines`/`outputMode`) → `grep files`; `pattern` alone → `glob files`; `path` alone → `read file`; undeterminable → corrective naming all five ops
- Resolver alias declarations: `old_string`/`old`/`search`/`from`/`target`/`match` → `find`; `new_string`/`new`/`to`/`with`/`replacement` → `replace`; `absolute_path`/`file_path` ↔ `path`/`filePath` per op

## Acceptance Criteria
- [ ] All five ops dispatch through `AnyOperation` with typed outputs
- [ ] A verbatim sah-style snake_case payload (`{"op":"edit file","file_path":…,"old_string":…,"new_string":…}`) lands as a working edit
- [ ] Read-only tool rejects mutations with corrective messages and allows read/glob/grep

## Tests
- [ ] `Tests/FileToolTests/FileToolDispatchTests.swift`: dispatch per op; snake_case parity payloads; native-Edit-dialect (`old_string`/`new_string`) inference and aliasing; full inference matrix (every branch + undeterminable); read-only rejections + allowed ops; rendered schema contains exactly the five op strings
- [ ] Run `swift test --filter FileToolDispatchTests` — expect: green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.