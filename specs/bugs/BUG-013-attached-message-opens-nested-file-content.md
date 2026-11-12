---
title: Opening an attached message (.eml) can return the content of a file inside it instead of its MIME source
priority: P3
area: EWS
status: open
found: 2026-11-12
---
## Summary
`parseAttachmentContent` first takes the first `FileAttachment` with `Content` anywhere in the GetAttachment response (descendant search). For an ItemAttachment whose message has file attachments returned with content, those nested bytes are returned and saved as the `.eml`, instead of the item's `MimeContent`.

## Repro
Tests: probeItemAttachmentContentPrefersMimeOverNestedFile in specs/bugs/probes/Probe_EWSTests.swift

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

    /// GetAttachment for an attached message returns the message with its own file attachments; the .eml is the MIME.
    @Test func probeItemAttachmentContentPrefersMimeOverNestedFile() throws {
        let d = try doc("""
            <m:GetAttachmentResponse><m:ResponseMessages><m:GetAttachmentResponseMessage ResponseClass="Success">
            <m:ResponseCode>NoError</m:ResponseCode><m:Attachments><t:ItemAttachment><t:AttachmentId Id="A"/><t:Name>Mail</t:Name>
            <t:Message><t:MimeContent CharacterSet="UTF-8">TUlNRQ==</t:MimeContent><t:ItemId Id="X"/>
            <t:Attachments><t:FileAttachment><t:AttachmentId Id="N"/><t:Name>n.txt</t:Name><t:Content>TkVTVEVE</t:Content></t:FileAttachment></t:Attachments>
            </t:Message></t:ItemAttachment></m:Attachments></m:GetAttachmentResponseMessage></m:ResponseMessages></m:GetAttachmentResponse>
            """)
        #expect(EWSBackend.parseAttachmentContent(d) == Data("MIME".utf8))
    }
}
```

## Expected vs actual
```
Expectation failed: EWSBackend.parseAttachmentContent(d) == Data("MIME".utf8)
  EWSBackend.parseAttachmentContent(d) → 6 bytes
(annotation: 6 bytes = "NESTED", the base64 TkVTVEVE of the inner n.txt; "MIME" would be 4 bytes)
```

## Why expected
Doc comment: "A file's content, or an attached message's MIME source." Caveat: depends on the server including nested FileAttachment Content in GetAttachment for an item attachment (Microsoft's GetAttachment item-attachment example nests the item's Attachments); not verified on the live server. A similar descendant-search issue exists in `listedAttachments` (`a.text("IsInline")`, EWSBackend.swift:127), but GetItem with item:Attachments returns only attachment metadata (no nested item), so that shape is unrealistic and not filed.

## Likely cause
Sources/EWS/EWSBackend.swift:143-146: `doc.first("FileAttachment")` searches the whole document; it should take the top-level attachment under `m:Attachments` and branch on its own type.
