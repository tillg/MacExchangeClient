---
title: 'Search without the index (index build failed or still building, or "Search failed") freezes 0.6-1 s per keystroke on 180,000 messages'
priority: P4
area: MailStore
status: deferred
found: 2026-11-13
---
## Summary
When `searcher` is nil, or the index failed for the current query, `visibleMessages` searches by scanning memory. On every keystroke it folds (case and diacritics) the joined subject, sender, To, Cc, preview and body of every message, synchronously on the main actor, with no debounce. With all 180,000 messages in memory, typing "invoice" costs 0.57-0.97 s per letter (debug build), about 4.5 s for the word.

When this applies with all mail in memory:
- **The index build failed** ("Couldn't build the search index"): search scans memory for the whole session.
- **The first launch after the update** that adds the index: `prepareSearch` builds it after `finishLoading` (about 1.3 s for 180,000 per the README).
- **A query the index throws on** (`fallbackQuery`, "Search failed").

On a normal launch it doesn't apply. Before `finishLoading`, only the Inboxes (about 6,000 messages) are in memory. After it, `prepareSearch` on an existing index returns at once (a `user_version` check), so the window is very short. Hence P4.

## Repro
Run: `swift test --filter Probe_Perf4Findings/memorySearchKeystrokeStaysInBudget` (file `specs/bugs/probes/Probe_Perf4Tests.swift` in the copy).

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

    /// R4-Perf4-04: typing in the search field before the index is ready (each launch until it is), or after
    /// "Search failed": memory is scanned on every keystroke.
    @Test func memorySearchKeystrokeStaysInBudget() {
        var times: [Double] = []
        for q in ["i", "in", "inv", "invo", "invoice"] {
            times.append(F.time("memory search keystroke '\(q)'", setup: { $0.selectedMailbox = .smart(.allInboxes); F.redraw($0) }) { s in
                s.searchText = q; _ = s.visibleMessages
            })
        }
        print("PERF4 R4-Perf4-04 per keystroke", times.map { String(format: "%.3f", $0) })
        #expect(times.last! < F.limit)
    }

}
```

## Expected vs actual
Expected: each keystroke under 0.25 s. Actual (best of 3 each, stable):
```
PERF4 memory search keystroke 'i': 0.572s (runs 0.572 0.573 0.574)
PERF4 memory search keystroke 'in': 0.566s (runs 0.606 0.622 0.566)
PERF4 memory search keystroke 'inv': 0.967s (runs 0.976 0.969 0.967)
PERF4 memory search keystroke 'invo': 0.973s (runs 0.978 0.973 1.002)
PERF4 memory search keystroke 'invoice': 0.963s (runs 0.971 0.968 0.963)
Expectation failed: times.last! < F.limit
```

## Why expected
`MailStorePerformanceTests.limit` = 0.25 s per user action. `MailStore.searcher` (:32-33) and `AccountsSettings.loadMail` say that until the index is ready, search scans memory. The index path is debounced (`searchDebounce` 150 ms) and runs off the main actor (`runSearch`). The memory path has neither.

## Likely cause
`Sources/MailModel/MailStore.swift:218-232` (`visibleMessages`) calls `matches()` (:266-271) for every message on every keystroke. `matches()` builds an array of up to ~10 strings, joins them (including the whole body) and runs `String.folding(options: [.caseInsensitive, .diacriticInsensitive])` over the result. That is about 180,000 joins and folds per keystroke.

The full-field fold came with the BUG-052 fix (commit a213327, which added `fold`, `searchWords` and the joined-fields `matches`).

Possible fixes: fold once per message per revision (a cached folded text), or run the memory scan detached and debounced like the index path.

## Deferred
2026-11-13. The probe times each keystroke on a fresh store of 180,000 messages, so most likely only a memory search that leaves the main actor (debounced and detached, like the index path) can stay under 0.25 s with the 10× margin the test rules ask for: a cold scan that folds every message once is ≥ 0.5 s, and a cached folded text per message doubles the memory of all loaded bodies. Making the memory path asynchronous changes the contract that existing tests pin: they read `visibleMessages` right after setting `searchText` (without an index) and expect the results at once (`searchTypedBeforeTheIndexIsReady`, `aFailedIndexSearchFallsBackToMemory`, `memorySearchStaysFastAt70kMessages` and the search tests in `MailStoreTests`). Changing those needs the user's decision. Not measured: a synchronous scan split across the cores, as `hitList` does. See DECISIONS.md {#d-bug-146}.
