---
title: drop() returns true for an already-flagged Trash message dropped on Flagged, although nothing changed
priority: P4
area: MailStore
status: open
found: 2026-11-12
---
## Summary
`drop(_:on:)` is documented to return false when nothing changed. For Flagged it treats every message not *listed* in Flagged as "moving"; a Trash message (never listed in Flagged) that already has a flag is unchanged by the drop, yet the call returns true, so the drop is accepted in the UI.

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

    @Test func dropOnFlaggedOfAnAlreadyFlaggedTrashMessageChangesNothing() {
        let a = msg(work, .trash, flag: .blue)
        let s = store([a])
        let r = s.drop([a.id], on: .smart(.flagged))
        #expect(s.message(a.id)?.flag == .blue && s.message(a.id)?.mailbox == .trash)
        #expect(!r, "drop reported a change although the message is unchanged")
    }
}
```

## Expected vs actual
```
Test dropOnFlaggedOfAnAlreadyFlaggedTrashMessageChangesNothing() recorded an issue at Probe_StoreCoreTests.swift:149:9: Expectation failed: !r
  drop reported a change although the message is unchanged
```

## Why expected
Doc comment on `drop` (`MailStore.swift:432`): "Returns false when nothing changed." Existing test `dropOnCurrentMailboxChangesNothing` pins that contract for mailboxes.

## Likely cause
`Sources/MailModel/MailStore.swift:436`: `moving` = messages with `!contains(ref, $0)`; for `.smart(.flagged)` membership also requires `mailbox != .trash`, but the drop only sets a flag when there is none (`:446`), so a flagged Trash message counts as moving but isn't changed.
