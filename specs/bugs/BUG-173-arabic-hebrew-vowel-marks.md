---
title: "Arabic and Hebrew words with vowel marks aren't found when typed without them"
priority: P4
area: search
status: open
found: 2026-11-13
---
Draft id: R5C-03 (probe suites `Probe_R5*` in `probes/Probe_R5*Tests.swift`).

## Summary
"مَرْحَبًا" (with harakat) isn't found by typing "مرحبا", neither by the index nor by memory search; Hebrew "שָׁלוֹם" (niqqud) isn't found by "שלום" in the index. `unicode61 remove_diacritics 2` only removes Latin accents, and Foundation's `.diacriticInsensitive` folding doesn't remove Arabic harakat. Users almost never type these marks, so text that carries them (quotes, religious and children's texts, signatures) can't be found.

## Expected
README "Search": "Case and accents don't matter". Greek accents got the same treatment for the same reason (BUG-082, `greekVariants`).

## Repro
`Probe_R5CSearch/arabicAndHebrewVowelMarksDontMatter`:
`swift test --package-path . --scratch-path .build/tests --skip-build --filter Probe_R5CSearch/arabicAndHebrewVowelMarksDontMatter`

## Failure output
```
Expectation failed: try indexSearch([ar], "مرحبا").count == 1
Expectation failed: memorySearch([ar], "مرحبا").count == 1
Expectation failed: try indexSearch([he], "שלום").count == 1
```

## Fix idea
Strip combining marks of these scripts (Arabic U+064B-065F, U+0670; Hebrew U+0591-05C7) from the indexed text and the query (an FTS5 column of folded text, or a custom fold before binding), and in `MailStore.fold`.
