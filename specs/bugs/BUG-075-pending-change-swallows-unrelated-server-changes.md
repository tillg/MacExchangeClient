---
title: A queued change of one property throws away the server's changes to the other properties of that message (flag, read state)
priority: P3
area: MailStore
status: open
found: 2026-11-12
---
## Summary
While any change for a message is queued, `merge` keeps the local read state, flag and mailbox together and skips its `readChanges`. A queued read change therefore drops a flag set on the phone, a queued flag change drops a read change, and a queued move drops both. Once the queued change is written, the flag is only repaired if the server reports the item again as a full `Update`; ⚠️ (recalled, not checked live) EWS reports a pure read change as `ReadFlagChange`, which carries no flag, so in practice it isn't; the lost read state is not reported again either.

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

    /// A queued read change must not swallow an unrelated flag change from the server.
    @Test func pendingReadChangeKeepsTheServersFlag() {
        let s = synced(["A"])
        let a = id(s, "A")
        s.toggleRead([a])  // queued: setRead true
        s.apply(page([remote("A", flag: .red)], token: "t1"), account: work.id, mailbox: .inbox)
        #expect(s.message(a)?.isRead == true)
        #expect(s.message(a)?.flag != nil, "flagged on the phone, lost here")
    }

    /// A queued flag change must not swallow a read change from the server.
    @Test func pendingFlagChangeKeepsTheServersReadState() {
        let s = synced(["A"])
        let a = id(s, "A")
        s.setFlag(.red, for: [a])
        s.apply(page(reads: ["A": true], token: "t1"), account: work.id, mailbox: .inbox)
        #expect(s.message(a)?.isRead == true, "read on the phone, still unread here")
    }

    /// A pending move must not swallow a read change from the server either.
    @Test func pendingMoveKeepsTheServersReadState() {
        let s = synced(["A"])
        let a = id(s, "A")
        s.archive([a])
        s.apply(page(reads: ["A": true], token: "t1"), account: work.id, mailbox: .inbox)
        #expect(s.message(a)?.mailbox == .archive)
        #expect(s.message(a)?.isRead == true, "read on the phone, still unread here")
    }
}
```

## Expected vs actual
Expected: the server's flag/read state is taken for the properties the queued change doesn't touch. Actual: "flagged on the phone, lost here"; "read on the phone, still unread here" (twice).

Actual (`swift test --filter Probe_SyncTests`, run 2026-11-12):
```
Test pendingFlagChangeKeepsTheServersReadState() recorded an issue at Probe_SyncTests.swift:146:9: Expectation failed: s.message(a)?.isRead == true
    read on the phone, still unread here
    s.message(a)?.isRead == true → false
      s.message(a)?.isRead → false
        some → false
        some → true
Test pendingMoveKeepsTheServersReadState() recorded an issue at Probe_SyncTests.swift:201:9: Expectation failed: s.message(a)?.isRead == true
    read on the phone, still unread here
    s.message(a)?.isRead == true → false
      s.message(a)?.isRead → false
        some → false
        some → true
Test pendingFlagChangeKeepsTheServersReadState() failed after 3.576 seconds with 1 issue.
Test pendingReadChangeKeepsTheServersFlag() recorded an issue at Probe_SyncTests.swift:137:9: Expectation failed: s.message(a)?.flag != nil
    flagged on the phone, lost here
    s.message(a)?.flag != nil → false
      s.message(a)?.flag → nil
Test pendingMoveKeepsTheServersReadState() failed after 3.576 seconds with 1 issue.
Test pendingReadChangeKeepsTheServersFlag() failed after 3.760 seconds with 1 issue.
```

## Why expected
- README: changes are written "in order: read state …, flags, moves" – separate properties; Exchange keeps them separately.
- `merge` doc says messages with a waiting change keep "their local read state, flag and mailbox"; the purpose (test `pendingChangesSurviveASyncThatRacesThem`) is not to undo the user's change, which only needs the changed property kept.
- EWSBackend.parseSync maps `ReadFlagChange` to `readChanges` only (EWSBackend.swift:478), so a flag lost here is not sent again.

## Likely cause
`Sources/MailModel/MailStore.swift:530, 567, 578`: `pending` is a set of remote IDs from any queued change; line 567 restores all three fields and line 578 skips every read change for those IDs. It should be per property (read for `.setRead`, flag for `.setFlagged`, mailbox for `.move`/answers).
