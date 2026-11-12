---
title: A stray </div> in an HTML mail closes the measured wrapper, so the rest of the message is cut off
priority: P3
area: HTMLPage
status: open
found: 2026-11-12
---
## Summary
`HTMLPage.document` pastes the message HTML inside `<div id="mail-replica-body">`, and HTMLBodyView sizes the web view to that div's bottom. A message with one more `</div>` than `<div>` closes our wrapper early. How often Exchange delivers such unbalanced HTML is unverified: it may rebalance tags when it returns the body, and that can't be checked offline. Everything after it lands outside the div and is not measured. The view is cut short and, because vertical scrolling is passed to the message view, the rest of the mail can't be reached.

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
    /// Same formula as HTMLBodyView.measure, plus the real content height and whether the tail is inside the wrapper.
    static let measureJS = """
        [Math.ceil(document.getElementById('\(HTMLPage.bodyID)').getBoundingClientRect().bottom
            + parseFloat(getComputedStyle(document.body).marginBottom)),
         document.documentElement.scrollHeight,
         document.getElementById('\(HTMLPage.bodyID)').contains(document.getElementById('tail'))].join('|')
        """

    @Test func strayClosingDivDoesNotEscapeTheMeasuredWrapper() async throws {
        let mail = "<div><p>Hello</p></div></div><p id=tail style='height:600px'>Signature and the rest of the mail</p>"
        let r = await Render.eval(HTMLPage.document(mail, allowRemote: false), Self.measureJS)
        try #require(r != nil)
        let parts = (r as? String ?? "").split(separator: "|").map(String.init)
        #expect(parts.count == 3 && parts[2] == "true", "measured|content height|tail inside wrapper = \(parts)")
        #expect(parts.count == 3 && Int(parts[0])! >= Int(parts[1])!, "measured|content height|tail inside wrapper = \(parts)")
    }

    // Control: passes.
    @Test func controlBalancedDivsStayInsideTheWrapper() async throws {
        let mail = "<div><p>Hello</p></div><p id=tail style='height:600px'>Signature and the rest of the mail</p>"
        let r = await Render.eval(HTMLPage.document(mail, allowRemote: false), Self.measureJS)
        try #require(r != nil)
        let parts = (r as? String ?? "").split(separator: "|").map(String.init)
        #expect(parts.count == 3 && parts[2] == "true" && Int(parts[0])! >= Int(parts[1])!, "\(parts)")
    }
}
```

## Expected vs actual
Expected: the tail is inside the wrapper and the measured height is at least the content height (the control gives `698|698|true`).
Actual (WebKit result `84|698|false`):
```
Test strayClosingDivDoesNotEscapeTheMeasuredWrapper() recorded an issue: Expectation failed: parts.count == 3 && parts[2] == "true"
Test strayClosingDivDoesNotEscapeTheMeasuredWrapper() recorded an issue: Expectation failed: parts.count == 3 && Int(parts[0])! >= Int(parts[1])!
```
The view would be 84 pt tall for a 698 pt message.

## Why expected
`HTMLPage.bodyID` is documented as "The element whose height is the message's height". README: HTML mail is "shown as the sender laid it out". Mail.app loads the message as its own document, so an unbalanced end tag can't hide content there. Under the HTML parsing rules, an `</div>` closes the nearest open `div` in scope, which here is our wrapper.

## Likely cause
`Sources/MailModel/HTMLPage.swift:33`: `<div id="\(bodyID)">\(html)</div>` wraps untrusted markup in an element the markup can close. `Sources/MailReplica/HTMLBodyView.swift:62-64` then measures only that element. Measuring `document.documentElement.scrollHeight`, or placing the marker after the content (an empty element appended at the end of `body`), would not depend on the mail's markup being balanced.
