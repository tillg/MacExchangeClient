---
title: 'Plain-text fallback of HTML mail: entities left raw, words run together, comment tails leak, slow on unclosed <style>'
priority: P4
area: EWS
status: open
found: 2026-11-12
---
## Summary
`plainText` (used only when the server sends no TextBody; its doc comment calls it "rough") decodes 6 entities only (`Gr&uuml;&szlig;e`, `&#8217;`, `&euro;` stay raw), turns only bare `<br>` into a newline (`<br clear="all">` and `</td><td>` join words), ends comments at their first `>` (`b then -->` leaks), and its lazy `<(head|style|script)\b.*?</\1>` regex is quadratic on unclosed tags (7.7 s for 5,000 `<style>` + 100 KB).

## Repro
Tests: probePlainTextDecodesCommonEntities, probePlainTextBreaksLinesAtBrWithAttributes, probePlainTextKeepsTableCellsApart, probePlainTextDropsComments, probePlainTextUnclosedStyleIsFast in specs/bugs/probes/Probe_EWSTests.swift

```swift
import Foundation
import Testing
@testable import EWS
@testable import MailModel

struct Probe_EWSTests {
    func doc(_ body: String) throws -> XMLDocument {
        try XMLDocument(xmlString: """
            <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" \
            xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages" \
            xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types"><s:Body>\(body)</s:Body></s:Envelope>
            """)
    }
    func request(_ body: String) throws -> XMLDocument { try XMLDocument(xmlString: EWSClient.envelope(body)) }

    @Test func probePlainTextDecodesCommonEntities() {
        #expect(EWSBackend.plainText("<p>Gr&uuml;&szlig;e &ndash; Till&#8217;s &euro;5 &#x27;x&#x27;</p>") == "Grüße – Till’s €5 'x'")
    }

    @Test func probePlainTextBreaksLinesAtBrWithAttributes() {
        #expect(EWSBackend.plainText("Line1<br clear=\"all\">Line2") == "Line1\nLine2")
    }

    @Test func probePlainTextKeepsTableCellsApart() {
        #expect(EWSBackend.plainText("<table><tr><td>Name</td><td>Value</td></tr></table>") != "NameValue")
    }

    @Test func probePlainTextDropsComments() {
        #expect(EWSBackend.plainText("<!-- if a > b then --><p>Hi</p>") == "Hi")
    }

    @Test func probePlainTextUnclosedStyleIsFast() {
        let html = String(repeating: "<style>x", count: 5_000) + String(repeating: "a", count: 100_000)
        let t = Date()
        _ = EWSBackend.plainText(html)
        #expect(Date().timeIntervalSince(t) < 5)
    }
}
```

## Expected vs actual
```
plainText("<p>Gr&uuml;&szlig;e &ndash; Till&#8217;s &euro;5 &#x27;x&#x27;</p>") → "Gr&uuml;&szlig;e &ndash; Till&#8217;s &euro;5 &#x27;x&#x27;"
plainText("Line1<br clear=\"all\">Line2") → "Line1Line2"
plainText("<table><tr><td>Name</td><td>Value</td></tr></table>") → "NameValue"
plainText("<!-- if a > b then --><p>Hi</p>") → "b then -->Hi"
probePlainTextUnclosedStyleIsFast: Date().timeIntervalSince(t) → 7.663308024406433  (< 5 expected)
```

## Why expected
HTML spec: character references must be decoded, `<br>` with attributes is a line break, comments are not content. The text is used for the message text / replies / search when TextBody is missing (`bodyRequest` always asks for item:TextBody, so on Exchange 2013+ this path is rare; the list preview comes from item:Preview, not from here).

## Likely cause
Sources/EWS/EWSBackend.swift:517-526: fixed 6-entity table (:521), `<br\s*/?>` regex (:519), generic `<[^>]*>` strip (:520) with no comment removal, backtracking regex (:518).
