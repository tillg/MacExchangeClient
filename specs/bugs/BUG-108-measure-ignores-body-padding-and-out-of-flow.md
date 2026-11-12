---
title: 'Height counts only the wrapper''s box: body padding and absolutely positioned content are cut off'
priority: P3
area: HTMLPage
status: open
found: 2026-11-13
---
## Summary
The view's height is the bottom of `#mail-replica-body` plus the body's bottom margin. Anything the page draws outside that box is cut off: the body's bottom padding (common in newsletters: `<body style="margin:0;padding:40px 0">`) and content laid out with `position:absolute` (generated invoices/PDF-to-HTML mails), which is out of flow. With an absolutely positioned layout the whole message shows as a 40-pt strip. (Different from BUG-064: the wrapper is intact here.)

## Repro
Harness: `RPage` (real WKWebView configured exactly like `MailWebView`: content JS off, non-persistent store, aqua; loads at the view width and 1 pt height as HTMLBodyView starts; `measure()` runs the app's measuring script verbatim; `settleLikeTheApp()` measures and sets the frame to that height) and `LoopbackRecorder` (127.0.0.1-only NWListener) — both at the top of COPY/specs/bugs/probes/Probe_RenderTests.swift. Run the WebKit suite alone: `--filter Probe_RenderTests`.
```swift
@Test func bodyPaddingIsInsideTheMeasuredHeight() async {
    let mail = #"<body style="margin:0;padding:40px 0"><table width="100%"><tr><td>Newsletter</td></tr></table><p>Unsubscribe</p></body>"#
    let p = await RPage(HTMLPage.document(mail, allowRemote: false), width: 600)
    let h = await p.settleLikeTheApp()
    let content = await p.contentHeight()
    #expect(h >= content, "measured \(h), page \(content)")
}
@Test func absolutelyPlacedContentIsMeasured() async {
    let mail = #"<div style="position:relative"><div style="position:absolute;top:0;left:0;width:500px">Line<br>Line<br>Line<br>Line<br>Line<br>Line<br>Line<br>Line<br>Total: 120,00 €</div></div>"#
    let p = await RPage(HTMLPage.document(mail, allowRemote: false), width: 600)
    let h = await p.settleLikeTheApp()
    let content = await p.contentHeight()
    #expect(h >= content, "measured \(h), page \(content)")
}
```
## Expected vs actual
```
bodyPaddingIsInsideTheMeasuredHeight:   measured 108.0, page 148.0
absolutelyPlacedContentIsMeasured:      measured 40.0, page 162.0
```
## Why expected
HTMLBodyView: "as tall as its content"; README: shown as the sender laid it out.
## Likely cause
`Sources/MailReplica/HTMLBodyView.swift:62-64`: measures the wrapper's border box + `marginBottom`, ignoring body padding/border and out-of-flow descendants. `document.documentElement.scrollHeight` (with the view at minimal height) includes them.
