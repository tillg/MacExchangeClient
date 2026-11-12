---
title: "Indexed search: Trash/Junk hits fill the 2,000-result cap, hiding real matches and showing 'Showing the newest 2,000 results' over an empty list"
priority: P2
area: MailStore
status: open
found: 2026-11-12
---

## Summary
`MailDatabase.search` applies `LIMIT 2000` before Trash/Junk are filtered out in `MailStore.hitList`. When the newest 2,000 matches of a word are in Trash or Junk (common for newsletters/notifications that get deleted), older matches in Inbox/Archive are never returned: the list is empty (or short) while the status bar claims "Showing the newest 2,000 results".

## Repro
```swift
import Foundation
import SQLite3
import Testing
@testable import MailModel

/// Probes for MailDatabase / MailCache / MailStore save-load. Real temp files, no mocks.
@MainActor
@Suite(.serialized)
struct Probe_DatabaseTests {
    let work = Account(name: "Work", address: "me@work.com")
    let home = Account(name: "Home", address: "me@home.com")

    func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ProbeDB-\(UUID())/Mail.sqlite")
    }

    func mail(_ subject: String, body: String = "", preview: String? = nil, from: Contact = Contact(name: "Ann", email: "ann@x.com"),
              to: [Contact] = [], account: Account? = nil, minutesAgo: Double = 0, rid: String? = nil) -> Message {
        Message(accountID: (account ?? work).id, from: from, to: to, subject: subject, body: body,
                date: Date(timeIntervalSinceReferenceDate: 800_000_000 - minutesAgo * 60), remoteID: rid ?? UUID().uuidString,
                serverPreview: preview, bodyLoaded: !body.isEmpty)
    }

    func db(_ msgs: [Message]) throws -> (MailDatabase, URL) {
        let url = tempURL()
        let db = try MailDatabase(url: url)
        if !msgs.isEmpty { try db.write(StoreChanges(upserts: msgs)) }
        return (db, url)
    }

    func cleanup(_ url: URL) { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    /// The newest 2,000 hits are cut in SQL before Trash/Junk is dropped in memory.
    @Test func probeTrashHitsCrowdOutRealResults() async throws {
        var msgs: [Message] = []
        for i in 0..<2100 { var m = mail("Rechnung trash \(i)", minutesAgo: Double(i)); m.mailbox = .trash; msgs.append(m) }
        for i in 0..<10 { msgs.append(mail("Rechnung inbox \(i)", minutesAgo: Double(10_000 + i))) }
        let (d, url) = try db(msgs); defer { cleanup(url) }
        let s = MailStore(accounts: [work], messages: msgs)
        s.searchDebounce = .zero
        s.searcher = { q, a in try d.search(q, accounts: a) }
        s.searchText = "rechnung"
        await s.searchTask?.value
        #expect(s.visibleMessages.count == 10)
        #expect(s.status != MailStore.limitNotice || s.visibleMessages.count >= MailDatabase.searchLimit,
                "status says \(s.status ?? "") over \(s.visibleMessages.count) results")
    }

    /// Control for the above: with fewer Trash hits than the limit, the Inbox hits show.
    @Test func probeTrashHitsBelowLimitControl() async throws {
        var msgs: [Message] = []
        for i in 0..<1900 { var m = mail("Rechnung trash \(i)", minutesAgo: Double(i)); m.mailbox = .trash; msgs.append(m) }
        for i in 0..<10 { msgs.append(mail("Rechnung inbox \(i)", minutesAgo: Double(10_000 + i))) }
        let (d, url) = try db(msgs); defer { cleanup(url) }
        let s = MailStore(accounts: [work], messages: msgs)
        s.searchDebounce = .zero
        s.searcher = { q, a in try d.search(q, accounts: a) }
        s.searchText = "rechnung"
        await s.searchTask?.value
        #expect(s.visibleMessages.count == 10)
    }
}
```

## Expected vs actual
Control with 1,900 Trash hits: 10 Inbox results shown (passes). With 2,100 Trash hits:
```
Expectation failed: s.visibleMessages.count == 10   s.visibleMessages.count → 0
Expectation failed: s.status != MailStore.limitNotice || s.visibleMessages.count >= MailDatabase.searchLimit
  s.status != MailStore.limitNotice → false
```

## Why expected
specs/change/fast-search.md, Goal: "The behaviour users see stays the same, apart from the deliberate matching changes listed under 'Matching semantics'." The in-memory path (and the same store without a searcher) shows all 10 Inbox matches; result loss from the cap is not one of the listed changes. The cap notice is meant to say the list holds 2,000 results.

## Likely cause
`Sources/MailModel/MailDatabase.swift:211-214` (`ORDER BY m.date DESC LIMIT …` with no mailbox filter) combined with `MailStore.swift:204-206` (`hitList` drops `.trash`/`.junk` after the cap) and `MailStore.swift:269` (notice keyed on `ids.count`, not on what is shown). Spec §3 chose "no Trash/Junk filtering in SQL" for staleness, but nothing compensates (e.g. excluding Trash/Junk in SQL and re-checking in memory, or fetching more).
