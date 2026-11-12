---
title: 'A mail with an autofocus form field shrinks to a few pixels: the page scrolls to the field at load and the height is measured relative to that scroll'
priority: P3
area: HTMLPage
status: open
found: 2026-11-13
---
## Summary
The body view starts 1 pt tall. A form field with `autofocus` (surveys, phishing forms, "reply here" boxes) gets focus at load and WebKit scrolls the 1-pt viewport down to it. The measuring script uses `getBoundingClientRect().bottom`, which is relative to that scroll position, so the message is measured at a fraction of its height. The user sees one strip at the end of the mail; the rest is unreachable (vertical scroll goes to the outer view).

## Repro
Harness: `RPage` (real WKWebView configured exactly like `MailWebView`: content JS off, non-persistent store, aqua; loads at the view width and 1 pt height as HTMLBodyView starts; `measure()` runs the app's measuring script verbatim; `settleLikeTheApp()` measures and sets the frame to that height) and `LoopbackRecorder` (127.0.0.1-only NWListener) — both at the top of COPY/specs/bugs/probes/Probe_RenderTests.swift. Run the WebKit suite alone: `--filter Probe_RenderTests`.
```swift
@Test func autofocusFieldDoesNotShortenTheMeasurement() async {
    let mail = "<p>\(String(repeating: "Survey intro text. ", count: 200))</p><form><input autofocus name=q></form>"
    let p = await RPage(HTMLPage.document(mail, allowRemote: false), width: 600)
    let scroll = ((await p.eval("window.scrollY")) as? NSNumber)?.doubleValue ?? -1
    let h = await p.measure()
    let content = await p.contentHeight()
    #expect(h >= content, "measured \(h), page \(content), scrollY \(scroll)")
}
```
Confirmed in the real app with the snapshot hook (`MAIL_SAMPLE_DATA=1 MAIL_SNAPSHOT=… MAIL_SNAPSHOT_HTML=autofocus.html .build/debug/MailReplica`, autofocus.html = a heading, 39 paragraphs and `<form><p>Your answer: <input autofocus name=q></p></form>`): only a sliver with the half-cut "Your answer:" field is shown under the header, the heading and all 39 paragraphs are gone (r3snap/autofocus.png).
## Expected vs actual
```
Expectation failed: h >= content
  measured 47.0, page 743.0, scrollY 696.0
```
## Why expected
README: HTML mail is "shown as the sender laid it out"; HTMLBodyView: "as tall as its content".
## Likely cause
`Sources/MailReplica/HTMLBodyView.swift:62-64`: `getBoundingClientRect().bottom` is viewport-relative; add `window.scrollY` (or use `document.documentElement.scrollHeight`), and/or keep the page from scrolling (focus) at all.
