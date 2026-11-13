---
title: "Text of an HTML-only mail loses ’, € and – written as &#146; &#128; &#150; (they become invisible control characters)"
priority: P4
area: ews / plain text of HTML
status: open
found: 2026-11-13
---

## Summary
`decodeEntities` turns every numeric reference into that code point. Old Word/Outlook and web-mail HTML often write Windows-1252 numbers: `It&#146;s &#128;5 &#150; ok` becomes "It\u{92}s \u{80}5 \u{96} ok", which shows as "Its 5  ok": the apostrophe, euro sign and dash are gone from the preview, search text and quote. `&#0;` and a surrogate (`&#xD800;`) are left as the literal text "&#0;". (The HTML view itself is right: WebKit applies the spec. Reachable only for mail without a usable `TextBody`.)

## Expected
HTML Living Standard §13.2.5.80 (numeric character reference end state): 0x80–0x9F map through the Windows-1252 table (0x92 → U+2019, 0x80 → U+20AC, 0x96 → U+2013); 0x00 and surrogates become U+FFFD.

## Repro
Probe `Probe_R5I_PlainText/c1NumericReferencesAreWindows1252` in `Tests/MailModelTests/Probe_R5ITests.swift`:

```sh
swift test --package-path . --scratch-path .build/tests --skip-build --filter Probe_R5I_PlainText/c1NumericReferencesAreWindows1252
```
(after the test build from CLAUDE.md)

## Failure output
```
Expectation failed: t == "It\u{2019}s \u{20AC}5 \u{2013} ok"
  scalars: 49 74 92 73 20 80 35 20 96 20 6f 6b   (t → "Its 5  ok")
Expectation failed: z == "a\u{FFFD}b\u{FFFD}c"
  z → "a&#0;b&#xD800;c"
```

## Fix idea
In `EWSBackend.decodeEntities`, apply the spec's replacement table for 0x80–0x9F and map 0, surrogates and > U+10FFFF to U+FFFD.
