---
title: hasRemoteContent misses srcset, <link href>, poster and &quot;-quoted url(), so no Load Remote Content banner
priority: P3
area: HTMLPage
status: open
found: 2026-11-12
---
## Summary
The remote-content detector only knows `src=`, `background=`, `url(` with a literal quote, and `@import`. Mail whose only remote resources are `srcset` images, a `<link rel=stylesheet href=https:…>`, a `<video poster=…>` or an Outlook-style `url(&quot;https:…&quot;)` style gets them silently blocked by the CSP, and the banner to load them never appears.

## Repro
Swift Testing, in `specs/bugs/probes/Probe_ModelTests.swift` (`import Testing`, `@testable import MailModel`, inside `struct Probe_ModelTests`):

```swift
func html(_ h: String) -> Message {
    var m = Message(accountID: UUID(), from: Contact(name: "A", email: "a@x"), to: [], subject: "S", body: "", date: .now)
    m.html = h
    return m
}

@Test func remoteContentSrcset() {
    #expect(html(#"<img srcset="https://t.example/p.png 1x">"#).hasRemoteContent)
}
@Test func remoteContentLinkStylesheet() {
    #expect(html(#"<link rel="stylesheet" href="https://t.example/s.css">"#).hasRemoteContent)
}
@Test func remoteContentEntityQuotedURL() {
    #expect(html(#"<td style="background-image:url(&quot;https://t.example/bg.png&quot;)">"#).hasRemoteContent)
}
@Test func remoteContentVideoPoster() {
    #expect(html(#"<video poster="https://t.example/p.jpg"></video>"#).hasRemoteContent)
}
```
Run: `swift test --package-path COPY --scratch-path COPY/.build/tests --skip-build --filter Probe_Model`

## Expected vs actual
All four fail: `hasRemoteContent → false` (expected true).

## Why expected
README ✅/behaviour: "Images, styles and fonts from the web … Other mail shows Load Remote Content first". The CSP (HTMLPage.swift:16-18) blocks these resources until allowed, so the user needs the banner to see them.

## Likely cause
Sources/MailModel/Models.swift:191 regex `(src|background)\s*=\s*["']?\s*https?:|url\(\s*["']?\s*https?:|@import` — no `srcset`/`href`/`poster`, and `&quot;` is not accepted as a quote inside `url(`.
