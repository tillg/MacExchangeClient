---
title: The sender's <body bgcolor>/text colours are overridden by our white page, so light text on a dark mail becomes invisible
priority: P3
area: HTMLPage
status: open
found: 2026-11-12
---
## Summary
The page's style sheet sets `html, body { background: #fff }` and `body { color: #000 }`. Author CSS beats HTML presentational attributes, so a mail that sets its page colour with `<body bgcolor=…>` (and `text=…`), as many newsletters and Outlook templates do, loses it. Text the sender coloured white for their dark page ends up white on white.

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
    @Test func bodyBgcolorFromTheSenderIsKept() async throws {
        let mail = "<html><body bgcolor=\"#000000\"><font id=f color=\"#ffffff\">White text on the sender's black page</font></body></html>"
        let r = await Render.eval(HTMLPage.document(mail, allowRemote: false),
                                  "getComputedStyle(document.body).backgroundColor + '|' + getComputedStyle(document.getElementById('f')).color")
        try #require(r != nil)
        #expect(r as? String == "rgb(0, 0, 0)|rgb(255, 255, 255)", "body background|text colour = \(String(describing: r))")
    }

    @Test func bodyTextAttributeFromTheSenderIsKept() async throws {
        let mail = "<html><body bgcolor=\"#000000\" text=\"#ffffff\"><p id=p>Dark newsletter</p></body></html>"
        let r = await Render.eval(HTMLPage.document(mail, allowRemote: false),
                                  "getComputedStyle(document.body).backgroundColor + '|' + getComputedStyle(document.getElementById('p')).color")
        try #require(r != nil)
        #expect(r as? String == "rgb(0, 0, 0)|rgb(255, 255, 255)", "body background|text colour = \(String(describing: r))")
    }

    // Control (passes): the same colours given as an inline style are kept.
    @Test func controlBodyStyleBackgroundIsKept() async throws {
        let mail = "<html><body style=\"background:#000\"><font id=f color=\"#ffffff\">x</font></body></html>"
        let r = await Render.eval(HTMLPage.document(mail, allowRemote: false),
                                  "getComputedStyle(document.body).backgroundColor + '|' + getComputedStyle(document.getElementById('f')).color")
        try #require(r != nil)
        #expect(r as? String == "rgb(0, 0, 0)|rgb(255, 255, 255)", "\(String(describing: r))")
    }
}
```

## Expected vs actual
```
Test bodyBgcolorFromTheSenderIsKept() recorded an issue at Probe_Model2Tests.swift:70:9: Expectation failed: r as? String == "rgb(0, 0, 0)|rgb(255, 255, 255)"
  r as? String → "rgb(255, 255, 255)|rgb(255, 255, 255)"
Test bodyTextAttributeFromTheSenderIsKept() recorded an issue at Probe_Model2Tests.swift:78:9: Expectation failed: r as? String == "rgb(0, 0, 0)|rgb(255, 255, 255)"
  r as? String → "rgb(255, 255, 255)|rgb(0, 0, 0)"
Test controlBodyStyleBackgroundIsKept() passed
```
The first is white text on a white page (invisible). In the second, both the sender's dark page and their white text are gone.

## Why expected
README: HTML mail is "shown as the sender laid it out". The page claims to be "Like Mail's MUIWebDocument.css". The real `/System/Library/PrivateFrameworks/MailUI.framework/Versions/A/Resources/MUIWebDocument.css` sets `font` on `html` and `margin/padding/word-wrap` on `body`, but no `background` and no `color`. In Mail, `bgcolor` and `text` therefore apply.

## Likely cause
`Sources/MailModel/HTMLPage.swift:25` (`html, body { background: #fff; }`) and `:27` (`color: #000` in the `body` rule). These are author-level declarations, which outrank the presentational hints `bgcolor`, `background` and `text` that the HTML parser copies onto our `<body>` from the mail's `<body>` tag.
