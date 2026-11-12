---
title: Stored mail of an account that is no longer set up is loaded at launch and shows in All Inboxes and search (its rows are never removed)
priority: P4
area: MailStore
status: open
found: 2026-11-12
---
## Summary
Launch filters sync positions, folders and the outbox to the configured accounts (`restore(meta)`), but `finishLoading` takes every other row of the database, including all mail of an account that is no longer in the account list. That mail appears in All Inboxes (and the index search, which searches all accounts), without its account in the sidebar; the next save then deletes its sync rows and folders but keeps the messages. Nothing ever removes an account's rows or index entries.

## Repro
Probe file: `specs/bugs/probes/Probe_DB2Tests.swift` (copy r2db), test `probeMailOfAccountNoLongerSetUpIsNotLoaded()`. Self-contained:

```swift
import Foundation
import SQLite3
import Testing
@testable import MailModel

/// Round 2 probes for MailDatabase and the MailStore save/load path. Real temp files, no mocks.
@MainActor
@Suite(.serialized)
struct Probe_DB2Tests {
    let work = Account(name: "Work", address: "me@work.com")
    let home = Account(name: "Home", address: "me@home.com")

    func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ProbeDB2-\(UUID())/Mail.sqlite")
    }

    func mail(_ subject: String, body: String = "", preview: String? = nil, from: Contact = Contact(name: "Ann", email: "ann@x.com"),
              to: [Contact] = [], account: Account? = nil, box: MailboxKind = .inbox, minutesAgo: Double = 0,
              rid: String? = nil) -> Message {
        Message(accountID: (account ?? work).id, mailbox: box, from: from, to: to, subject: subject, body: body,
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

    /// What `AppSetup.loadMail` does at launch.
    func launch(_ accounts: [Account], from url: URL) throws -> MailStore {
        let d = try MailDatabase(url: url)
        let s = MailStore(accounts: accounts, messages: [])
        let first = accounts.map { MailboxKey(account: $0.id, mailbox: .inbox) }
        s.restore(try d.meta())
        s.restore(try d.messages(in: first), boxes: first)
        s.finishLoading(try d.messages(notIn: first))
        return s
    }

    /// An account that is no longer set up: launch reads its sync positions and folders only for configured
    /// accounts (`restore(meta)` filters), but `finishLoading` takes every other row of the database.
    @Test func probeMailOfAccountNoLongerSetUpIsNotLoaded() throws {
        let url = tempURL(); defer { cleanup(url) }
        let d = try MailDatabase(url: url)
        try d.write(StoreChanges(upserts: [mail("work inbox", rid: "W1"), mail("old home inbox", account: home, rid: "H1"),
                                           mail("old home archive", account: home, box: .archive, rid: "H2")],
                                 sync: [SyncState(account: work.id, mailbox: .inbox, token: "w", complete: true),
                                        SyncState(account: home.id, mailbox: .inbox, token: "h", complete: true)],
                                 folders: [home.id: [Folder(box: .folder("hf"), name: "Home Folder")]]))
        // Next launch: only Work is set up.
        let s = try launch([work], from: url)
        #expect(s.folders[home.id] == nil)              // control: meta is filtered
        #expect(s.syncToken(home.id, .inbox) == nil)     // control
        let foreign = s.messages.filter { $0.accountID == home.id }.map(\.subject)
        #expect(foreign.isEmpty, "mail of a removed account loaded: \(foreign)")
        #expect(s.visibleMessages.map(\.subject) == ["work inbox"], "All Inboxes shows \(s.visibleMessages.map(\.subject))")
    }
}
```

## Expected vs actual
Expected only Work's mail in memory and All Inboxes. Actual: the old Home account's Inbox and Archive mail are loaded and "old home inbox" shows in All Inboxes.

```
Expectation failed: foreign.isEmpty
  mail of a removed account loaded: ["old home inbox", "old home archive"]
Expectation failed: s.visibleMessages.map(\.subject) == ["work inbox"]
  All Inboxes shows ["work inbox", "old home inbox"]
Test probeMailOfAccountNoLongerSetUpIsNotLoaded() failed after 0.018 seconds with 2 issues.
```

## Why expected
`restore(meta)` and `restore(_ c: MailCache)` deliberately keep to the store's accounts (`mine.contains`), so launch is meant to load only configured accounts. All Inboxes is "each account's Inbox" of the accounts in the sidebar. There is no UI to remove an account today (only by editing the saved accounts), hence P4.

## Likely cause
`Sources/MailModel/MailStore.swift:669-672` (`finishLoading`) and :661-664 append rows without checking `accounts`; `MailDatabase.messages(notIn:)` (`MailDatabase.swift:278`) returns every row not in the given boxes, including other accounts'. `MailDatabase.search(accounts: nil)` likewise returns them.
