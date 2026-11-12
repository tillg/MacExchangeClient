---
title: 'Pictures sent from Apple Mail (img.Apple-web-attachment) show at full pixel width, far wider than the window'
priority: P3
area: HTMLPage
status: open
found: 2026-11-13
---
## Summary
Apple Mail marks pictures placed in a message with `class="Apple-web-attachment"`; Mail caps them at the page width. In the replica a 3024 px wide iPhone photo is drawn 3024 px wide: the reader sees a corner of the picture and has to scroll sideways.

## Repro
Harness: `RPage` (real WKWebView configured like `MailWebView`) at the top of COPY/specs/bugs/probes/Probe_RenderTests.swift; run alone with `--filter Probe_RenderTests`.
```swift
@Test func appleMailPictureFitsTheWindow() async {
    let mail = #"<div>Look:</div><div><img class="Apple-web-attachment Singleton" id="i" width="3024" height="40" src="data:image/png;base64,\#(png1x1)"></div>"#
    let p = await RPage(HTMLPage.document(mail, allowRemote: false))   // 600 pt wide
    let r = await p.string("document.getElementById('i').getBoundingClientRect().width + '|' + document.documentElement.scrollWidth")
    #expect(r == "560|600", "picture width|page scroll width = \(r)")
}
```
## Expected vs actual
```
r → "3024|3044"   (expected "560|600")
```
## Why expected
✅ /System/Library/PrivateFrameworks/MailUI.framework/Versions/A/Resources/MUIWebDocument.css: `img.Apple-web-attachment { vertical-align: top !important; max-width: 100% !important; }` (and `video.Apple-web-attachment { max-width: 100% !important; }`).
## Likely cause
`Sources/MailModel/HTMLPage.swift:24-32`: rule not taken over from MUIWebDocument.css.
