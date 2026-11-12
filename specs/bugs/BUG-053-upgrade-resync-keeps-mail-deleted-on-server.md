---
title: The from-scratch re-sync after the conversation upgrade never removes mail deleted or moved on the server since the last session (ghost messages forever)
priority: P2
area: MailDatabase
status: open
found: 2026-11-12
---
## Summary
Opening a database from before conversations sets every sync token to NULL and complete to 0, so each folder syncs again from the start. A sync from scratch only lists what is on the server now; it never reports deletions. Mail that was deleted or moved elsewhere (phone, OWA) since the last session would have been reported by the old token, but now stays in its folder for good, even after the folder's re-sync completes. Moved mail shows twice (old ghost + new copy).

## Repro
Probe file: `specs/bugs/probes/Probe_DB2Tests.swift` (copy r2db), test `probeUpgradeResyncDropsMailDeletedOnTheServer()`. Self-contained:

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

    /// After the conversation upgrade every folder syncs from the start. A from-scratch sync lists what is on
    /// the server now and never reports deletions, so mail deleted elsewhere since the last session stays.
    @Test func probeUpgradeResyncDropsMailDeletedOnTheServer() throws {
        let url = tempURL(); defer { cleanup(url) }
        let s0 = MailStore(accounts: [work], messages: [])
        s0.apply(SyncResult(upserts: [mail("still there", rid: "R1"), mail("deleted on phone", rid: "R2")], deletedRemoteIDs: [],
                            token: "T1", more: false), account: work.id, mailbox: .inbox)
        try MailDatabase(url: url).write(s0.takeChanges())
        var raw: OpaquePointer?
        #expect(sqlite3_open(url.path, &raw) == SQLITE_OK)
        #expect(sqlite3_exec(raw, "ALTER TABLE messages DROP COLUMN conversation", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(raw)
        // Upgrade launch: sync positions are reset.
        let s = try launch([work], from: url)
        #expect(s.syncToken(work.id, .inbox) == nil)
        // The from-scratch sync of the Inbox, complete in one page: R2 was deleted on the phone meanwhile.
        var r1 = mail("still there", rid: "R1"); r1.conversationID = "C1"
        s.apply(SyncResult(upserts: [r1], deletedRemoteIDs: [], token: "T2", more: false), account: work.id, mailbox: .inbox)
        #expect(s.isComplete(work.id, .inbox))
        let inbox = s.messages.filter { $0.mailbox == .inbox }.map(\.subject)
        #expect(inbox == ["still there"], "Inbox after the complete re-sync: \(inbox)")
    }
}
```

## Expected vs actual
Expected the Inbox to hold only what the completed re-sync returned. Actual: the deleted message stays.

```
Test probeUpgradeResyncDropsMailDeletedOnTheServer() recorded an issue at Probe_DB2Tests.swift: Expectation failed: inbox == ["still there"]
  Inbox after the complete re-sync: ["still there", "deleted on phone"]
Test probeUpgradeResyncDropsMailDeletedOnTheServer() failed after 0.016 seconds with 1 issue.
```

## Why expected
README: "A database from before conversations syncs every folder once more from the start so existing mail learns its conversation; local IDs, bodies and flag colours are kept" – the re-sync is meant to refresh, not to freeze deletions out. Before the upgrade the incremental token would have removed the message; acting on a ghost later fails on the server ("Exchange refused a change").

## Likely cause
`Sources/MailModel/MailDatabase.swift:122-127` resets the tokens; `MailStore.apply`/`merge` (`MailStore.swift:483-488, 525-581`) only ever remove messages listed in `deletedRemoteIDs`. Nothing removes local messages of a folder that a sync started from nil (token == nil) didn't return once it completes (`more == false`).
