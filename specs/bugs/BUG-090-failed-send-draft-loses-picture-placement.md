---
title: "The draft kept after a failed send loses where the pictures were placed in the text"
priority: P4
area: MailStore
status: open
found: 2026-11-12
---
## Summary
A message with a picture placed in the text (a `\u{FFFC}` mark, sent as HTML with `cid:`) that fails to send is kept in Drafts with `body: d.text`, which has the marks stripped, and no HTML. The kept copy has the picture as a trailing attachment and the text closes up around where it was.

## Repro
Tests: `failedSendKeepsPlacedPictureInItsPlace` in `specs/bugs/probes/Probe_Store2Tests.swift`.

```swift
import Foundation
import Testing
@testable import EWS
@testable import MailModel

@MainActor
struct Probe_Store2Tests {
    let work = Account(name: "Work", address: "me@work.com")
    let home = Account(name: "iCloud", address: "me@icloud.com")

    func msg(_ acct: Account, _ box: MailboxKind = .inbox, subject: String = "Hi", from: String = "Ann",
             read: Bool = false, minutesAgo: Double = 0, flag: FlagColor? = nil) -> Message {
        Message(accountID: acct.id, mailbox: box, from: Contact(name: from, email: "\(from.lowercased())@x.com"),
                to: [Contact(name: "Me", email: acct.address)], subject: subject, body: "Body of \(subject)",
                date: Date(timeIntervalSince1970: 1_000_000 - minutesAgo * 60), isRead: read, flag: flag)
    }

    /// Like a server summary (EWS FindItem/SyncFolderItems): no body, names only for From/To.
    func summary(_ acct: Account, _ rid: String, subject: String = "Hi", minutesAgo: Double = 0) -> Message {
        var m = Message(accountID: acct.id, from: Contact(name: "Ann Lee", email: ""), to: [Contact(name: "Me", email: "")],
                        subject: subject, body: "", date: Date(timeIntervalSince1970: 1_000_000 - minutesAgo * 60),
                        remoteID: rid, serverPreview: "Can we meet on Friday?", bodyLoaded: false)
        m.conversationID = nil
        return m
    }

    func store(_ msgs: [Message]) -> MailStore { MailStore(accounts: [work, home], messages: msgs) }

    func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("ProbeStore2-\(UUID())")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func invite(organizer: Contact? = Contact(name: "Org", email: "org@x.com")) -> Invite {
        Invite(start: Date(timeIntervalSince1970: 2_000_000), end: Date(timeIntervalSince1970: 2_003_600),
               organizer: organizer)
    }

    /// The draft kept after a failed send keeps the picture where it was placed.
    @Test func failedSendKeepsPlacedPictureInItsPlace() {
        let s = store([])
        s.merge([(.inbox, [])], account: work.id)
        var d = Draft(accountID: work.id, to: "a@x.com", subject: "S", body: "Look:\n\u{FFFC}\nnice")
        d.attachments = [DraftAttachment(name: "p.png", contentType: "image/png", data: Data([1, 2]))]
        s.failed(PendingChange(account: work.id, change: .send(d), previous: []), "busy")
        let kept = s.messages.first { $0.mailbox == .drafts }
        #expect(kept?.body.contains("\u{FFFC}") == true || kept?.html?.contains("cid:") == true,
                "body: \(String(reflecting: kept?.body)), html: \(String(describing: kept?.html))")
    }
}
```

## Expected vs actual
Actual:
```
failedSendKeepsPlacedPictureInItsPlace(): Expectation failed: kept?.body.contains("\u{FFFC}") == true || kept?.html?.contains("cid:") == true
  body: Optional("Look:\n\nnice"), html: nil
```

## Why expected
README: pictures "placed in the text go out in their place". The draft is the only copy of a message that wasn't sent, and it should be what the user wrote.

## Likely cause
`Sources/MailModel/MailStore.swift:730-734`: `body: d.text` (marks removed) and no `html: d.html(...)` for placed pictures.
