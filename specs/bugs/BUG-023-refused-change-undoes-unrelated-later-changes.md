---
title: A refused server change restores the whole old message, undoing later queued changes (e.g. a move) or resurrecting an erased message
priority: P3
area: MailStore
status: open
found: 2026-11-12
---
## Summary
`failed(_:_:)` undoes a refused change by copying mailbox, read state, flag and invite back from the snapshot taken when *that* change was queued. A later change still queued (or already sent) is undone locally too, so the local state no longer matches what the outbox will do on the server; an erased message is appended back.

## Repro
```swift
import Foundation
import Testing
@testable import MailModel

@MainActor
struct Probe_StoreCoreTests {
    let work = Account(name: "Work", address: "me@work.com")
    let home = Account(name: "iCloud", address: "me@icloud.com")

    func msg(_ acct: Account, _ box: MailboxKind = .inbox, subject: String = "Hi", from: String = "Ann",
             read: Bool = false, minutesAgo: Double = 0, flag: FlagColor? = nil, rid: String? = nil,
             conv: String? = nil) -> Message {
        var m = Message(accountID: acct.id, mailbox: box, from: Contact(name: from, email: "\(from.lowercased())@x.com"),
                        to: [Contact(name: "Me", email: acct.address)], subject: subject, body: "Body of \(subject)",
                        date: Date(timeIntervalSince1970: 1_000_000 - minutesAgo * 60), isRead: read, flag: flag,
                        remoteID: rid)
        m.conversationID = conv
        return m
    }

    func store(_ msgs: [Message]) -> MailStore { MailStore(accounts: [work, home], messages: msgs) }

    @Test func refusedReadChangeDoesNotUndoALaterMove() {
        let m = msg(work, rid: "R")
        let s = store([m])
        s.toggleRead([m.id])
        s.move([m.id], to: .archive)
        #expect(s.outbox.count == 2)
        s.failed(s.outbox[0], "refused")
        #expect(s.message(m.id)?.isRead == false)
        #expect(s.message(m.id)?.mailbox == .archive, "the move is still queued for the server")
    }

    @Test func refusedMoveDoesNotResurrectAnErasedMessage() {
        let m = msg(work, rid: "R")
        let s = store([m])
        s.archive([m.id])            // move → archive (queued)
        s.delete([m.id])             // move → trash (queued)
        s.delete([m.id])             // erase (queued delete)
        #expect(s.message(m.id) == nil)
        s.failed(s.outbox[0], "refused")
        #expect(s.message(m.id) == nil, "erased message is back in the Inbox while its delete is still queued")
    }
}
```

## Expected vs actual
```
Test refusedReadChangeDoesNotUndoALaterMove() recorded an issue at Probe_StoreCoreTests.swift:76:9: Expectation failed: s.message(m.id)?.mailbox == .archive
  the move is still queued for the server
  s.message(m.id)?.mailbox → MailboxKind(rawValue: "inbox")
Test refusedMoveDoesNotResurrectAnErasedMessage() recorded an issue at Probe_StoreCoreTests.swift:270:9: Expectation failed: s.message(m.id) == nil
  erased message is back in the Inbox while its delete is still queued
  s.message(m.id) → Message(... mailbox: "inbox", ... remoteID: Optional("R") ...)
```

## Why expected
README: "If the server refuses a change, it is undone" — *that* change. A refused read change must not move the message back to the Inbox while the move to Archive is still queued (the server will archive it; the app then shows it in the Inbox until a later sync). Existing test `rejectedChangeIsUndoneLocally` fails the *latest* change (and expects a refused erase to bring the message back – that re-adding is intended); it never fails an *earlier* change while a later one on the same message is still queued, which is the gap here.

## Likely cause
`Sources/MailModel/MailStore.swift:738-749`: the `default:` branch restores `mailbox`, `isRead`, `flag` and `invite` from `p.previous` regardless of which field the change touched, and `messages.append(old)` when the message is gone. Re-adding is right for a refused erase, but not when the message was erased by a *later* change that is still queued. Restoring only the field of `p.change` (read → isRead, flagged → flag, move → mailbox) and skipping messages with later queued changes would avoid it.
