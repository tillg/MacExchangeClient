---
title: 'An attachment Exchange flags IsInline that the body doesn''t show (text mail, no cid: reference) is neither listed nor shown: it can''t be seen or saved'
priority: P3
area: EWS
status: open
found: 2026-11-12
---
## Summary
`listedAttachments` drops every attachment with `IsInline` true, assuming the HTML shows it. When the body is plain text, or the HTML doesn't reference that Content-ID, the file is invisible: not in the attachment list, not in the text, not in Save Attachments. Apple Mail and iOS send attachments with `Content-Disposition: inline` and a Content-ID; ⚠️ Exchange is expected to report such files with IsInline true (not checked on the live server).

## Repro
Tests: probeInlineAttachmentNotReferencedIsListed in `specs/bugs/probes/Probe_EWS2Tests.swift` (suites `Probe_EWS2Tests` / `Probe_EWS2StoreTests`).
No network: `EWSClient` is pointed at a `file://` URL holding one canned Exchange response, so the real `URLSession`, `EWSClient.call`, `EWSBackend` and `MailStore` run unchanged (no mock, no fake backend). Every call of that client gets the same response.

```swift
import Foundation
import Testing
@testable import EWS
@testable import MailModel

struct Probe_EWS2Tests {
    func doc(_ body: String) throws -> XMLDocument {
        try XMLDocument(xmlString: """
            <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" \
            xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages" \
            xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types"><s:Body>\(body)</s:Body></s:Envelope>
            """)
    }
    /// A file standing in for one server response: EWSClient.call reads it through URLSession (file://).
    func responseFile(_ xml: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ews-\(UUID().uuidString).xml")
        try Data(xml.utf8).write(to: url)
        return url
    }
    func envelope(_ body: String) -> String {
        """
        <?xml version="1.0" encoding="utf-8"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" \
        xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages" \
        xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types"><s:Body>\(body)</s:Body></s:Envelope>
        """
    }
    func backend(_ xml: String) throws -> EWSBackend {
        EWSBackend(client: EWSClient(url: try responseFile(xml), username: "u", password: "p"))
    }
    func ok(_ op: String, _ inner: String = "") -> String {
        "<m:\(op)ResponseMessage ResponseClass=\"Success\"><m:ResponseCode>NoError</m:ResponseCode>\(inner)</m:\(op)ResponseMessage>"
    }
    func err(_ op: String, _ code: String) -> String {
        "<m:\(op)ResponseMessage ResponseClass=\"Error\"><m:MessageText>\(code) text</m:MessageText><m:ResponseCode>\(code)</m:ResponseCode><m:DescriptiveLinkKey>0</m:DescriptiveLinkKey></m:\(op)ResponseMessage>"
    }
    func response(_ op: String, _ messages: String) -> String {
        envelope("<m:\(op)Response><m:ResponseMessages>\(messages)</m:ResponseMessages></m:\(op)Response>")
    }

    /// An attachment Exchange flags inline that the body never shows (text body, no cid: reference): it is
    /// neither listed nor shown, so the user can't see or save it.
    @Test func probeInlineAttachmentNotReferencedIsListed() throws {
        let d = try doc("""
            <t:Message><t:ItemId Id="A"/><t:Body BodyType="Text">See the attached scan.</t:Body>
            <t:Attachments><t:FileAttachment><t:AttachmentId Id="AT1"/><t:Name>scan.pdf</t:Name>
            <t:ContentType>application/pdf</t:ContentType><t:ContentId>3A1F@apple</t:ContentId><t:Size>1234</t:Size>
            <t:IsInline>true</t:IsInline></t:FileAttachment></t:Attachments></t:Message>
            """)
        let b = EWSBackend.parseBody(d.first("Message")!)
        #expect(b.attachments.map(\.name) == ["scan.pdf"])
    }
}
```

## Expected vs actual
```
􀢄  Test probeInlineAttachmentNotReferencedIsListed() recorded an issue at Probe_EWS2Tests.swift:139:9: Expectation failed: b.attachments.map(\.name) == ["scan.pdf"]
􀄵  b.attachments.map(\.name) == ["scan.pdf"] → false
􀄵    b.attachments.map(\.name) → []
􀢄  Test probeInlineAttachmentNotReferencedIsListed() failed after 0.003 seconds with 1 issue.
```

## Why expected
README Attachments: "shown below the text. Pictures appear in place, other files as their Finder icon". Mail.app and Outlook show an inline part that the body doesn't place as an ordinary attachment. ⚠️ The exact IsInline value Exchange gives Apple-Mail attachments is recalled, not verified.

## Likely cause
Sources/EWS/EWSBackend.swift:127: `guard a.text("IsInline") != "true" …` decides by the flag alone, without checking that the HTML body references the attachment's ContentId (the body is right there in `parseBody`).
