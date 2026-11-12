---
title: Changes queued for a message that the server reports deleted stay in the outbox and are sent anyway
priority: P4
area: MailStore
status: open
found: 2026-11-12
---
## Summary
When a sync deletes a message (deletion elsewhere wins over a queued read/flag change), its queued `setRead`/`setFlagged` entries stay in the outbox with that ID. They are sent, refused ("not found"), and the user sees "Exchange refused a change" for a message that no longer exists; through BUG-023's mechanism `failed` then even re-appends the deleted message.

## Repro
```swift
import Foundation
import Testing
@testable import MailModel

@MainActor
struct Probe_SyncTests {
    let work = Account(name: "Work", address: "me@work.com")
    let home = Account(name: "iCloud", address: "me@icloud.com")

    func store(_ msgs: [Message] = []) -> MailStore { MailStore(accounts: [work, home], messages: msgs) }

    /// Like an EWS list summary: no body, recipients as display names only (EWSBackend.message).
    func remote(_ rid: String, subject: String = "Hi", read: Bool = false, minutesAgo: Double = 0,
                flag: FlagColor? = nil) -> Message {
        var m = Message(accountID: work.id, from: Contact(name: "Ann", email: "ann@x.com"),
                        to: [Contact(name: "Me", email: "")], cc: [Contact(name: "Bob", email: "")],
                        subject: subject, body: "", date: Date(timeIntervalSince1970: 1_000_000 - minutesAgo * 60),
                        isRead: read, flag: flag, remoteID: rid, bodyLoaded: false)
        m.serverPreview = "preview"
        return m
    }

    func page(_ ups: [Message] = [], del: [String] = [], reads: [String: Bool] = [:], token: String = "t",
              more: Bool = false) -> SyncResult {
        SyncResult(upserts: ups, deletedRemoteIDs: del, readChanges: reads, token: token, more: more)
    }

    func synced(_ rids: [String], in box: MailboxKind = .inbox) -> MailStore {
        let s = store()
        s.apply(page(rids.map { remote($0) }, token: "t0"), account: work.id, mailbox: box)
        return s
    }

    func id(_ s: MailStore, _ rid: String) -> Message.ID { s.messages.first { $0.remoteID == rid }!.id }

    /// A message deleted elsewhere: its queued read/flag changes can't be written any more and must leave the outbox
    /// (else they are sent, refused, and show "Exchange refused a change").
    @Test func serverDeletionDropsTheMessagesQueuedChanges() {
        let s = synced(["A", "B"])
        s.toggleRead([id(s, "A")])
        s.setFlag(.red, for: [id(s, "A"), id(s, "B")])
        s.apply(page(del: ["A"], token: "t1"), account: work.id, mailbox: .inbox)
        #expect(s.message(id(s, "B")) != nil)
        let ids = s.outbox.flatMap(\.change.remoteIDs)
        #expect(!ids.contains("A"), "outbox still has \(s.outbox.map(\.change))")
    }
}
```

## Expected vs actual
Expected: the outbox no longer mentions "A" (B's flag change remains). Actual: `outbox still has [setRead(["A"], true), setFlagged(["A", "B"], true)]`.

Actual (`swift test --filter Probe_SyncTests`, run 2026-11-12):
```
Test serverDeletionDropsTheMessagesQueuedChanges() recorded an issue at Probe_SyncTests.swift:127:9: Expectation failed: !ids.contains("A")
    outbox still has [MailModel.ServerChange.setRead(["A"], true), MailModel.ServerChange.setFlagged(["A", "B"], true)]
    !ids.contains("A") → true
      ids.contains("A") → false
        ids → ["A", "A", "B"]
Test serverDeletionDropsTheMessagesQueuedChanges() failed after 3.576 seconds with 1 issue.
```

## Why expected
- Existing test `deletionElsewhereWinsOverAPendingReadChange`: the deletion wins, so the queued change for the deleted message is moot.
- README: "If the server refuses a change, it is undone and the reason shows" – a refusal notice for a change that cannot apply any more is spurious. Cross-reference BUG-023 (the re-append); the fix here is in `merge`, not `failed`.

## Likely cause
`Sources/MailModel/MailStore.swift:540-551` (`merge`) removes deleted messages but never prunes their remote IDs from `outbox` entries.
