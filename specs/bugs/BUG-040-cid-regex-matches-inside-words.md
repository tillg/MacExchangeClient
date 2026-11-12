---
title: 'cid: references are found inside ordinary words ("acid:rain", "Lucid:dreams")'
priority: P4
area: HTMLPage
status: open
found: 2026-11-12
---
## Summary
The `cid:` pattern has no word/attribute boundary, so text like `Placid:lake`, `acid:rain,` yields content IDs `lake`, `rain,`, `dreams</p`. `MailStore.loadInlineImages` then asks Exchange for inline images of a message that has none (extra GetItem/GetAttachment round trip on every open), and a matching id would rewrite visible text.

## Repro
Swift Testing, in `specs/bugs/probes/Probe_ModelTests.swift` (`import Testing`, `@testable import MailModel`, inside `struct Probe_ModelTests`):

```swift
@Test func cidInsideWordsIsNotAReference() {
    #expect(HTMLPage.contentIDs(in: "<p>Placid:lake and acid:rain, Lucid:dreams</p>").isEmpty)
}
```
Run: `swift test --package-path COPY --scratch-path COPY/.build/tests --skip-build --filter Probe_Model`

## Expected vs actual
```
HTMLPage.contentIDs(in: "<p>Placid:lake and acid:rain, Lucid:dreams</p>") → ["dreams</p", "rain,", "lake"]
```

## Why expected
Doc comment: "The content IDs the HTML refers to with `cid:` (in `src`, `background` or CSS `url()`)" — text is none of these. RFC 2392 cid URLs are the scheme `cid:`, not a substring of a word.

## Likely cause
Sources/MailModel/HTMLPage.swift:44 `cid:([^"'\s)>]+)` with no preceding boundary (e.g. `(?<![\w-])`), and `<` not in the terminator set.
