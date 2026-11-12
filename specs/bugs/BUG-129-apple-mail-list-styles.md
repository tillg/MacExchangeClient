---
title: 'Apple Mail dash lists show bullets, and nested numbered lists show 1. 1. 1. instead of 1. a. i.'
priority: P4
area: HTMLPage
status: open
found: 2026-11-13
---
## Summary
Mail draws `ul.Apple-dash-list` (Apple Mail's "dashed" list format) with en dashes and numbers nested `<ol>` levels decimal → lower-alpha → lower-roman. The replica shows disc bullets and decimal at every level.

## Repro
Harness: `RPage` (real WKWebView configured like `MailWebView`) at the top of COPY/specs/bugs/probes/Probe_RenderTests.swift; run alone with `--filter Probe_RenderTests`.
```swift
@Test func appleMailListStyles() async {
    let mail = #"<ul class="Apple-dash-list" id="u"><li>one</li></ul><ol><li>a<ol id="o2"><li>b<ol id="o3"><li>c</li></ol></li></ol></li></ol>"#
    let p = await RPage(HTMLPage.document(mail, allowRemote: false))
    let r = await p.string("['u','o2','o3'].map(id => getComputedStyle(document.getElementById(id)).listStyleType).join(' ')")
    #expect(r == "none lower-alpha lower-roman", "\(r)")
}
```
## Expected vs actual
```
r → "disc decimal decimal"
```
## Why expected
✅ /System/Library/PrivateFrameworks/MailUI.framework/Versions/A/Resources/MUIWebDocument.css: `ul.Apple-dash-list, ul.Apple-dash-list ul { list-style-type: none; } ul.Apple-dash-list li:before { content: "\2013"; … }`, `ol ol, … { list-style-type: lower-alpha; }`, `ol ol ol, … { list-style-type: lower-roman; }`.
## Likely cause
`Sources/MailModel/HTMLPage.swift:24-32`: list rules not taken over from MUIWebDocument.css.
