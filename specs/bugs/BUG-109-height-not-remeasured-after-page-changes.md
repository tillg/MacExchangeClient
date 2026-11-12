---
title: 'The body''s height is never re-measured when the page grows after load (lazy images, <details>, interactive mail): the end is cut off'
priority: P3
area: HTMLPage
status: open
found: 2026-11-13
---
## Summary
HTMLBodyView measures only on `didFinish` and on width changes. Content that grows later is cut off: `loading="lazy"` images (newsletter tools add this) load only once the view has grown into its measured height, after the measurement; opening a `<details>` or a CSS checkbox "show more" section grows the page but the view stays the old height.

## Repro
Harness: `RPage` (real WKWebView configured exactly like `MailWebView`: content JS off, non-persistent store, aqua; loads at the view width and 1 pt height as HTMLBodyView starts; `measure()` runs the app's measuring script verbatim; `settleLikeTheApp()` measures and sets the frame to that height) and `LoopbackRecorder` (127.0.0.1-only NWListener) — both at the top of COPY/specs/bugs/probes/Probe_RenderTests.swift. Run the WebKit suite alone: `--filter Probe_RenderTests`.
```swift
@Test func lazyImageIsMeasured() async {
    let mail = #"<p>Top</p><img loading="lazy" style="display:block" src="data:image/png;base64,\#(png1x1)" width="1" height="1"><img loading="lazy" style="display:block;width:300px" src="data:image/png;base64,\#(png1x1)"><p>End</p>"#
    let p = await RPage(HTMLPage.document(mail, allowRemote: false), width: 600)
    let h = await p.settleLikeTheApp()
    try? await Task.sleep(for: .milliseconds(500))
    let content = await p.contentHeight()
    #expect(content <= h, "measured \(h), page \(content)")
}
@Test func openingDetailsGrowsTheView() async {
    let mail = #"<details id="d"><summary>Show order</summary>\#(String(repeating: "<p>Item</p>", count: 20))</details><p>End</p>"#
    let p = await RPage(HTMLPage.document(mail, allowRemote: false), width: 600)
    let h = await p.settleLikeTheApp()
    _ = await p.eval("document.getElementById('d').open = true; 1")   // what a click on the summary does
    try? await Task.sleep(for: .milliseconds(300))
    let content = await p.contentHeight()
    #expect(content <= h, "view height \(h), page after opening \(content)")
}
```
## Expected vs actual
```
lazyImageIsMeasured:         measured 129.0, page 429.0
openingDetailsGrowsTheView:  view height 101.0, page after opening 701.0
```
## Why expected
HTMLBodyView doc comment: "as tall as its content"; the vertical scroll goes to the outer view, so content beyond the view's height can't be reached.
## Likely cause
`Sources/MailReplica/HTMLBodyView.swift:41,72`: `measure` runs only from `didFinish` and `layout()` width changes. Needs a content-size observation (e.g. a ResizeObserver in an app-world WKUserScript posting to a message handler, or KVO on the scroll view's document size).
