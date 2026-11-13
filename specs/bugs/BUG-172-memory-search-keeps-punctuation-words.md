---
title: "Memory search requires punctuation the index ignores; an invisible character alone lists all mail"
priority: P3
area: search
status: open
found: 2026-11-13
---
Draft id: R5C-02 (probe suites `Probe_R5*` in `probes/Probe_R5*Tests.swift`).

## Summary
The memory path (`MailStore.matches`, used for sample data, every launch until the index is ready, and after "Search failed") splits the query only at whitespace and needs every piece literally. The index drops words without a letter or digit and ignores punctuation in a word. So "Q3 - report" or "report, q3" finds "Q3 report" with the index but nothing from memory. And a query made only of a zero-width space (U+200B) or a line separator (U+2028), e.g. pasted, matches every message from memory (the index returns none).

## Expected
search.md "Query and matching": "words without any letter or digit are dropped. No word left: no results"; punctuation splits words. DECISIONS #d-memory-search: memory follows the index's rules (only exception: matching inside a word, #d-bug-052).

## Repro
`Probe_R5CSearch/memorySearchDropsWordsWithoutLettersLikeTheIndex`:
`swift test --package-path . --scratch-path .build/tests --skip-build --filter Probe_R5CSearch/memorySearchDropsWordsWithoutLettersLikeTheIndex`

## Failure output
```
Expectation failed: memorySearch([q3], "Q3 - report").count == 1
Expectation failed: memorySearch([q3], "report, q3").count == 1
Expectation failed: memorySearch([q3], "\u{200B}").isEmpty
Expectation failed: memorySearch([q3], "\u{2028}").isEmpty
```

## Fix idea
In `MailStore.searchWords`, split each word at non-letter/non-digit characters (as the tokenizer does), drop empty pieces, and return no results when none is left (`visibleMessages` memory branch).
