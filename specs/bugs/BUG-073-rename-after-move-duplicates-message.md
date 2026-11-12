---
title: A moved message appears twice when the destination sync brings its new ID before the move's answer renames it
priority: P3
area: MailStore
status: open
found: 2026-11-12
---
## Summary
While a move is in flight (`perform` awaits `backend.move`), the history or a quick check of the destination can already merge the moved item under its new ID as a new message. When the move returns, `renameRemote` gives the original message the same new ID, so two messages share the remote ID: the Archive shows the mail twice, and from then on `merge` only updates one of them (index keeps the last), so the other is a stale duplicate forever (also stored in the database).

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

    /// While a move is on its way, the destination's sync can already list the moved copy under its new ID;
    /// when the move's answer then renames the message, there must be one message, not two.
    @Test func renameOntoAnIDTheSyncAlreadyBroughtDoesNotDuplicate() {
        let s = synced(["A"])
        let a = id(s, "A")
        s.archive([a])
        s.apply(page([remote("A2")], token: "a1"), account: work.id, mailbox: .archive)
        s.renameRemote(["A": "A2"], account: work.id)
        #expect(s.messages.filter { $0.remoteID == "A2" }.count == 1)
        #expect(s.count(.account(work.id, .archive)) == 1)
    }
}
```

## Expected vs actual
Expected: one message with remote ID "A2", Archive count 1. Actual: two messages with "A2", Archive count 2.

Actual (`swift test --filter Probe_SyncTests`, run 2026-11-12):
```
Test renameOntoAnIDTheSyncAlreadyBroughtDoesNotDuplicate() recorded an issue at Probe_SyncTests.swift:102:9: Expectation failed: s.messages.filter { $0.remoteID == "A2" }.count == 1
    s.messages.filter { $0.remoteID == "A2" }.count == 1 → false
      s.messages.filter { $0.remoteID == "A2" }.count → 2
Test renameOntoAnIDTheSyncAlreadyBroughtDoesNotDuplicate() recorded an issue at Probe_SyncTests.swift:103:9: Expectation failed: s.count(.account(work.id, .archive)) == 1
    s.count(.account(work.id, .archive)) == 1 → false
      s.count(.account(work.id, .archive)) → 2
Test renameOntoAnIDTheSyncAlreadyBroughtDoesNotDuplicate() failed after 3.760 seconds with 2 issues.
```

## Why expected
- Existing test `movedMessagesTakeTheirNewServerIDs` and `pendingChangesSurviveASyncThatRacesThem` ("The move went through and the inbox sync reports B gone before the new ID arrived") show the move/sync race is a designed-for state.
- One server item must be one message; the merge index assumes remote IDs are unique per account.

## Likely cause
`Sources/MailModel/MailStore.swift:717-722` (`renameRemote`) sets `remoteID = new` without checking whether a message with `new` already exists in the account (it should merge into / drop that one, keeping the local ID, body and selection).

## Also seen by
Another probe hunt found the same root cause (`probeMoveAnswerAfterTargetSyncLeavesOneMessage` in `specs/bugs/probes/`).
