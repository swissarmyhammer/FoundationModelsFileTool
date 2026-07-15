---
depends_on:
- 01KXJWNX69AB8Q6PEBEPH5KP3A
- 01KXKY0YMD58YMNF5X4THRNWZT
position_column: todo
position_ordinal: '9080'
title: 'Docs: README, DocC, departures'
---
## What
Per plan.md §10 task 12. Write `README.md` (library-style: declare → fuse → session → CLI, with a runnable example; the diagnostics loop — edit → see compiler errors → fix — front and center, including the multi-project story: a session root above several git repos, per-project diagnostics routing), DocC comments on all public API in `Sources/FileTool/`, plan §8 departures cross-referenced in a DESIGN_NOTES section or file, and a note pointing at the upstream `CodeContextManager` + public `CodeContext.rootDirectory` changes this package builds on. DESIGN_NOTES also records the nested-repo semantics (nearest-open-ancestor-wins; overlap degradation to `pending`) per the bridge task.

## Acceptance Criteria
- [ ] README's usage snippet compiles (doc-snippet-tested against the example source, the siblings' mechanism)
- [ ] Every public type/method in `Sources/FileTool/` has a DocC comment (checked by the snippet test target compiling with documentation warnings surfaced)
- [ ] DESIGN_NOTES departures section exists, cross-references plan §8 items 1–8, and documents the nested-repo/overlap semantics

## Tests
- [ ] `Tests/FileToolTests/ReadmeSnippetTests.swift`: extract the README code fence(s) and compile/assert against the example source (sibling mechanism)
- [ ] Run `swift test --filter ReadmeSnippetTests` — expect: green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.