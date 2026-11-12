---
title: 'Mail with window-relative heights (MailChimp height="100%" table, 100vh) is measured against the view''s own height: after widening the window it never gets shorter, and 100vh blocks push the end out'
priority: P3
area: HTMLPage
status: open
found: 2026-11-13
---
## Summary
The web view's viewport is the view itself, sized to the last measurement. Percentage/viewport heights in the mail then resolve against that measured height. MailChimp's standard template (`<table height="100%" id="bodyTable">`, quirks mode) keeps the height measured at a narrow width forever: widen the window and the view stays 2178 pt tall for 978 pt of content (1200 pt of white). A `height:100vh` block is 1 pt at measuring time and then grows to the view's height, pushing the mail's end below the view.

## Repro
Harness: `RPage` (real WKWebView configured exactly like `MailWebView`: content JS off, non-persistent store, aqua; loads at the view width and 1 pt height as HTMLBodyView starts; `measure()` runs the app's measuring script verbatim; `settleLikeTheApp()` measures and sets the frame to that height) and `LoopbackRecorder` (127.0.0.1-only NWListener) — both at the top of COPY/specs/bugs/probes/Probe_RenderTests.swift. Run the WebKit suite alone: `--filter Probe_RenderTests`. `percentTemplate` is a MailChimp skeleton (body margin 0, `height="100%"` bodyTable, 600px max-width inner table, 30 sentences).
```swift
@Test func percentHeightNewsletterShrinksWhenWindowWidens() async {
    let p = await RPage(HTMLPage.document(Self.percentTemplate, allowRemote: false), width: 320)
    let narrow = await p.settleLikeTheApp()
    await p.resize(width: 900)
    let widened = await p.measure()            // what onWidthChange → measure computes
    let fresh = await RPage(HTMLPage.document(Self.percentTemplate, allowRemote: false), width: 900)
    let reference = await fresh.measure()
    #expect(abs(widened - reference) <= 2, "narrow \(narrow), after widening \(widened), fresh load at that width \(reference)")
}
@Test func viewportHeightBlockDoesNotOutgrowTheView() async {
    let mail = #"<div style="height:100vh;background:#eee">Hero</div><p>Read more</p><p id="last">Unsubscribe</p>"#
    let p = await RPage(HTMLPage.document(mail, allowRemote: false), width: 600)
    let h = await p.settleLikeTheApp()
    let lastBottom = ((await p.eval("document.getElementById('last').getBoundingClientRect().bottom")) as? NSNumber)?.doubleValue ?? -1
    #expect(lastBottom <= h, "measured \(h), last line ends at \(lastBottom)")
}
```
Control `controlPlainMailShrinksWhenWindowWidens` (same steps, plain paragraph) passes.
## Expected vs actual
```
percentHeightNewsletterShrinksWhenWindowWidens: narrow 2178.0, after widening 2178.0, fresh load at that width 978.0
viewportHeightBlockDoesNotOutgrowTheView:       measured 115.0, last line ends at 193.0
```
## Why expected
The view should be as tall as the content at the current width (control case); a fresh load at the same width gives 978.
## Likely cause
`Sources/MailReplica/HTMLBodyView.swift:60-72` + `BodyWebView.layout`: measuring a view whose viewport height is its own previous height. Measure with the view (or a separate measuring viewport) at minimal height, or neutralise viewport-relative heights on the page (e.g. `html,body{height:auto!important}`).
