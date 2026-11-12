---
title: 'Fonts embedded in the mail (data: URIs) are blocked unless remote content is allowed'
priority: P4
area: HTMLPage
status: open
found: 2026-11-12
---
## Summary
Without remote content, the page's Content-Security-Policy is `default-src 'none'; style-src 'unsafe-inline'; img-src data:`. It has no `font-src`, so `@font-face` fonts embedded as `data:` URIs fall back to `default-src 'none'` and are blocked. They contact no server, just like `data:` images, which the policy allows. Mail that ships its own font therefore shows in a fallback font until the user clicks Load Remote Content, and for senders outside the organisation that click also loads the trackers.

## Repro
```swift
import Foundation
import Testing
import WebKit
@testable import MailModel

/// Renders HTMLPage.document in a real WKWebView configured like HTMLBodyView, then runs a script.
@MainActor
enum Render {
    static func eval(_ page: String, _ script: String, settle: Int = 0, timeout: TimeInterval = 30) async -> Any? {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.websiteDataStore = .nonPersistent()
        let v = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), configuration: config)
        v.loadHTMLString(page, baseURL: nil)
        let deadline = Date().addingTimeInterval(timeout)
        try? await Task.sleep(for: .milliseconds(200))
        while v.isLoading && Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        if settle > 0 { try? await Task.sleep(for: .milliseconds(settle)) }
        return try? await v.evaluateJavaScript(script)
    }
}

@MainActor
struct Probe_Model2Tests {
    static func fontMail() throws -> String {
        let font = try Data(contentsOf: URL(fileURLWithPath: "/System/Library/Fonts/Supplemental/NotoSansCarian-Regular.ttf"))
        return "<style>@font-face { font-family: Embedded; src: url(data:font/ttf;base64,\(font.base64EncodedString())); }"
            + " p { font-family: Embedded, Helvetica; }</style><p>Embedded font</p>"
    }
    static let fontStatusJS = "Array.from(document.fonts).map(f => f.family + ':' + f.status).join(',')"

    @Test func embeddedDataFontsLoadWithoutRemoteContent() async throws {
        let r = await Render.eval(HTMLPage.document(try Self.fontMail(), allowRemote: false), Self.fontStatusJS, settle: 1000)
        try #require(r != nil)
        #expect(r as? String == "Embedded:loaded", "\(String(describing: r))")
    }

    // Control (passes): the same page with remote content allowed loads the font.
    @Test func controlEmbeddedDataFontsLoadWithRemoteContent() async throws {
        let r = await Render.eval(HTMLPage.document(try Self.fontMail(), allowRemote: true), Self.fontStatusJS, settle: 1000)
        try #require(r != nil)
        #expect(r as? String == "Embedded:loaded", "\(String(describing: r))")
    }
}
```

## Expected vs actual
```
Test embeddedDataFontsLoadWithoutRemoteContent() recorded an issue at Probe_Model2Tests.swift:100:9: Expectation failed: r as? String == "Embedded:loaded"
  (WebKit result: Embedded:unloaded)
Test controlEmbeddedDataFontsLoadWithRemoteContent() passed   (WebKit result: Embedded:loaded)
```

## Why expected
README: "Images, styles and fonts **from the web** follow Outlook's 'Download external images'". The type comment says the policy allows "nothing from the web unless `allowRemote`". A `data:` font is part of the message, not from the web, and `img-src data:` already applies that reasoning to images.

## Likely cause
`Sources/MailModel/HTMLPage.swift:17`: the blocked policy lacks `font-src data:`. The remote policy (line 16) has `font-src * data:`.
