---
title: An empty `<t:TextBody/>` next to an HTML body gives the message empty text
priority: P4
area: EWS
status: open
found: 2026-11-12
---
## Summary
`parseBody` takes `TextBody` whenever the element exists, even if empty, so the HTML→text fallback is skipped and `text` is "" although the HTML has content. Replies quote nothing and search finds nothing in the body.

## Repro
Tests: probeEmptyTextBodyFallsBackToHTML in specs/bugs/probes/Probe_EWSTests.swift

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

    @Test func probeEmptyTextBodyFallsBackToHTML() throws {
        let d = try doc("""
            <t:Message><t:ItemId Id="A"/><t:Body BodyType="HTML">&lt;p&gt;Hello&lt;/p&gt;</t:Body><t:TextBody BodyType="Text"/></t:Message>
            """)
        #expect(EWSBackend.parseBody(d.first("Message")!).text == "Hello")
    }
}
```

## Expected vs actual
```
EWSBackend.parseBody(d.first("Message")!).text → ""   (expected "Hello")
```

## Why expected
The fallback chain (`TextBody ?? plainText(html) ?? Body`) is meant to produce text when TextBody has none. Caveat: whether Exchange returns an empty TextBody for an HTML body with text is not verified on the live server.

## Likely cause
Sources/EWS/EWSBackend.swift:509: `item.child("TextBody")?.stringValue` is "" (not nil) for an empty element, so `??` never falls through.
