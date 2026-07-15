---
depends_on:
- 01KXJWNX69AB8Q6PEBEPH5KP3A
position_column: todo
position_ordinal: '9080'
title: 'Docs: README, DocC, departures'
---
## What
Per plan.md §10 task 12. Write `README.md` (library-style: declare → fuse → session → CLI, with a runnable example; the diagnostics loop — edit → see compiler errors → fix — front and center), DocC comments on all public API in `Sources/FileTool/`, plan §8 departures cross-referenced in a DESIGN_NOTES section or file, and a note pointing at the upstream `DiagnosticsReport` visibility change.

## Acceptance Criteria
- [ ] README's usage snippet compiles (doc-snippet-tested against the example source, the siblings' mechanism)
- [ ] Every public type/method in `Sources/FileTool/` has a DocC comment (checked by the snippet test target compiling with documentation warnings surfaced)
- [ ] DESIGN_NOTES departures section exists and cross-references plan §8 items 1–8

## Tests
- [ ] `Tests/FileToolTests/ReadmeSnippetTests.swift`: extract the README code fence(s) and compile/assert against the example source (sibling mechanism)
- [ ] Run `swift test --filter ReadmeSnippetTests` — expect: green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.