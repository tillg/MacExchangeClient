---
title: 'Apple Mail quotes (<blockquote type="cite">) show as a plain 40px indent instead of Mail''s quote bar'
priority: P3
area: HTMLPage
status: open
found: 2026-11-13
---
## Summary
Replies from Apple Mail/iPhone quote the original in `<blockquote type="cite">`. Mail draws these with no margin, 8 px padding and a 2 px coloured bar on the left (nested levels in other colours). The replica's page leaves WebKit's default: 40 px indent on both sides, no bar, so quoted text can't be told from the new text.

## Repro
Harness: `RPage` (real WKWebView configured like `MailWebView`) at the top of COPY/specs/bugs/probes/Probe_RenderTests.swift; run alone with `--filter Probe_RenderTests`.
```swift
@Test func appleMailQuoteHasMailsQuoteBar() async {
    let mail = """
        <div dir="ltr">Sounds good.</div><div><br><blockquote type="cite" id="q"><div>On 12 Nov 2026, at 09:14, Ann Lee &lt;ann@example.com&gt; wrote:</div><br><div><div>Shall we meet at 10?</div></div></blockquote></div>
        """
    let p = await RPage(HTMLPage.document(mail, allowRemote: false))
    let r = await p.string("""
        (s => [s.borderLeftWidth, s.borderLeftStyle, s.marginLeft, s.paddingLeft].join(' '))(getComputedStyle(document.getElementById('q')))
        """)
    #expect(r == "2px solid 0px 8px", "border-left width, style, margin-left, padding-left = \(r)")
}
```
## Expected vs actual
```
r → "0px none 40px 0px"
```
## Why expected
✅ Mail's own stylesheet, /System/Library/PrivateFrameworks/MailUI.framework/Versions/A/Resources/MUIWebDocument.css:
`blockquote[type=cite] { padding-left: 8px; margin: 0; border-left-width: 2px; border-left-style: solid; border-left-color: @[QUOTE_BAR_COLOR_LVL1_RGB]; color: @[QUOTE_TEXT_COLOR_LVL1_RGB]; }` (+ level 2 and 3). HTMLPage's comment says its style is "Like Mail's MUIWebDocument.css".
## Likely cause
`Sources/MailModel/HTMLPage.swift:24-32`: only the first rules of MUIWebDocument.css (html font, body margins, word breaking, table) were taken; the `blockquote[type=cite]` rules are missing.
