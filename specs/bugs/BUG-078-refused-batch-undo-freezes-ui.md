---
title: Undoing a refused batch of 100 changes takes about 1 s on a 70k-message account (main thread)
priority: P3
area: MailStore
status: open
found: 2026-11-12
---
## Summary
`failed` looks up every message of the refused batch with a linear `firstIndex` over all messages and mutates them one by one; with a 70,000-message account one refused batch of 100 (the outbox batch size) blocks the main actor for ~1 s when the batch's messages sit near the end of the message array (as measured; messages near the start cost less, since `firstIndex` stops early). Each further refused batch adds the same again.

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

    /// The 70k account of MailStorePerformanceTests, limit 0.25 s (its budget).
    func big(_ n: Int = 70_000) -> MailStore {
        var ms: [Message] = []
        ms.reserveCapacity(n)
        for i in 0..<n {
            ms.append(Message(accountID: work.id, mailbox: i < 3000 ? .inbox : .sent, from: Contact(name: "S", email: "s@x.com"),
                              to: [], subject: "Subject \(i)", body: "", date: Date(timeIntervalSince1970: Double(i * 60)),
                              isRead: true, remoteID: "R\(i)", serverPreview: "Preview \(i)", bodyLoaded: false))
        }
        let s = store(ms)
        s.apply(page(token: "t"), account: work.id, mailbox: .inbox)
        return s
    }

    @Test func refusedBatchOf100IsUndoneQuicklyOnABigAccount() {
        let t = (0..<3).map { _ in
            let s = big()
            s.markAllRead(in: .account(work.id, .inbox))  // already read: nothing
            s.archive(Set(s.messages.suffix(100).map(\.id)))
            let p = s.outbox[0]
            let start = Date()
            s.failed(p, "refused")
            return Date().timeIntervalSince(start)
        }.min()!
        print("PERF failed() 100 in 70k: \(Int(t * 1000)) ms")
        #expect(t < 0.25, "\(Int(t * 1000)) ms")
    }
}
```

## Expected vs actual
Expected: under the repo's 0.25 s budget for a 70k account. Actual: 1025 ms (test run alone, best of three, debug build – the build `run.sh` ships).

Actual (`swift test --filter Probe_SyncTests`, run 2026-11-12):
```
Test refusedBatchOf100IsUndoneQuicklyOnABigAccount() recorded an issue at Probe_SyncTests.swift:401:9: Expectation failed: t < 0.25
    993 ms
    t < 0.25 → false
      t → 0.993677020072937
Test refusedBatchOf100IsUndoneQuicklyOnABigAccount() failed after 3.576 seconds with 1 issue.
```

## Why expected
- `MailStorePerformanceTests.limit = 0.25` for the same 70k account ("must stay well under a frame budget"); `merge` and `hitList` are explicitly written to avoid per-message passes over 180,000 messages (comments at MailStore.swift:197, 539).
- For comparison (same probe file): `renameRemote` of 100 takes 18 ms, `setBody` 5 ms.

## Likely cause
`Sources/MailModel/MailStore.swift:739-748` (`failed`): `messages.firstIndex(where: { $0.id == old.id })` inside the loop over `p.previous` = O(batch × messages), plus four separate writes to the observed `messages` array per message. Build an index once.
