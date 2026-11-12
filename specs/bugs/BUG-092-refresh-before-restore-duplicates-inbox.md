---
title: A refresh that runs before launch has restored the stored Inbox duplicates Inbox messages
priority: P4
area: MailStore
status: open
found: 2026-11-12
---
## Summary
`SidebarView` refreshes on every mailbox selection, also before launch has read the stored Inbox (the window is short: from window open until `restore(_:boxes:)`, README: ~0.1 s for the Inbox plus opening the database). If the newest-50 answer of such a refresh is merged before the restore (the store knows no sync positions yet, so it asks for the newest 50), those messages get new local IDs, and `restore(_:boxes:)` then adds the stored copies again because it dedups by local ID only. (A refresh whose answer arrives after the restore is deduplicated by remote ID. `restore(meta)` also puts back the older stored sync tokens; that only re-fetches changes, which apply idempotently, so it is not counted as harm here.)

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

    /// A refresh that runs before launch has restored the database (the user clicks a mailbox while
    /// "Loading Mail…"; SidebarView refreshes on every selection change) merges the newest Inbox mail under new
    /// local IDs; restoring the stored Inbox then adds the same server messages again, and the stored
    /// (older) sync position replaces the one just fetched.
    @Test func refreshBeforeLaunchRestoreDoesNotDuplicateTheInbox() {
        let s = store()
        // Stored last session:
        var stored = remote("A"); stored.accountID = work.id
        var meta = StoredMeta()
        meta.sync = [SyncState(account: work.id, mailbox: .sent, token: "old", complete: true)]
        // Early refresh: Inbox not complete in memory yet → newest 50 merged; Sent delta moved on to "new".
        s.merge([remote("A"), remote("B")], account: work.id, mailbox: .inbox)
        s.apply(page(token: "new"), account: work.id, mailbox: .sent)
        // Then launch restores the database.
        s.restore(meta)
        s.restore([stored], boxes: [MailboxKey(account: work.id, mailbox: .inbox)])
        s.finishLoading([])
        #expect(s.messages.filter { $0.remoteID == "A" }.count == 1, "Inbox shows A \(s.messages.filter { $0.remoteID == "A" }.count) times")
        #expect(s.syncToken(work.id, .sent) == "new")
    }
}
```

## Expected vs actual
Expected: one message per remote ID. Actual: "Inbox shows A 2 times". (The second issue in the output, the Sent token back at "old", is the harmless token rollback mentioned above.)

Actual (`swift test --filter Probe_SyncTests`, run 2026-11-12):
```
Test refreshBeforeLaunchRestoreDoesNotDuplicateTheInbox() recorded an issue at Probe_SyncTests.swift:339:9: Expectation failed: s.messages.filter { $0.remoteID == "A" }.count == 1
    Inbox shows A 2 times
    s.messages.filter { $0.remoteID == "A" }.count == 1 → false
      s.messages.filter { $0.remoteID == "A" }.count → 2
Test refreshBeforeLaunchRestoreDoesNotDuplicateTheInbox() recorded an issue at Probe_SyncTests.swift:340:9: Expectation failed: s.syncToken(work.id, .sent) == "new"
    s.syncToken(work.id, .sent) == "new" → false
      s.syncToken(work.id, .sent) → "old"
        some → "old"
        some → "new"
Test refreshBeforeLaunchRestoreDoesNotDuplicateTheInbox() failed after 3.760 seconds with 2 issues.
```

## Why expected
- README "Launch": the stored Inboxes show first and are then checked; mail shouldn't be duplicated. `MailReplicaApp.pollForMail` explicitly loads before the first check ("before the first check, so it only fetches what changed"), but `SidebarView.onChange(of: store.selectedMailbox) { await store.refresh() }` is not gated on loading.

## Likely cause
`Sources/MailModel/MailStore.swift:643-665`: `restore(_:boxes:)` dedups by local ID (:662-663) instead of remote ID; `restore(meta)` assigns stored tokens unconditionally (:646). `refresh()` (:1037) and `startHistory()` (:1104) run before `restore(meta)` because `loadedBoxes` is still nil then.
