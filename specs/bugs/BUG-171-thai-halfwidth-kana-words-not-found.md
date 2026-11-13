---
title: "A word inside Thai text (or half-width katakana) isn't found by search"
priority: P3
area: search
status: open
found: 2026-11-13
---
Draft id: R5C-01 (probe suites `Probe_R5*` in `probes/Probe_R5*Tests.swift`).

## Summary
Thai (also Lao, Khmer, Myanmar) is written without spaces between words, like Chinese and Japanese. The FTS5 `unicode61` tokenizer turns a whole Thai sentence into one token, and the index only matches word starts, so a word in the middle of a sentence is never found. `MailDatabase.isCJK` sends only Han, hiragana and katakana (U+3040-30FF) words to the substring path; half-width katakana (U+FF66-FF9F, common in older Japanese mail) is left out too. Memory search (sample data, before the index) finds both, so results also change between launch and later.

## Expected
search.md: a word in a script "written without spaces" must "occur anywhere in one of the indexed columns" — the reason `isCJK` exists (DECISIONS #d-bug-081, BUG-081). Memory search finds these words; the two paths should agree (#d-memory-search).

## Repro
`Probe_R5CSearch/wordsInsideThaiOrHalfwidthKatakanaTextAreFound` in `Tests/MailModelTests/Probe_R5CTests.swift`:
`swift test --package-path . --scratch-path .build/tests --skip-build --filter Probe_R5CSearch/wordsInsideThaiOrHalfwidthKatakanaTextAreFound`

## Failure output
```
Expectation failed: try indexSearch([thai], "วันจันทร์").count == 1   (subject "ประชุมวันจันทร์")
Expectation failed: try indexSearch([kana], "ﾃｽﾄ").count == 1        (subject "ｶﾀｶﾅﾃｽﾄ会議")
```

## Fix idea
Extend `MailDatabase.isCJK` (rename: "no spaces") with Thai U+0E00-0E7F, Lao U+0E80-0EFF, Myanmar U+1000-109F, Khmer U+1780-17FF and half-width katakana U+FF65-FF9F.
