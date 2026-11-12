---
title: parseBody builds an invite for any item with Start/End (e.g. a MeetingResponse), while message() limits invites to requests/cancellations
priority: P4
area: EWS
status: open
found: 2026-11-12
---
## Summary
`parseInvite` doesn't check `item.localName`; `message()` does (MeetingRequest/MeetingCancellation only). If an "Accepted: …" MeetingResponse carries Start/End, `parseBody` returns an invite, MailStore sets `isInvite = true` (MailStore.swift:843) and the detail view would show Accept/Decline on a response.

## Repro
Tests: probeMeetingResponseIsNotAnInvite in specs/bugs/probes/Probe_EWSTests.swift

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

    /// "Accepted: …" answers carry the meeting's Start/End in Exchange 2013; they are not invites to answer.
    @Test func probeMeetingResponseIsNotAnInvite() throws {
        let d = try doc("""
            <t:MeetingResponse><t:ItemId Id="R1"/><t:Body BodyType="Text">ok</t:Body>
            <t:Start>2026-11-23T11:30:00Z</t:Start><t:End>2026-11-23T12:00:00Z</t:End><t:Location>Room</t:Location></t:MeetingResponse>
            """)
        let item = d.first("MeetingResponse")!
        #expect(EWSBackend.message(item)?.isInvite == false)
        #expect(EWSBackend.parseBody(item).invite == nil)
    }
}
```

## Expected vs actual
```
Expectation failed: EWSBackend.parseBody(item).invite == nil
  EWSBackend.parseBody(item).invite → Invite(start: 2026-11-23 11:30:00 +0000, end: 2026-11-23 12:00:00 +0000, location: "Room", isAllDay: false, organizer: nil, required: [], optional: [], response: nil, reply: nil, isCancellation: Optional(false))
(EWSBackend.message(item)?.isInvite == false passed — list and body disagree)
```

## Why expected
Consistency with `message()` (EWSBackend.swift:500). Caveat: EWSBackend.swift:166 says the invite props are "only meeting requests return them (checked on the real server)", so the trigger (Start/End on a MeetingResponse) may not occur on this server; the EWS 2013 schema does define Start/End on MeetingResponseMessageType.

## Likely cause
Sources/EWS/EWSBackend.swift:200-209 `parseInvite` has no item-type check; called unconditionally from `parseBody` (:513).
