---
title: Inline pictures sent as `application/octet-stream` are never fetched, so the HTML shows a broken image
priority: P3
area: EWS
status: open
found: 2026-11-12
---
## Summary
`inlineAttachmentIDs` only considers attachments whose ContentType starts with `image/`. Several mailers send cid-referenced pictures as `application/octet-stream` (name `image001.png`). Even though the HTML references the content ID, the attachment is skipped, so the picture never loads.

## Repro
Tests: probeInlineImageWithGenericContentType in specs/bugs/probes/Probe_EWSTests.swift

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

    @Test func probeInlineImageWithGenericContentType() throws {
        let d = try doc("""
            <t:Message><t:Attachments><t:FileAttachment><t:AttachmentId Id="A1"/><t:Name>image001.png</t:Name>
            <t:ContentType>application/octet-stream</t:ContentType><t:ContentId>image001.png@01D</t:ContentId></t:FileAttachment></t:Attachments></t:Message>
            """)
        #expect(EWSBackend.inlineAttachmentIDs(d.first("Message")!, wanted: ["image001.png@01D"]) == ["A1"])
    }
}
```

## Expected vs actual
```
EWSBackend.inlineAttachmentIDs(d.first("Message")!, wanted: ["image001.png@01D"]) → []   (expected ["A1"])
```

## Why expected
Doc comment: "Image attachments the HTML refers to, whether or not Exchange marks them inline." An attachment the HTML references by `cid:` in an `<img>` is meant to be drawn; Mail.app shows such pictures.

## Likely cause
Sources/EWS/EWSBackend.swift:100 `ContentType…hasPrefix("image/")` guard; the `wanted` content-ID match alone already restricts it to referenced parts.
