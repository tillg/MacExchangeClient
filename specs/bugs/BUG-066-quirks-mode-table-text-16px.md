---
title: Every HTML mail renders in quirks mode, so text in tables is 16 px instead of Mail's 14 px default
priority: P3
area: HTMLPage
status: open
found: 2026-11-12
---
## Summary
`HTMLPage.document` starts with a `<meta>` and has no doctype. The mail's own `<!DOCTYPE html>` ends up inside our `<div>`, where the parser ignores it, so every message renders in quirks mode (`document.compatMode == "BackCompat"`). In quirks mode WebKit resets `font-size` on tables to `medium` (16 px). Text inside a table therefore doesn't inherit the 14 px from `html { font: 14px Helvetica }`. Tables are very common in mail: signatures, Outlook layouts, newsletters. That text shows larger than the paragraphs around it.

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
    @Test func tableTextGetsTheDefaultFontSizeInAStandardsModeMail() async throws {
        let mail = "<!DOCTYPE html><html><body><table><tr><td id=c>Kind regards</td></tr></table></body></html>"
        let r = await Render.eval(HTMLPage.document(mail, allowRemote: false),
                                  "document.compatMode + '|' + getComputedStyle(document.getElementById('c')).fontSize")
        try #require(r != nil)
        #expect(r as? String == "CSS1Compat|14px", "\(String(describing: r))")
    }

    @Test func tableTextGetsTheDefaultFontSizeInAnUnstyledMail() async throws {
        let mail = "<p id=p>Hi,</p><table><tr><td id=c>Kind regards<br>Ann</td></tr></table>"
        let r = await Render.eval(HTMLPage.document(mail, allowRemote: false),
                                  "getComputedStyle(document.getElementById('p')).fontSize + '|' + getComputedStyle(document.getElementById('c')).fontSize")
        try #require(r != nil)
        #expect(r as? String == "14px|14px", "paragraph|table cell = \(String(describing: r))")
    }
}
```

## Expected vs actual
```
Test tableTextGetsTheDefaultFontSizeInAStandardsModeMail() recorded an issue at Probe_Model2Tests.swift:162:9: Expectation failed: r as? String == "CSS1Compat|14px"
  r as? String → "BackCompat|16px"
Test tableTextGetsTheDefaultFontSizeInAnUnstyledMail() recorded an issue at Probe_Model2Tests.swift:170:9: Expectation failed: r as? String == "14px|14px"
  (WebKit result: 14px|16px)
```

## Why expected
README: "Mail without its own fonts uses Mail's default, Helvetica 14". The existing test `unstyledMailUsesMailsDefaultFontAndMargins` checks only the style text, not the result. Mail.app loads the message as its own document, so a mail that declares `<!DOCTYPE html>` renders in standards mode, where tables inherit the font size. Caveat: for a mail with no doctype at all, Mail is in quirks mode too, and its table font size then depends on the web view's default font size, which wasn't checked. The first probe (a mail with a doctype) needs no such assumption.

## Likely cause
`Sources/MailModel/HTMLPage.swift:21-34`: the page has no `<!DOCTYPE html>`, so WebKit picks quirks mode. The mail's doctype can't help, because it sits inside `<div id="mail-replica-body">`. Its quirks style sheet then applies `table { font-size: medium }`.
