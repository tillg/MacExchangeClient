---
title: 'Unresolved CID: (uppercase scheme) images are not hidden when remote content is allowed'
priority: P4
area: HTMLPage
status: open
found: 2026-11-12
---
## Summary
The rule hiding unresolved inline images is `img[src^="cid:"]`, case-sensitive. The cid regex is case-insensitive, so `CID:` references are recognised, but when one has no image (and remote content is allowed, so the `visibility:hidden` rule is absent) WebKit draws a broken-image box.

## Repro
Swift Testing, in `specs/bugs/probes/Probe_ModelTests.swift` (`import Testing`, `@testable import MailModel`, inside `struct Probe_ModelTests`):

```swift
@Test func unresolvedUppercaseCIDHidden() {
    let page = HTMLPage.document(#"<img src="CID:missing@x">"#, allowRemote: true)
    #expect(page.contains(#"img[src^="cid:" i]"#))
}
```
Run: `swift test --package-path COPY --scratch-path COPY/.build/tests --skip-build --filter Probe_Model`

## Expected vs actual
Page CSS contains only:
```
img[src^="cid:"] { display: none; }
```
(no ` i` flag), while the sibling rule uses `img:not([src^="data:" i])`.

## Why expected
Doc at HTMLPage.swift:10: "References without an image stay `cid:` and hidden." URL schemes are case-insensitive (RFC 3986 §3.1), and the code treats `cid:` case-insensitively elsewhere.

## Likely cause
Sources/MailModel/HTMLPage.swift:28 attribute selector lacks the ` i` modifier.
