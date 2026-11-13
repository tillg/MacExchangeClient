---
title: "Text of an HTML-only mail shows tag remains when an attribute value contains \">\" (alt=\"->\", title=\"a > b\")"
priority: P4
area: ews / plain text of HTML
status: open
found: 2026-11-13
---

## Summary
`plainText` ends a tag at the first `>`, even inside a quoted attribute value. `<img alt="->" src="x.png">` leaves `" src="x.png">` as text, and `<a title="a > b" href="x">` leaves ` b" href="x">`. The markup shows in the preview, search text and reply quotes of mail without a usable `TextBody`.

## Expected
HTML Living Standard §13.2.5.36–38 (attribute value (double-/single-quoted) state): `>` inside a quoted value is part of the value.

## Repro
Probe `Probe_R5I_PlainText/greaterThanInQuotedAttributeIsNotText` in `Tests/MailModelTests/Probe_R5ITests.swift`:

```sh
swift test --package-path . --scratch-path .build/tests --skip-build --filter Probe_R5I_PlainText/greaterThanInQuotedAttributeIsNotText
```
(after the test build from CLAUDE.md)

## Failure output
```
Expectation failed: t == "Link"
  t → "\" src=\"x.png\"> b\" href=\"x\">Link"
```

## Fix idea
In `plainText`, scan the tag for its end skipping `"…"` and `'…'` values instead of `find(">")`.
