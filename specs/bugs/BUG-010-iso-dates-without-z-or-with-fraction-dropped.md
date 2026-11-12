---
title: 'Dates with fractional seconds or without a zone suffix aren''t parsed: message dated year 1, invite and calendar events dropped'
priority: P3
area: EWS
status: open
found: 2026-11-12
---
## Summary
All EWS date parsing uses one default `ISO8601DateFormatter` (`.withInternetDateTime`), which rejects `2026-11-10T09:30:00.123Z` and `2026-11-23T11:30:00`. A message then gets `.distantPast` (sorts last, shows year 1), a meeting request loses its invite card, and calendar events drop out of the day column.

## Repro
Tests: probeReceivedDateWithFractionalSeconds, probeInviteStartWithoutTimeZone, probeEventsWithFractionalSeconds in specs/bugs/probes/Probe_EWSTests.swift

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

    @Test func probeReceivedDateWithFractionalSeconds() throws {
        let d = try doc("""
            <t:Message><t:ItemId Id="ID1"/><t:DateTimeReceived>2026-11-10T09:30:00.123Z</t:DateTimeReceived></t:Message>
            """)
        let m = try #require(EWSBackend.message(d.first("Message")!))
        #expect(m.date != .distantPast)
    }

    @Test func probeInviteStartWithoutTimeZone() throws {
        let d = try doc("""
            <t:MeetingRequest><t:ItemId Id="M1"/><t:Body BodyType="Text">x</t:Body>
            <t:Start>2026-11-23T11:30:00</t:Start><t:End>2026-11-23T12:00:00</t:End></t:MeetingRequest>
            """)
        #expect(EWSBackend.parseBody(d.first("MeetingRequest")!).invite != nil)
    }

    @Test func probeEventsWithFractionalSeconds() throws {
        let d = try doc("""
            <m:Items><t:CalendarItem><t:ItemId Id="C1"/><t:Subject>S</t:Subject><t:Start>2026-11-23T08:00:00.000Z</t:Start>
            <t:End>2026-11-23T08:15:00.000Z</t:End></t:CalendarItem></m:Items>
            """)
        #expect(EWSBackend.parseEvents(d).count == 1)
    }
}
```

## Expected vs actual
```
probeReceivedDateWithFractionalSeconds: m.date → 0001-01-01 00:00:00 +0000  (== .distantPast)
probeInviteStartWithoutTimeZone: EWSBackend.parseBody(d.first("MeetingRequest")!).invite → nil
probeEventsWithFractionalSeconds: EWSBackend.parseEvents(d).count → 0
```

## Why expected
The schema type of DateTimeReceived/Start/End is `xs:dateTime`, which allows fractional seconds and an absent zone. Whether this Exchange (pinned to Exchange2013_SP1) actually sends such values is unverified; the parser just rejects valid schema values.

## Likely cause
Sources/EWS/EWSBackend.swift:487 `isoDate = ISO8601DateFormatter()` without `.withFractionalSeconds` and no zone-less fallback; used at :187, :201-202, :495.
