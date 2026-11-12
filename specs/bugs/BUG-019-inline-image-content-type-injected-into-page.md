---
title: Inline image content type is inserted unescaped into the page, breaking out of the src attribute
priority: P3
area: HTMLPage
status: open
found: 2026-11-12
---
## Summary
`HTMLPage.document` builds `data:\(contentType);base64,…` and splices it into the HTML in place of `cid:…`. The content type comes from the server's attachment `ContentType` (sender-controlled; EWS only checks the `image/` prefix). A `"` in it ends the `src` attribute and injects arbitrary attributes/markup into the message page.

## Repro
Swift Testing, in `specs/bugs/probes/Probe_ModelTests.swift` (`import Testing`, `@testable import MailModel`, inside `struct Probe_ModelTests`):

```swift
@Test func inlineContentTypeIsNotMarkup() {
    let evil = InlineImage(contentType: #"image/png" onload="x" data-x=""#, data: Data([1]))
    let page = HTMLPage.document(#"<img src="cid:a@x">"#, allowRemote: false, inline: ["a@x": evil])
    #expect(!page.contains(#"onload="x""#))
}
```
Run: `swift test --package-path COPY --scratch-path COPY/.build/tests --skip-build --filter Probe_Model`

## Expected vs actual
Test fails. Generated body line (printed by a debug probe):
```
<div id="mail-replica-body"><img src="data:image/png" onload="x" data-x=";base64,AQ=="></div>
```

## Why expected
HTMLPage's doc: "Mail is untrusted". The image is also broken (src is now `data:image/png` with no data). CSP limits scripts, but attribute/markup injection from a header value should not be possible.

## Likely cause
Sources/MailModel/HTMLPage.swift:11-12 `"data:\($0.contentType);base64,…"` — contentType neither validated (token chars only) nor HTML/attribute-escaped; EWSBackend.swift:157-159 passes it through.
