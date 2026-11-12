---
title: Archive while viewing Archive changes nothing but moves the selection to the next message
priority: P4
area: MailStore
status: open
found: 2026-11-12
---
## Summary
`actOnSelection` always selects the next message, even when the selected messages are still in the list afterwards. Archive (⌃⌘A / toolbar) in the Archive mailbox leaves the message where it is but jumps to the next one (which is then marked read by the list).

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

    @Test func archivingInArchiveKeepsTheSelection() {
        let a = msg(work, .archive, subject: "a", minutesAgo: 1), b = msg(work, .archive, subject: "b", minutesAgo: 2)
        let s = store([a, b])
        s.selectedMailbox = .account(work.id, .archive)
        s.selection = [a.id]
        s.archiveSelection()
        #expect(s.message(a.id)?.mailbox == .archive)
        #expect(s.selection == [a.id])
    }
}
```

## Expected vs actual
```
Test archivingInArchiveKeepsTheSelection() recorded an issue at Probe_StoreCoreTests.swift:140:9: Expectation failed: s.selection == [a.id]
  s.selection → [8D64AA1C-…]  (b)
  [a.id] → [E01C26CE-…]
```
Inferred, not observed: b, never looked at, then gets marked read by `MessageListView`'s selection handler (`MessageListView.swift:72-76`).

## Why expected
README: "After an action the next message is selected, as in Mail" – the next message replaces one that left the list. Here nothing happened (⚠️ from memory, not observed: Mail disables Archive in the Archive mailbox). Note: `droppingSelectionPartlyAlreadyThereStillSelectsNext` deliberately advances when *some* messages moved; this probe is the case where none did.

## Likely cause
`Sources/MailModel/MailStore.swift:403-414`: the next selection is picked unconditionally after `action(ids)`; it does not check whether any selected message actually left `visibleMessages` (or changed at all).
