---
title: "Georgian written in capitals (Mtavruli) isn't found by search"
priority: P4
area: search
status: open
found: 2026-11-13
---
Draft id: R5C-04 (probe suites `Probe_R5*` in `probes/Probe_R5*Tests.swift`).

## Summary
A subject "ᲡᲐᲥᲐᲠᲗᲕᲔᲚᲝ" (Georgian Mtavruli capitals, Unicode 11, used for headings and signatures) isn't found by typing "საქართველო". The `unicode61` tokenizer's tables predate these letters, so they are separators and the word isn't in the index at all. Memory search (Swift's Unicode case mapping) finds it.

## Expected
README "Search": case doesn't matter; the memory and index paths follow the same rules (DECISIONS #d-memory-search).

## Repro
`Probe_R5CSearch/georgianCapitalsAreFound`:
`swift test --package-path . --scratch-path .build/tests --skip-build --filter Probe_R5CSearch/georgianCapitalsAreFound`

## Failure output
```
Expectation failed: try indexSearch([ka], "საქართველო").count == 1
```

## Fix idea
Lowercase Mtavruli (U+1C90-1CBF → U+10D0-10FF) before writing the indexed columns, or index a case-folded copy of the text (`MailDatabase.bind` / search schema).
