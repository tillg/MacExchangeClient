---
title: 'Hebrew/Arabic lines turn left-to-right (left-aligned, punctuation on the wrong side) once a placed picture makes the mail HTML'
priority: P4
area: Models
status: open
found: 2026-11-13
---
## Summary
Without pictures the mail is plain text, and the recipient's client lays out each paragraph by its first strong character, so a Hebrew line reads right to left. Once a JPEG, PNG or GIF is placed, `Draft.html` writes each line as a `<div>` with no `dir`, so the base direction is LTR. In WebKit the Hebrew line is left-aligned and its final "!" lands on the right end instead of the left.

## Repro
```swift
import Foundation
import Testing
import WebKit
@testable import EWS
@testable import MailModel

/// Renders HTML in a real WKWebView and runs a script (same approach as Probe_Model2Tests' harness).
@MainActor
enum ComposeRender {
    static func eval(_ page: String, _ script: String, width: CGFloat = 600, timeout: TimeInterval = 30) async -> Any? {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let v = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: 400), configuration: config)
        v.loadHTMLString(page, baseURL: nil)
        let deadline = Date().addingTimeInterval(timeout)
        try? await Task.sleep(for: .milliseconds(200))
        while v.isLoading && Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        return try? await v.evaluateJavaScript(script)
    }
}

struct ComposeRNG: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

@MainActor
struct Probe_ComposeTests {
    let work = Account(name: "Work", address: "me@work.com")
    let home = Account(name: "iCloud", address: "me@icloud.com")
    let mark = String(Draft.fileMark)

    func msg(_ acct: Account, _ box: MailboxKind = .inbox, subject: String = "Hi", from: Contact? = nil,
             to: [Contact]? = nil, cc: [Contact] = [], body: String = "Body") -> Message {
        Message(accountID: acct.id, mailbox: box, from: from ?? Contact(name: "Ann", email: "ann@x.com"),
                to: to ?? [Contact(name: "Me", email: acct.address)], cc: cc, subject: subject, body: body,
                date: Date(timeIntervalSince1970: 1_000_000))
    }

    func store(_ msgs: [Message]) -> MailStore { MailStore(accounts: [work, home], messages: msgs) }

    func png(_ name: String, _ bytes: Int = 4) -> DraftAttachment {
        DraftAttachment(name: name, contentType: "image/png", data: Data(repeating: 7, count: bytes))
    }

    /// A Hebrew/Arabic line shows right-to-left in the compose window (NSTextView's natural direction) and in a
    /// plain-text mail. Once a picture is placed, the mail goes as HTML: it must not turn into a left-to-right line.
    @Test func rtlLineStaysRightToLeftInHTML() async throws {
        var d = Draft(accountID: work.id, body: "שלום עולם!\n\(mark)")
        d.attachments = [png("p.png")]
        let h = d.html { _ in "x" }
        let js = """
        (() => { const div = document.querySelector('div'); const t = div.firstChild; const r = document.createRange();
          r.setStart(t, t.length - 1); r.setEnd(t, t.length); const bang = r.getBoundingClientRect();
          r.setStart(t, 0); r.setEnd(t, 1); const first = r.getBoundingClientRect();
          return [bang.left < first.left, Math.round(first.right), Math.round(div.getBoundingClientRect().right)].join('|') })()
        """
        let r = try #require(await ComposeRender.eval(h, js) as? String)
        let parts = r.split(separator: "|")
        #expect(parts.first == "true", "'!' should be at the left end (RTL paragraph); bang-left-of-first|first.right|div.right = \(r)")
    }

}
```

## Expected vs actual
Rendered `Draft.html` of `"שלום עולם!\n<picture>"` in a 600 px WKWebView:
```
'!' should be at the left end (RTL paragraph); bang-left-of-first|first.right|div.right = false|68|592
```
The first Hebrew letter ends at x=68 (the line is left-aligned in a 592 px div), and "!" is to its right. Expected: "!" on the left and the line right-aligned, as `dir="auto"` would give.

## Why expected
The same text sent as plain text keeps natural direction per paragraph, so adding a picture changes how the text reads. The compose view is an NSTextView with the default (natural) base writing direction, so the user sees RTL while writing. That last point was read from the code, not checked in the app.

## Likely cause
`Models.swift` `Draft.html(contentID:)`: `"<div>\(out.isEmpty ? "<br>" : out)</div>"` sets no `dir`. `<div dir="auto">` per line (or `dir=auto` on body plus `unicode-bidi: plaintext`) would keep each line's natural direction.
