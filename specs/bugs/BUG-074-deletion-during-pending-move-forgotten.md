---
title: A server deletion that arrives while a move is queued is ignored for good; when the move then fails the message stays as a ghost
priority: P3
area: MailStore
status: open
found: 2026-11-12
---
## Summary
Deletions reported for a message with a queued move are skipped (on the assumption that our own move caused them). If the deletion was real (deleted on another device), the queued move is then refused ("not found"), `failed` puts the message back in the Inbox, and no later sync will report the deletion again (the sync token moved past it): the message stays in the Inbox forever although it no longer exists on the server.

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

    /// The Inbox sync says A was deleted (elsewhere) while a local move of A was queued. The move then fails
    /// (the item is gone): A must not stay in the Inbox forever – no later sync will report it again.
    @Test func deletionSeenDuringAPendingMoveIsNotForgotten() {
        let s = synced(["A"])
        let a = id(s, "A")
        s.archive([a])
        s.apply(page(del: ["A"], token: "t1"), account: work.id, mailbox: .inbox)
        s.failed(s.outbox[0], "The specified object was not found in the store.")
        s.apply(page(token: "t2"), account: work.id, mailbox: .inbox)
        #expect(s.message(a) == nil, "deleted on the server but shown in \(s.message(a)?.mailbox.rawValue ?? "-")")
    }
}
```

## Expected vs actual
Expected: after the refused move and the next sync, message A is gone. Actual: "deleted on the server but shown in inbox".

Actual (`swift test --filter Probe_SyncTests`, run 2026-11-12):
```
Test deletionSeenDuringAPendingMoveIsNotForgotten() recorded an issue at Probe_SyncTests.swift:115:9: Expectation failed: s.message(a) == nil
    deleted on the server but shown in inbox
    s.message(a) == nil → false
      s.message(a) → Message(id: D885663F-2E45-4BD1-98C4-22CD7263DAC8, accountID: 776BA0BE-BFE6-4CF5-BDD1-B85912B7490D, mailbox: MailModel.MailboxKind(rawValue: "inbox"), from: MailModel.Contact(name: "Ann", email: "ann@x.com"), to: [MailModel.Contact(name: "Me", email: "")], cc: [MailModel.Contact(name: "Bob", email: "")], subject: "Hi", body: "", date: 1970-01-12 13:46:40 +0000, isRead: false, flag: nil, category: MailModel.MailCategory.primary, isVIP: false, attachments: [], remoteID: Optional("A"), hasAttachments: false, serverPreview: Optional("preview"), bodyLoaded: false, isInvite: nil, invite: nil, html: nil, htmlChecked: nil, conversationID: nil)
        some → Message(id: D885663F-2E45-4BD1-98C4-22CD7263DAC8, accountID: 776BA0BE-BFE6-4CF5-BDD1-B85912B7490D, mailbox: MailModel.MailboxKind(rawValue: "inbox"), from: MailModel.Contact(name: "Ann", email: "ann@x.com"), to: [MailModel.Contact(name: "Me", email: "")], cc: [MailModel.Contact(name: "Bob", email: "")], subject: "Hi", body: "", date: 1970-01-12 13:46:40 +0000, isRead: false, flag: nil, category: MailModel.MailCategory.primary, isVIP: false, attachments: [], remoteID: Optional("A"), hasAttachments: false, serverPreview: Optional("preview"), bodyLoaded: false, isInvite: nil, invite: nil, html: nil, htmlChecked: nil, conversationID: nil)
          id → D885663F-2E45-4BD1-98C4-22CD7263DAC8
          accountID → 776BA0BE-BFE6-4CF5-BDD1-B85912B7490D
          mailbox → MailboxKind(rawValue: "inbox")
            rawValue → "inbox"
          from → Contact(name: "Ann", email: "ann@x.com")
            name → "Ann"
            email → "ann@x.com"
          to → [MailModel.Contact(name: "Me", email: "")]
          cc → [MailModel.Contact(name: "Bob", email: "")]
          subject → "Hi"
          body → ""
          date → 1970-01-12 13:46:40 +0000
            timeIntervalSinceReferenceDate → -977307200.0
          isRead → false
          flag → nil
          category → .primary
          isVIP → false
          attachments → []
          remoteID → "A"
            some → "A"
          hasAttachments → false
          serverPreview → "preview"
            some → "preview"
          bodyLoaded → false
          isInvite → nil
          invite → nil
          html → nil
          htmlChecked → nil
          conversationID → nil
Test deletionSeenDuringAPendingMoveIsNotForgotten() failed after 3.576 seconds with 1 issue.
```

## Why expected
- Code comment at MailStore.swift:531: "A pending move makes the source folder report the message as deleted; that one stays. Any other deletion (done elsewhere) wins". A deletion done elsewhere while a move is queued is indistinguishable at that point and must be remembered rather than dropped.
- Same state is designed for in `pendingChangesSurviveASyncThatRacesThem`.
- Not BUG-023: that one is about `failed` restoring stale fields; here the server's deletion is discarded in `merge` and nothing ever re-reports it. With BUG-023 fixed, the message would still stay.

## Likely cause
`Sources/MailModel/MailStore.swift:533-540` (`merge`): `gone = Set(deleted).subtracting(moving)` simply drops the deletion; nothing records it so it can be applied if the move fails (or the move succeeds without a rename).
