---
title: 'With remote content blocked, embedded (data:) pictures are hidden when given via srcset/<picture> or with a leading space in src'
priority: P4
area: HTMLPage
status: open
found: 2026-11-13
---
## Summary
The blocked-content rule hides every `<img>` whose `src` attribute doesn't literally start with `data:`. Pictures embedded in the mail itself – which need no permission and do load – are hidden when the `src` has leading whitespace, when the picture comes from `srcset`, or from a `<picture><source srcset="data:…">`. No banner offers to show them either (they are not remote).

## Repro
Harness: `RPage` at the top of COPY/specs/bugs/probes/Probe_RenderTests.swift; run alone with `--filter Probe_RenderTests`.
```swift
@Test func embeddedPicturesStayVisibleWhenRemoteBlocked() async {
    let d = "data:image/png;base64,\(png1x1)"
    let mail = """
        <img id="a" src=" \(d)" width="10" height="10">
        <img id="b" srcset="\(d) 1x" width="10" height="10">
        <picture><source srcset="\(d)"><img id="c" width="10" height="10"></picture>
        """
    let p = await RPage(HTMLPage.document(mail, allowRemote: false))
    let r = await p.string("['a','b','c'].map(i => { const e = document.getElementById(i); return i + ':' + getComputedStyle(e).visibility + ':' + (e.complete && e.naturalWidth > 0) }).join(' ')")
    #expect(r == "a:visible:true b:visible:true c:visible:true", "\(r)")
}
```
## Expected vs actual
```
r → "a:hidden:true b:hidden:true c:hidden:true"
```
All three pictures loaded (`naturalWidth > 0`), yet are invisible.
## Why expected
rendering.md: only images the CSP blocks should be hidden ("WebKit draws a blocked image as an outlined box… Mail shows nothing"); `img-src data:` allows these.
## Likely cause
`Sources/MailModel/HTMLPage.swift:19`: `img:not([src^="data:" i]) { visibility: hidden; }` tests the attribute text, not what was loaded. Hiding only broken images (e.g. checking `complete && naturalWidth == 0` from the app script, or matching `[src]:not([src^=data:])` with trimmed src and leaving srcset/picture images alone) avoids it.
