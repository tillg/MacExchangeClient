---
title: A message erased from Trash comes back when a Trash page or the newest lookup lists it before the queued delete reached the server
priority: P3
area: MailStore
status: open
found: 2026-11-12
---
## Summary
Erasing removes the message from memory and queues `.delete`. `merge` protects messages with queued changes only when they are still in memory, so a Trash sync page (or the history's newest-200 lookup) fetched before the delete went through appends the server copy as a new message: the erased mail reappears in Trash under a new local ID. The same happens for any message gone locally while a change for it is queued (e.g. an Inbox page that still lists a message moved to Trash and then erased).

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

    /// A message erased from Trash (delete still queued) must not come back when a Trash page that was
    /// fetched before the erase reached the server lists it.
    @Test func erasedMessageIsNotBroughtBackByATrashPageWhileItsDeleteIsQueued() {
        let s = synced(["A"], in: .trash)
        let a = id(s, "A")
        s.delete([a])
        #expect(s.message(a) == nil)
        #expect(s.outbox.map(\.change) == [.delete(["A"])])
        s.apply(page([remote("A")], token: "t1"), account: work.id, mailbox: .trash)
        #expect(s.messages.filter { $0.remoteID == "A" }.isEmpty, "erased message is back in Trash")
    }

    /// Same, through the history's newest-200 lookup.
    @Test func erasedMessageIsNotBroughtBackByTheNewestLookup() {
        let s = synced(["A"], in: .trash)
        s.delete([id(s, "A")])
        s.merge([remote("A")], account: work.id, mailbox: .trash)
        #expect(s.count(.account(work.id, .trash)) == 0)
    }
}
```

## Expected vs actual
Expected: no message with remote ID "A" after the page (its delete is still in the outbox). Actual: A is back in Trash.

Actual (`swift test --filter Probe_SyncTests`, run 2026-11-12):
```
Test erasedMessageIsNotBroughtBackByTheNewestLookup() recorded an issue at Probe_SyncTests.swift:91:9: Expectation failed: s.count(.account(work.id, .trash)) == 0
    s.count(.account(work.id, .trash)) == 0 → false
      s.count(.account(work.id, .trash)) → 1
Test erasedMessageIsNotBroughtBackByATrashPageWhileItsDeleteIsQueued() recorded an issue at Probe_SyncTests.swift:83:9: Expectation failed: s.messages.filter { $0.remoteID == "A" }.isEmpty
    erased message is back in Trash
    s.messages.filter { $0.remoteID == "A" }.isEmpty → false
      s.messages.filter { $0.remoteID == "A" } → [MailModel.Message(id: 271BF74E-87E5-42EC-ADA7-ABDE9B2DEE59, accountID: FECDDC98-F3B8-4AED-A20D-1E825C5DA8A0, mailbox: MailModel.MailboxKind(rawValue: "trash"), from: MailModel.Contact(name: "Ann", email: "ann@x.com"), to: [MailModel.Contact(name: "Me", email: "")], cc: [MailModel.Contact(name: "Bob", email: "")], subject: "Hi", body: "", date: 1970-01-12 13:46:40 +0000, isRead: false, flag: nil, category: MailModel.MailCategory.primary, isVIP: false, attachments: [], remoteID: Optional("A"), hasAttachments: false, serverPreview: Optional("preview"), bodyLoaded: false, isInvite: nil, invite: nil, html: nil, htmlChecked: nil, conversationID: nil)]
      isEmpty → false
Test erasedMessageIsNotBroughtBackByTheNewestLookup() failed after 3.760 seconds with 1 issue.
Test erasedMessageIsNotBroughtBackByATrashPageWhileItsDeleteIsQueued() failed after 3.760 seconds with 1 issue.
```

## Why expected
- Existing test `pendingChangesSurviveASyncThatRacesThem`: "The server hasn't seen the changes yet and reports the old state" – queued changes are meant to win over stale server pages; `merge` doc: "Messages with a change still waiting for the server keep their local read state, flag and mailbox."
- The history runs concurrently with the outbox drain (both on the main actor, interleaved at awaits), and offline the delete waits in the outbox while later pages arrive.

## Likely cause
`Sources/MailModel/MailStore.swift:559-573` (`merge`): `pending` is only consulted inside `if let rid = m.remoteID, let i = index[rid]`; a pending rid without a message in memory falls into the `else` branch and is appended. A queued `.delete` should make the upsert be skipped.
