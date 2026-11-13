---
title: "Text of an HTML-only mail runs blocks together: \"Original textMy answer\" after </blockquote>, <hr>, or an unclosed <p>"
priority: P4
area: ews / plain text of HTML
status: open
found: 2026-11-13
---

## Summary
`plainText` breaks lines only at `<br>` and the *end* tags of p, div, tr, li and h1–h6. A `</blockquote>`, `<hr>`, `</table>`, `</pre>`, `</ul>`, or a new `<p>` without the previous one closed (HTML allows the omission) adds nothing, so the words on both sides join: "Original textMy answer", "FirstSecond", "AboveBelow". That text is the preview, the search text and the reply quote of mail without a usable `TextBody` (the only case `plainText` runs).

## Expected
HTML Living Standard §15.3.3 (blockquote, hr, p, pre, ul, table are `display: block`); §13.1.2.4: a `<p>` start tag closes an open `p`. ews.md documents the current tag list, so P4.

## Repro
Probe `Probe_R5I_PlainText/otherBlockElementsBreakLines` in `Tests/MailModelTests/Probe_R5ITests.swift`:

```sh
swift test --package-path . --scratch-path .build/tests --skip-build --filter Probe_R5I_PlainText/otherBlockElementsBreakLines
```
(after the test build from CLAUDE.md)

## Failure output
```
Expectation failed: quote.contains("\n")   quote → "Original textMy answer"
Expectation failed: paras.contains("\n")   paras → "FirstSecond"
Expectation failed: rule.contains("\n")    rule → "AboveBelow"
```

## Fix idea
In `EWSBackend.plainText`, treat start and end tags of all block elements (p, div, blockquote, hr, pre, ul, ol, dl, dt, dd, table, section, …) as line breaks.
