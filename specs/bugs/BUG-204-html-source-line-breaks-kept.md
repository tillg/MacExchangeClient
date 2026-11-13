---
title: "Text of an HTML-only mail keeps the HTML source's line breaks: paragraphs break mid-sentence and every <br> gives a blank line in quotes"
priority: P4
area: ews / plain text of HTML
status: open
found: 2026-11-13
---

## Summary
When Exchange sends no `TextBody` (or a blank one), `EWSBackend.plainText` makes the text for the list preview, search and reply quotes from the HTML. It copies the text between tags as is, so line breaks and runs of spaces in the HTML *source* stay. Outlook writes its HTML with CRLF breaks inside paragraphs and after each `<br>`: "Thanks for the\r\nquick reply,   Ann" stays broken in the middle of the sentence, and `Line one<br>\r\nLine two` becomes "Line one\n\r\nLine two", which a reply quotes with an empty "> " line after every line. (The `\r\n` is one Swift `Character`, so the final `split(separator: "\n")` doesn't even see it.) Reachable only for mail without a usable `TextBody`.

## Expected
HTML Living Standard / CSS Text 3 §4.1: in normal white-space, segment breaks and runs of spaces collapse to one space; only markup (`<br>`, block ends) breaks lines. ews.md calls `plainText` a "rough plain text", so P4.

## Repro
Probe `Probe_R5I_PlainText/htmlSourceLineBreaksAreSpaces` in `Tests/MailModelTests/Probe_R5ITests.swift`:

```sh
swift test --package-path . --scratch-path .build/tests --skip-build --filter Probe_R5I_PlainText/htmlSourceLineBreaksAreSpaces
```
(after the test build from CLAUDE.md)

## Failure output
```
Expectation failed: t == "Thanks for the quick reply, Ann"
  t → "Thanks for the\r\nquick reply,   Ann"
Expectation failed: v == "Line one\nLine two"
  v → "Line one\n\r\nLine two"
```

## Fix idea
In `plainText.flush`, collapse each run of whitespace (incl. CR/LF) in the decoded text to one space (outside `<pre>`), then trim lines as now.
