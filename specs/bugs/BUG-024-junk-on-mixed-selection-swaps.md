---
title: Move to Junk on a mixed selection swaps each message (junk ones go to the Inbox)
priority: P3
area: MailStore
status: open
found: 2026-11-12
---
## Summary
`toggleJunk` flips every message independently. With a selection that has both junk and non-junk messages (e.g. in Flagged, which lists Junk mail), "Move to Junk" (⇧⌘J, toolbar, context menu) moves the junk ones out to the Inbox and the others into Junk.

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

    @Test func junkOnMixedSelectionMovesAllToJunk() {
        let a = msg(work, .junk, subject: "a", flag: .red), b = msg(work, subject: "b", flag: .red)
        let s = store([a, b])
        s.toggleJunk([a.id, b.id])
        #expect(s.message(a.id)?.mailbox == .junk)
        #expect(s.message(b.id)?.mailbox == .junk)
    }
}
```

## Expected vs actual
```
Test junkOnMixedSelectionMovesAllToJunk() recorded an issue at Probe_StoreCoreTests.swift:63:9: Expectation failed: s.message(a.id)?.mailbox == .junk
  s.message(a.id)?.mailbox → MailboxKind(rawValue: "inbox")
```

## Why expected
The command is labelled "Move to Junk" (`MailCommands.swift:82`, `MessageListView.swift:180`); ⚠️ from memory of Mail, not observed: for a multi-selection Mail applies one action to all, consistent with this app's own `toggleRead` (any unread → all read, `MailStore.swift:391-394`) and Toggle Flag (any flagged → all cleared). Existing tests (`archiveAndJunkToggle`, `junkToggleAndDropQueueMoves`) only toggle single messages.

## Likely cause
`Sources/MailModel/MailStore.swift:385-387`: `update(ids) { $0.mailbox = $0.mailbox == .junk ? .inbox : .junk }` decides per message instead of once for the set.
