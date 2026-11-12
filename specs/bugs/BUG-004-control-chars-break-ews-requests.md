---
title: Control characters in subject/body/file name/invite comment make the EWS request malformed XML, so Send/Save/Answer fails
priority: P2
area: EWS
status: open
found: 2026-11-12
---
## Summary
`xmlEscape` only escapes & < > ". Characters XML 1.0 forbids (U+0000–U+0008, U+000B, U+000C, U+000E–U+001F) are written into the SOAP body as-is, so the request is not well-formed XML. Text pasted from Word/PDF can carry U+000B (Word manual line break) or U+000C (form feed); such a message can't be sent, saved as draft, or used as an invite-answer comment.

## Repro
Tests: probeCreateRequestWithControlCharactersIsWellFormed, probeAttachmentNameWithControlCharacterIsWellFormed, probeInviteCommentWithControlCharacterIsWellFormed in specs/bugs/probes/Probe_EWSTests.swift

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

    /// Text pasted from Word/PDF often carries form feed / vertical tab; the request must stay well-formed XML.
    @Test func probeCreateRequestWithControlCharactersIsWellFormed() throws {
        for c in ["\u{000B}", "\u{000C}", "\u{0001}", "\u{001B}", "\u{0000}"] {
            let draft = Draft(accountID: UUID(), to: "a@x.com", subject: "S\(c)ubject", body: "line\(c)break")
            let xml = EWSClient.envelope(EWSBackend.createRequest(draft, send: true))
            #expect((try? XMLDocument(xmlString: xml)) != nil, "control char U+\(String(c.unicodeScalars.first!.value, radix: 16)) breaks the request")
        }
    }

    @Test func probeAttachmentNameWithControlCharacterIsWellFormed() throws {
        let files = [DraftAttachment(name: "scan\u{000C}1.pdf", contentType: "application/pdf", data: Data([1]))]
        #expect((try? request(EWSBackend.createAttachmentRequest(parentID: "I", files))) != nil)
    }

    @Test func probeInviteCommentWithControlCharacterIsWellFormed() throws {
        let reply = InviteReply(response: .decline, comment: "sorry\u{000B}next week")
        #expect((try? request(EWSBackend.respondRequest("M", reply))) != nil)
    }
}
```

## Expected vs actual
```
Test probeCreateRequestWithControlCharactersIsWellFormed() recorded an issue at Probe_EWSTests.swift:78:13: Expectation failed: (try? XMLDocument(xmlString: xml)) != nil
  control char U+b breaks the request
  (also recorded for U+c, U+1, U+1b, U+0)
Test probeAttachmentNameWithControlCharacterIsWellFormed() ... Expectation failed: (try? request(EWSBackend.createAttachmentRequest(parentID: "I", files))) != nil
Test probeInviteCommentWithControlCharacterIsWellFormed() ... Expectation failed: (try? request(EWSBackend.respondRequest("M", reply))) != nil
```

## Why expected
XML 1.0 §2.2 (Char production) excludes these code points, so any conforming parser — Foundation's here, Exchange's on the server — must reject the document. The app already handles the reverse direction (`EWSClient.sanitize`, test `controlCharacterReferencesDontBreakParsing`). Mail.app sends such text.

## Likely cause
Sources/EWS/EWSClient.swift:129-132 `xmlEscape` doesn't drop/replace XML-illegal characters; used by `createRequest` (EWSBackend.swift:392-394), `createAttachmentRequest` (:328), `respondRequest` (:226), `mailTipsRequest` (:298).
