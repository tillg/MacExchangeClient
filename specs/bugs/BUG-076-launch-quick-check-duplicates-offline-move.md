---
title: At launch, the Inbox check duplicates a message that was moved offline last session (its queued move is restored, the message is not in memory yet)
priority: P3
area: MailStore
status: open
found: 2026-11-12
---
## Summary
Launch loads the Inbox first and checks it with the server while the other mailboxes load. A message moved to Archive while offline last session is in Archive on disk (not loaded yet) and its move is still queued. If the Inbox delta lists it (e.g. read on the phone), `merge` doesn't find it in memory and appends it to the Inbox; `finishLoading` then adds the stored Archive copy as well (it dedups by local ID only). Result: the same server message in Inbox and Archive.

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

    /// Launch: a move made offline last session is still queued; the moved message sits in Archive on disk
    /// (not loaded yet). The quick check of the Inbox reports a change of it (read on the phone). After loading,
    /// there must be one message, not one in the Inbox and one in the Archive.
    @Test func quickCheckDuringLaunchDoesNotDuplicateAMessageMovedOfflineLastSession() {
        var moved = remote("A"); moved.accountID = work.id; moved.mailbox = .archive
        var inboxMsg = remote("B"); inboxMsg.accountID = work.id
        let s = store()
        var meta = StoredMeta()
        meta.sync = [SyncState(account: work.id, mailbox: .inbox, token: "t0", complete: true)]
        meta.outbox = [PendingChange(account: work.id, change: .move(["A"], to: .archive), previous: [remote("A")])]
        s.restore(meta)
        s.restore([inboxMsg], boxes: [MailboxKey(account: work.id, mailbox: .inbox)])
        #expect(s.quickCheckRoles(work.id) == [.inbox])
        s.apply(page([remote("A", read: true)], token: "t1"), account: work.id, mailbox: .inbox)
        s.finishLoading([moved])
        #expect(s.messages.filter { $0.remoteID == "A" }.count == 1, "boxes: \(s.messages.filter { $0.remoteID == "A" }.map(\.mailbox.rawValue))")
    }
}
```

## Expected vs actual
Expected: one message with remote ID "A". Actual: `boxes: ["inbox", "archive"]`.

Actual (`swift test --filter Probe_SyncTests`, run 2026-11-12):
```
Test quickCheckDuringLaunchDoesNotDuplicateAMessageMovedOfflineLastSession() recorded an issue at Probe_SyncTests.swift:219:9: Expectation failed: s.messages.filter { $0.remoteID == "A" }.count == 1
    boxes: ["inbox", "archive"]
    s.messages.filter { $0.remoteID == "A" }.count == 1 → false
      s.messages.filter { $0.remoteID == "A" }.count → 2
Test quickCheckDuringLaunchDoesNotDuplicateAMessageMovedOfflineLastSession() failed after 3.760 seconds with 1 issue.
```

## Why expected
- `quickCheckRoles` comment: "While launch is loading, a mailbox not yet in memory isn't checked: merging would duplicate its mail" – the intent is no duplicates during launch; README "Launch: … The Inbox is checked with the server meanwhile. Other mailboxes are synced only once their mail is in memory".
- Offline changes are kept across launches (README: "Offline, changes wait until the next refresh"; outbox stored in the database).

## Likely cause
`Sources/MailModel/MailStore.swift:559-573` (merge appends when the rid isn't in memory, even with a queued change for it) and `:669-671` (`finishLoading` filters `rest` by local `id`, not by remote ID).

## Also seen by
Another probe hunt found the same root cause (`probePendingMoveSurvivesInboxCheckDuringLaunch` in `specs/bugs/probes/`).
