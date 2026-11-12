---
title: Opening a message with the unread filter on (or in the Unread mailbox) removes it from the list at once
priority: P2
area: MailStore
status: open
found: 2026-11-12
---
## Summary
Selecting a message marks it read (`markSelectionRead`), and `visibleMessages` immediately filters read messages out under the unread filter and in the Unread smart mailbox. The row the user just clicked vanishes while the message stays selected and displayed (see also 01: it can then be erased by pressing Delete twice). Model state only; the running UI was not observed.

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

    @Test func unreadFilterKeepsTheOpenedMessageInTheList() {
        let a = msg(work, subject: "a", minutesAgo: 1), b = msg(work, subject: "b", minutesAgo: 2)
        let s = store([a, b])
        s.selectedMailbox = .account(work.id, .inbox)
        s.filterUnread = true
        s.selection = [a.id]
        s.markSelectionRead()  // what MessageListView does on selection change
        #expect(s.visibleMessages.map(\.id).contains(a.id))
    }

    @Test func unreadSmartMailboxKeepsTheOpenedMessageInTheList() {
        let a = msg(work, subject: "a", minutesAgo: 1), b = msg(work, subject: "b", minutesAgo: 2)
        let s = store([a, b])
        s.selectedMailbox = .smart(.unread)
        s.selection = [a.id]
        s.markSelectionRead()
        #expect(s.visibleMessages.map(\.id).contains(a.id))
    }
}
```

## Expected vs actual
```
Test unreadFilterKeepsTheOpenedMessageInTheList() recorded an issue at Probe_StoreCoreTests.swift:31:9: Expectation failed: s.visibleMessages.map(\.id).contains(a.id)
  s.visibleMessages.map(\.id) → [D639D936-…]   (only b)
  a.id → 31C2CE45-…
Test unreadSmartMailboxKeepsTheOpenedMessageInTheList() recorded an issue at Probe_StoreCoreTests.swift:41:9: Expectation failed: s.visibleMessages.map(\.id).contains(a.id)
  s.visibleMessages.map(\.id) → [50F03F9B-…]   (only b)
```

## Why expected
⚠️ From memory of Mail, not observed: Mail keeps the message being read in the filtered list (Unread filter ⌘L, Unread smart mailbox) until the user moves away; otherwise the filter can't be used to read through unread mail — every click removes the row and loses the list position, and next/previous navigation has no anchor. README: "Marked read when shown" + "unread filter" (⚠️ tested in MailStoreTests, which never combine the two).

## Likely cause
`Sources/MailModel/MailStore.swift:188` (`if filterUnread && m.isRead { return false }`) and `:117` (`.smart(.unread)` = `!m.isRead && inbox`) recompute membership on every change; nothing keeps the current selection in the list. Triggered by `MessageListView.swift:72-76` calling `markSelectionRead()` on selection change.
