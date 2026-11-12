---
title: "Moving a picture to another place in the text doesn't count as a change, so closing the window discards it without asking"
priority: P4
area: Models
status: open
found: 2026-11-12
---
## Summary
`Draft.hasChanges(since:)` compares `text` (the body without the U+FFFC file marks) and the non-original attachments. Moving a placed picture changes only where the mark sits, which `text` doesn't show. A compose window whose only edit is moving a picture closes without the "Save this message as a draft?" sheet, and the edit is lost.

## Repro
Tests: `movingAPlacedPictureIsAChange` in `specs/bugs/probes/Probe_Store2Tests.swift`.

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

    /// Moving a picture to another place in the text is a change: closing the window must ask.
    @Test func movingAPlacedPictureIsAChange() {
        var d = Draft(accountID: work.id, to: "a@x.com", subject: "S", body: "\u{FFFC}Hello world")
        d.attachments = [DraftAttachment(name: "p.png", contentType: "image/png", data: Data([1]))]
        let start = d
        d.body = "Hello world\u{FFFC}"
        #expect(d.hasChanges(since: start))
    }
}
```

## Expected vs actual
Actual:
```
movingAPlacedPictureIsAChange(): Expectation failed: d.hasChanges(since: start)
  d.hasChanges(since: start) → false
```

## Why expected
README ✅: "Closing a message you changed without sending it asks first, with Mail's sheet", and pictures can be dragged "to another place" in the text. Placement matters because pictures are sent in their place (HTML with `cid:`).

## Likely cause
`Sources/MailModel/Models.swift:233-235`: `userContent` uses `text` (marks filtered out) instead of `body`. Original files' marks would need to be filtered separately so that their arrival still doesn't count.

## Also seen by
Another probe hunt found the same root cause ( in `specs/bugs/probes/`).
