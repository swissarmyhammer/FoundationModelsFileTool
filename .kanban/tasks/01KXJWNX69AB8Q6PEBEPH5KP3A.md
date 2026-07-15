---
depends_on:
- 01KXJWMRY1WHKFH4PNT731KY99
- 01KXJWNFZ106SY3N2BWZKC0QPS
position_column: todo
position_ordinal: 8f80
title: file-demo --chat and --script modes
---
## What
Per plan.md §7. Extend `Examples/FileDemo/Sources/file-demo/`:
- `--chat`: a `LanguageModelSession` with the fused tool, availability-gated (skips gracefully without Apple Intelligence). Scripted prompts drive: read a file → edit by anchor → `diagnostics: clean`; a deliberately type-breaking edit → model sees the compiler error in the tool result → prompted to fix it. Reports op-call accuracy, rendered schema size via `tokenCount(for:)`, and retry-cap behavior on a denied path (`../../etc/passwd` → corrective → model corrects)
- `--script`: reads op lines (JSON payloads) from stdin, executes sequentially in one process, prints typed outputs — the human-driven twin of the integration tests

## Acceptance Criteria
- [ ] `swift run file-demo --script` executes a piped read→edit→read sequence against a temp dir and prints valid JSON per op
- [ ] `swift run file-demo --chat` runs the scripted harness end-to-end on a machine with Apple Intelligence (manual, availability-gated) and skips cleanly otherwise

## Tests
- [ ] `Tests/FileToolIntegrationTests/ScriptModeTests.swift`: spawn `file-demo --script` with a piped op sequence in an isolated dir; assert JSON outputs and file state
- [ ] Run `swift test --filter ScriptModeTests` — expect: green (chat mode is manual-run but scripted; not a CI gate)

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.