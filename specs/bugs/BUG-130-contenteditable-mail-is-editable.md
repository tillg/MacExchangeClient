---
title: 'A mail with contenteditable can be edited in the message view (the reader can type into received mail)'
priority: P4
area: HTMLPage
status: open
found: 2026-11-13
---
## Summary
HTML that carries `contenteditable` (common in mail forwarded from web editors/CMS previews, or a whole `<body contenteditable>`) becomes editable in the viewer: clicking puts a caret in the received text and typing changes it. Mail forces every element read-only.

## Repro
Harness: `RPage` (real WKWebView configured like `MailWebView`) at the top of COPY/specs/bugs/probes/Probe_RenderTests.swift; run alone with `--filter Probe_RenderTests`.
```swift
@Test func contentEditableMailIsNotEditable() async {
    let mail = #"<div contenteditable="true" id="e">Type here to change what I wrote</div>"#
    let p = await RPage(HTMLPage.document(mail, allowRemote: false))
    let r = await p.string("document.getElementById('e').isContentEditable + '|' + getComputedStyle(document.getElementById('e')).webkitUserModify")
    #expect(r == "false|read-only", "\(r)")
}
```
## Expected vs actual
```
r → "true|read-write"
```
## Why expected
✅ /System/Library/PrivateFrameworks/MailUI.framework/Versions/A/Resources/MUIWebDocument.css, first rule: `* { -webkit-user-modify: initial !important; }` – a message is never editable in Mail.
## Likely cause
`Sources/MailModel/HTMLPage.swift:24-32`: that rule is missing from the page's style.
