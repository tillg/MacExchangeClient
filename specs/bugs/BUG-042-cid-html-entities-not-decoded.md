---
title: 'cid: references with &amp; (or other entities) are not decoded, so the image is not found'
priority: P4
area: HTMLPage
status: open
found: 2026-11-12
---
## Summary
Only `&lt;`/`&gt;` are unescaped in the extracted ID. A Content-ID containing `&` is written in HTML as `&amp;`, so the ID requested from Exchange is `a&amp;b@x` instead of `a&b@x` and the inline image never loads.

## Repro
Swift Testing, in `specs/bugs/probes/Probe_ModelTests.swift` (`import Testing`, `@testable import MailModel`, inside `struct Probe_ModelTests`):

```swift
@Test func cidAmpEntity() {
    #expect(HTMLPage.contentIDs(in: #"<img src="cid:a&amp;b@x">"#) == ["a&b@x"])
}
```
Run: `swift test --package-path COPY --scratch-path COPY/.build/tests --skip-build --filter Probe_Model`

## Expected vs actual
```
HTMLPage.contentIDs(in: #"<img src="cid:a&amp;b@x">"#) → ["a&amp;b@x"]
```

## Why expected
The attribute value the browser sees is `cid:a&b@x`; the code already decodes `&lt;`/`&gt;` for the same reason, so entity decoding is intended but incomplete.

## Likely cause
Sources/MailModel/HTMLPage.swift:52-53 decodes only `&lt;` and `&gt;` (no `&amp;`, `&#64;`, `&quot;`…).
