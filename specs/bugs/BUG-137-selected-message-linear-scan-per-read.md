---
title: 'Clicking a message that arrived this session takes 0.43 s: selectedMessage scans all messages on each of its 7 reads per redraw'
priority: P3
area: MailStore
status: open
found: 2026-11-13
---
## Summary
`selectedMessage` finds the message by a linear scan over all messages (`message(_:)`), every time it is read, with no cache. Mail that arrives during the session is appended to the end of `messages`, so the newest Inbox mail (the top rows) costs 0.036 s per read on 180,000 messages in a debug build. One redraw of the main window reads `selectedMessage` 7 times. Clicking an unread message that just arrived therefore takes 0.43 s. The same click on an Inbox message loaded at launch, which sits at the front of the array, takes 0.20 s.

Caveat: this is over budget only because of the 7 reads. One read plus the click is about 0.23 s. The count of 7 comes from the call sites in the view code (listed below); the app was not run to count the reads.

## Repro
Run: `swift test --filter Probe_Perf4Findings/selectingANewlyArrivedMessageStaysInBudget` (file `specs/bugs/probes/Probe_Perf4Tests.swift` in the copy).

```swift
import Foundation
import Testing
@testable import MailModel

/// 180,000 messages over 2 accounts and 300 folders, as the README describes the real database.
/// Debug build. Budget: 0.25 s per user action (MailStorePerformanceTests.limit).
enum Perf4Fixture {
    static let work = Account(name: "Work", address: "me@work.com")
    static let home = Account(name: "Home", address: "me@home.com")
    static let limit = 0.25

    /// Exchange-like long IDs.
    static func exid(_ prefix: String, _ n: Int) -> String {
        "AAMkADk2YjNhZjM0LTQ5ZjEtNDYxMC05ZmQ1LWVlYjE1ZTcwNzhhOQBGAAAAAAB" + prefix + String(n) + String(repeating: "A", count: 60) + "="
    }

    /// 150 folders per account: 30 top-level, each with 4 subfolders.
    static func folders(_ acct: Int) -> [Folder] {
        var out: [Folder] = []
        for t in 0..<30 {
            let top = MailboxKind.folder(exid("F\(acct)T", t))
            out.append(Folder(box: top, name: "Project \(t)"))
            for c in 0..<4 { out.append(Folder(box: .folder(exid("F\(acct)T\(t)C", c)), name: "Sub \(c)", parent: top)) }
        }
        return out
    }

    struct Plan { let acct: Account; let boxes: [(MailboxKind, Int)] }

    static let plans: [Plan] = {
        let fw = folders(0).map(\.box), fh = folders(1).map(\.box)
        // Work: 140,000; Home: 40,000.
        let w: [(MailboxKind, Int)] = [(.inbox, 2_900), (.drafts, 300), (.sent, 54_000), (.trash, 11_800), (.archive, 30_000), (.junk, 400)]
            + fw.map { ($0, 270) }   // 150 * 270 = 40,500  -> 99,400 + 40,500 = 139,900
        let h: [(MailboxKind, Int)] = [(.inbox, 3_000), (.drafts, 100), (.sent, 10_000), (.trash, 5_000), (.archive, 0), (.junk, 900)]
            + fh.map { ($0, 140) }   // 150 * 140 = 21,000 -> 19,000 + 21,000 = 40,000
        return [Plan(acct: work, boxes: w), Plan(acct: home, boxes: h)]
    }()

    /// Inboxes first (launch step 2), then everything else mailbox by mailbox (launch step 3).
    static let base: [Message] = {
        var inbox: [Message] = [], rest: [Message] = []
        inbox.reserveCapacity(6_000); rest.reserveCapacity(175_000)
        var n = 0
        for (ai, p) in plans.enumerated() {
            for (box, count) in p.boxes {
                for _ in 0..<count {
                    n += 1
                    let loaded = n % 10 == 0
                    var m = Message(accountID: p.acct.id, mailbox: box,
                                    from: Contact(name: "Sender \(n % 700)", email: "sender\(n % 700)@example.com"),
                                    to: [Contact(name: "Me", email: p.acct.address)],
                                    subject: "Subject line number \(n)", body: loaded ? String(repeating: "Body text \(n). ", count: 60) : "",
                                    date: Date(timeIntervalSince1970: 1_600_000_000 + Double(n) * 600),  // ascending in array order: the best case for the list sort (real order unverified; `newest` returns descending)
                                    isRead: n % 25 != 0, flag: n % 150 == 0 ? .red : nil, isVIP: n % 90 == 0,
                                    remoteID: exid("M\(ai)", n), serverPreview: "Preview of message \(n)", bodyLoaded: loaded)
                    m.conversationID = "AAQkADk2YjNhZjM0LTQ5ZjEtNDYxMC05ZmQ1LWVlYjE1ZTcwNzhhOQAQ" + String(n / 3)
                    if box == .inbox { inbox.append(m) } else { rest.append(m) }
                }
            }
        }
        return inbox + rest
    }()

    /// A store as the app has it after launch: server accounts with their folder trees.
    @MainActor static func store() -> MailStore {
        let s = MailStore(accounts: [work, home], messages: base.map { $0 })  // own buffer, not shared with `base`
        s.setFolders(folders(0), account: work.id)
        s.setFolders(folders(1), account: home.id)
        for a in [work, home] {
            s.apply(SyncResult(upserts: [], deletedRemoteIDs: [], token: "t", more: false), account: a.id, mailbox: .inbox)
        }
        _ = s.takeChanges()
        return s
    }

    /// Best of three runs, each on a fresh store prepared by `setup`.
    @MainActor static func time(_ label: String, setup: (MailStore) -> Void = { _ in }, _ f: (MailStore) -> Void) -> Double {
        let t = (0..<3).map { _ in
            let s = store()
            setup(s)
            let start = ContinuousClock.now
            f(s)
            let d = start.duration(to: .now)
            return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
        }
        print(String(format: "PERF4 %@: %.3fs (runs %@)", label, t.min()!, t.map { String(format: "%.3f", $0) }.joined(separator: " ")))
        return t.min()!
    }

    /// One redraw of the main window: list, sidebar badges, subtitle, title, detail.
    @MainActor static func redraw(_ s: MailStore) {
        _ = s.visibleMessages
        let refs: [MailboxRef] = [.smart(.allInboxes), .smart(.vip), .smart(.flagged), .smart(.unread)]
        for r in refs { _ = s.unreadCount(r) }
        for a in s.accounts {
            for b in MailboxKind.allCases + (s.folders[a.id] ?? []).map(\.box) { _ = s.unreadCount(.account(a.id, b)) }
        }
        _ = s.title
        _ = s.count(s.selectedMailbox); _ = s.unreadCount(s.selectedMailbox)
        if let m = s.selectedMessage { _ = s.conversation(of: m.id) }
    }
}

/// One test per finding. Each prints its timings; the assertion is the repo's budget (0.25 s per user action).
@MainActor
@Suite(.serialized)
struct Probe_Perf4Findings {
    typealias F = Perf4Fixture
    var w: UUID { F.work.id }
    var inbox: [Message] { F.base.filter { $0.accountID == F.work.id && $0.mailbox == .inbox } }

    /// R4-Perf4-03: clicking a message that arrived during this session (appended at the end of `messages`).
    /// A redraw reads `selectedMessage` 7 times: MailCommands.swift:27, :31, :60, :62, :64, MessageViewer.swift:77,
    /// MessageDetailView.swift:10.
    @Test func selectingANewlyArrivedMessageStaysInBudget() {
        let arrived = Message(accountID: w, from: Contact(name: "New", email: "new@x.com"), to: [], subject: "Just arrived",
                              body: "", date: Date(timeIntervalSince1970: 2_000_000_000), isRead: false, remoteID: "NEW-1",
                              serverPreview: "p", bodyLoaded: false)
        let front = inbox.first { !$0.isRead }!.id
        func arrive(_ s: MailStore) {
            s.apply(SyncResult(upserts: [arrived], deletedRemoteIDs: [], token: "t2", more: false), account: w, mailbox: .inbox)
            s.selectedMailbox = .account(w, .inbox)
            F.redraw(s)
        }
        func click(_ s: MailStore, _ id: Message.ID) {
            s.selection = [id]
            s.markSelectionRead()
            F.redraw(s)                                  // 1 read of selectedMessage
            for _ in 0..<6 { _ = s.selectedMessage }     // the other 6 reads of the same redraw
        }
        let oneRead = F.time("1 read of selectedMessage (new message)", setup: { arrive($0); $0.selection = [arrived.id] }) { s in _ = s.selectedMessage }
        let atFront = F.time("click unread Inbox message loaded at launch", setup: arrive) { s in click(s, front) }
        let newest = F.time("click unread message that arrived this session", setup: arrive) { s in
            let id = s.visibleMessages.first!.id          // top row of the Inbox
            click(s, id)
        }
        print(String(format: "PERF4 R4-Perf4-03 one read %.3fs, click front %.3fs, click newest %.3fs", oneRead, atFront, newest))
        #expect(newest < F.limit)
    }
}
```

## Expected vs actual
Expected: under 0.25 s, the same as clicking a message loaded at launch. Actual (best of 3, stable 0.434–0.443 s):
```
PERF4 1 read of selectedMessage (new message): 0.036s (runs 0.036 0.037 0.037)
PERF4 click unread Inbox message loaded at launch: 0.195s (runs 0.197 0.195 0.199)
PERF4 click unread message that arrived this session: 0.434s (runs 0.434 0.441 0.443)
Expectation failed: newest < F.limit
```

## Why expected
`MailStorePerformanceTests.limit` = 0.25 s per user action. Clicking new mail is the most common action, and position in memory shouldn't matter. The store already caches the list, the counts and the conversation per revision; `selectedMessage` is the one per-redraw read that isn't cached.

## Likely cause
`Sources/MailModel/MailStore.swift:101` `message(_:)` = `messages.first { $0.id == id }`, called from `selectedMessage` (:350) on every read.
- The reads per redraw are at `Sources/MailReplica/MailCommands.swift:27, 31, 60, 62, 64` (`.disabled(store.selectedMessage …)`), `MessageViewer.swift:77` and `MessageDetailView.swift:10`.
- New mail is appended by `merge` (`ms.append(m)`, :670), so the newest mail sits at the far end of the scan.

Possible fixes: cache `selectedMessage` per (revision, selection), or keep an id→index map per revision. The same scan also runs in `loadBody`, `setBody` and `answer` (`message(id)` / `firstIndex`).

Not BUG-078, which is the `firstIndex` loop in `failed()`.
