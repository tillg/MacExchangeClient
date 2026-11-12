---
title: 'Unquoted cid: in a self-closing tag gets a trailing "/" in its ID, so the image never shows'
priority: P4
area: HTMLPage
status: open
found: 2026-11-12
---
## Summary
`<img src=cid:logo@x/>` (unquoted attribute, XHTML-style self-closing tag, common in generated signatures) yields content ID `logo@x/`, which matches no attachment; the image stays hidden.

## Repro
Swift Testing, in `specs/bugs/probes/Probe_ModelTests.swift` (`import Testing`, `@testable import MailModel`, inside `struct Probe_ModelTests`):

```swift
@Test func cidUnquotedSelfClosing() {
    #expect(HTMLPage.contentIDs(in: "<img src=cid:logo@x/>") == ["logo@x"])
}
```
Run: `swift test --package-path COPY --scratch-path COPY/.build/tests --skip-build --filter Probe_Model`

## Expected vs actual
```
HTMLPage.contentIDs(in: "<img src=cid:logo@x/>") → ["logo@x/"]
```

## Why expected
Doc at HTMLPage.swift:43: "A reference runs to the closing quote, bracket or space". In HTML, `/>` ends an unquoted attribute value followed by the tag close.

## Likely cause
Sources/MailModel/HTMLPage.swift:44 terminator class `[^"'\\s)>]` doesn't stop before `/>`.
