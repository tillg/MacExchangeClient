---
title: '`&#xFFFE;`/`&#xFFFF;`/surrogate references in a response still make the whole page unreadable'
priority: P3
area: EWS
status: open
found: 2026-11-12
---
## Summary
`EWSClient.sanitize` replaces only C0 control character references. References to U+FFFE, U+FFFF and surrogates (U+D800–U+DFFF) are equally illegal in XML 1.0, so `XMLDocument` still throws and the whole FindItem/SyncFolderItems page fails with "Unreadable EWS response" — the failure `sanitize` exists to prevent.

## Repro
Tests: probeNonCharacterReferencesDontBreakParsing in specs/bugs/probes/Probe_EWSTests.swift

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

    @Test func probeNonCharacterReferencesDontBreakParsing() throws {
        for ref in ["&#xFFFE;", "&#xFFFF;", "&#65535;", "&#xD800;", "&#55296;"] {
            let raw = "<a><s>x\(ref)y</s></a>"
            #expect((try? XMLDocument(data: EWSClient.sanitize(Data(raw.utf8)))) != nil, "\(ref) fails the page")
        }
    }
}
```

## Expected vs actual
```
Expectation failed: (try? XMLDocument(data: EWSClient.sanitize(Data(raw.utf8)))) != nil
  &#xFFFE; fails the page
  &#xFFFF; fails the page
  &#65535; fails the page
  &#xD800; fails the page
  &#55296; fails the page
```

## Why expected
XML 1.0 Char = #x9 | #xA | #xD | [#x20-#xD7FF] | [#xE000-#xFFFD] | [#x10000-#x10FFFF]. The existing test `controlCharacterReferencesDontBreakParsing` states the intent: bad references become U+FFFD instead of failing the page.

## Likely cause
Sources/EWS/EWSClient.swift:64-65 `invalidCharRef` covers only 0–31 (minus 9/10/13).
