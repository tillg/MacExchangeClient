---
title: 'A position:fixed footer/header in a mail permanently covers the message''s last (or first) lines'
priority: P4
area: HTMLPage
status: open
found: 2026-11-13
---
## Summary
Because the web view is exactly as tall as the content and never scrolls, a `position:fixed; bottom:0` bar (web pages sent as mail, "view in browser" bars) is drawn over the last lines of the message, and they can never be scrolled out from under it. Here the signature line is hidden under the bar.

## Repro
Harness: `RPage` (real WKWebView configured exactly like `MailWebView`: content JS off, non-persistent store, aqua; loads at the view width and 1 pt height as HTMLBodyView starts; `measure()` runs the app's measuring script verbatim; `settleLikeTheApp()` measures and sets the frame to that height) and `LoopbackRecorder` (127.0.0.1-only NWListener) — both at the top of COPY/specs/bugs/probes/Probe_RenderTests.swift. Run the WebKit suite alone: `--filter Probe_RenderTests`.
```swift
@Test func fixedFooterDoesNotCoverTheLastLine() async {
    let mail = #"<p>\#(String(repeating: "Body text. ", count: 100))</p><p id="last">Kind regards, Ann</p><div id="bar" style="position:fixed;bottom:0;left:0;right:0;height:60px;background:#333;color:#fff">Open in browser</div>"#
    let p = await RPage(HTMLPage.document(mail, allowRemote: false), width: 600)
    _ = await p.settleLikeTheApp()
    let r = await p.string("""
        (r => { const e = document.elementFromPoint(r.left + 5, r.top + r.height / 2); return e ? (e.id || e.tagName) : 'none' })(document.getElementById('last').getBoundingClientRect())
        """)
    #expect(r == "last", "element on top of the last line: \(r)")
}
```
## Expected vs actual
```
element on top of the last line: bar
```
## Why expected
All of the message text should be readable. In a browser the fixed bar only covers content temporarily while it scrolls past. (Mail.app's exact handling of fixed elements is not verified ⚠️.)
## Likely cause
`Sources/MailModel/HTMLPage.swift:23-34` / content-sized `HTMLBodyView`: fixed positioning is relative to a viewport that equals the whole message. Turning `position:fixed` into `absolute`/`static` in the page style (e.g. override via a user stylesheet) would avoid it.
