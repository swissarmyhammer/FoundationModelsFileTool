---
depends_on:
- 01KXJWMBD3KHJRTDMAVE1V3F9R
position_column: todo
position_ordinal: 8c80
title: CLI driver wiring (file-demo default mode)
---
## What
Per plan.md §7 first bullet. Wire `OperationCLIDriver` over the fused tool in `Examples/FileDemo/Sources/file-demo/main.swift` (default CLI mode only; `--chat`/`--script` are a later task):
- Grammar `<noun> <verb>` from the stock driver: `file-demo file read --path … --offset 60`, `file-demo files glob --pattern 'Sources/**/*.swift'`, `file-demo file edit --file-path … --find … --replace …`
- Exit codes: corrective outcome → nonzero with the message; JSON printing of typed outputs

## Acceptance Criteria
- [ ] Every op invocable from the CLI against a real directory
- [ ] argv → payload equals the model-path payload for every op (upstream's convergence contract)

## Tests
- [ ] `Tests/FileToolTests/CLIDriverTests.swift`: argv round-trip per op vs `AnyOperation` payload; help snapshot; unknown noun/verb did-you-mean; corrective exit code
- [ ] Run `swift test --filter CLIDriverTests` — expect: green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.