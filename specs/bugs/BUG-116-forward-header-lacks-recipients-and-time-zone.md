---
title: 'The forward header leaves out To and Cc (and the date has no time zone), so the forward loses who the original went to'
priority: P4
area: MailStore
status: open
found: 2026-11-13
---
## Summary
The "Begin forwarded message:" block has only From, Subject and Date. The recipient of the forward can't see who the original was addressed or copied to, and the date has no zone, so someone in another time zone reads the wrong time.

## Repro
```swift
import Foundation
import Testing
@testable import EWS
@testable import MailModel

@MainActor
struct Probe_ComposeTests {
    let work = Account(name: "Work", address: "me@work.com")
    let home = Account(name: "iCloud", address: "me@icloud.com")
    let mark = String(Draft.fileMark)

    func msg(_ acct: Account, _ box: MailboxKind = .inbox, subject: String = "Hi", from: Contact? = nil,
             to: [Contact]? = nil, cc: [Contact] = [], body: String = "Body") -> Message {
        Message(accountID: acct.id, mailbox: box, from: from ?? Contact(name: "Ann", email: "ann@x.com"),
                to: to ?? [Contact(name: "Me", email: acct.address)], cc: cc, subject: subject, body: body,
                date: Date(timeIntervalSince1970: 1_000_000))
    }

    func store(_ msgs: [Message]) -> MailStore { MailStore(accounts: [work, home], messages: msgs) }

    func png(_ name: String, _ bytes: Int = 4) -> DraftAttachment {
        DraftAttachment(name: name, contentType: "image/png", data: Data(repeating: 7, count: bytes))
    }

    /// Mail's "Begin forwarded message:" block carries the time zone and the recipients (To, Cc).
    @Test func forwardHeaderHasTimeZoneAndRecipients() {
        let m = msg(work, from: Contact(name: "Ann", email: "ann@x.com"),
                    to: [Contact(name: "Bob", email: "bob@x.com")], cc: [Contact(name: "Cy", email: "cy@x.com")])
        let s = store([m])
        let body = s.draft(.forward, to: m.id).body
        let dateLine = body.split(separator: "\n").first { $0.hasPrefix("Date:") }.map(String.init) ?? ""
        let tz = TimeZone.current
        let zoneNames = [tz.abbreviation(for: m.date) ?? "~", "GMT", "UTC", tz.identifier,
                         tz.localizedName(for: .standard, locale: .current) ?? "~", tz.localizedName(for: .daylightSaving, locale: .current) ?? "~"]
        #expect(zoneNames.contains { dateLine.contains($0) }, "Date line has no time zone: \(dateLine)")
        #expect(body.contains("To: Bob <bob@x.com>"), "no To line: \(body.debugDescription)")
        #expect(body.contains("Cc: Cy <cy@x.com>"), "no Cc line: \(body.debugDescription)")
    }

}
```

## Expected vs actual
Expected lines `To: Bob <bob@x.com>` and `Cc: Cy <cy@x.com>`, and a zone on the Date line. Actual body:
```
"\n\nBegin forwarded message:\n\nFrom: Ann <ann@x.com>\nSubject: Hi\nDate: 12. Jan 1970 at 14:46\n\n> Body"
```

## Why expected
⚠️ Recalled, not read from Mail's bundle: Mail's forwarded-message block lists From, Subject, Date (with seconds and zone, e.g. "… at 10:15:23 CET"), To and, when present, Cc and Reply-To. The To/Cc lines are the information lost. The time zone is secondary.

## Likely cause
`MailStore.swift` `draft(_:to:)`, the `header` for `.forward`: `"From: …\nSubject: …\nDate: \(df.string(from: m.date))\n\n"`, with `df` using `.medium`/`.short` styles and no zone. `m.to`/`m.cc` are not used.
