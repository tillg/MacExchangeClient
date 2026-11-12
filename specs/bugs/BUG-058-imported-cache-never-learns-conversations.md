---
title: Mail imported from Cache.json keeps the cache's sync positions, so it never learns its conversation
priority: P3
area: MailDatabase
status: open
found: 2026-11-12
---
## Summary
Every Cache.json predates conversations, so its messages have no `conversationID`. The upgrade of an older database resets all sync positions so existing mail learns its conversation, but `importCache` builds a new database (which already has the column), writes the cache's tokens and complete flags unchanged, and the folders only fetch changes from then on. Imported messages never get a conversation: opening one shows it alone, without its replies.

## Repro
Probe file: `specs/bugs/probes/Probe_DB2Tests.swift` (copy r2db), test `probeImportedCacheSyncsAgainToLearnConversations()`. Self-contained:

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

    /// Every Cache.json comes from before conversations (it predates the database). README: "A database from
    /// before conversations syncs every folder once more from the start so existing mail learns its
    /// conversation." The import keeps the cache's sync positions, so imported mail never learns it.
    @Test func probeImportedCacheSyncsAgainToLearnConversations() async throws {
        let dir = tempURL().deletingLastPathComponent(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cacheURL = dir.appendingPathComponent("Cache.json"), dbURL = dir.appendingPathComponent("Mail.sqlite")
        let old = MailStore(accounts: [work], messages: [])
        old.apply(SyncResult(upserts: [mail("A", rid: "A"), mail("B", rid: "B")], deletedRemoteIDs: [], token: "T-old", more: false),
                  account: work.id, mailbox: .inbox)
        #expect(old.messages.allSatisfy { $0.conversationID == nil })
        try old.cache().save(to: cacheURL)
        let s = MailStore(accounts: [work], messages: [])
        let d = try #require(try await MailDatabase.importCache(from: cacheURL, into: dbURL, store: s))
        // Control: a database from before conversations starts over.
        #expect(s.messages.count == 2)
        #expect(s.syncToken(work.id, .inbox) == nil && !s.isComplete(work.id, .inbox),
                "imported store: token \(s.syncToken(work.id, .inbox) ?? "nil"), complete \(s.isComplete(work.id, .inbox))")
        let stored = try d.meta().sync
        #expect(stored.allSatisfy { $0.token == nil && !$0.complete }, "stored sync: \(stored)")
    }
}
```

## Expected vs actual
Expected the imported Inbox to start over (token nil, not complete), as an older database does. Actual: token "T-old", complete, both in memory and in the new database.

```
Expectation failed: s.syncToken(work.id, .inbox) == nil && !s.isComplete(work.id, .inbox)
  imported store: token T-old, complete true
Expectation failed: stored.allSatisfy { $0.token == nil && !$0.complete }
  stored sync: [MailModel.SyncState(account: …, mailbox: MailModel.MailboxKind(rawValue: "inbox"), token: Optional("T-old"), complete: true)]
Test probeImportedCacheSyncsAgainToLearnConversations() failed after 0.032 seconds with 2 issues.
```

## Why expected
README (Conversations): "A database from before conversations syncs every folder once more from the start so existing mail learns its conversation." The JSON cache is the oldest storage of all; existing test `anOlderDatabaseGetsConversationsAndSyncsAgain` shows the intended reset.

## Likely cause
`Sources/MailModel/MailDatabase.swift:381-415` (`importCache`) writes `store.storedState()` with the cache's sync states; the reset in `init` (:120-127) runs only when the `conversation` column is missing, which a newly created database never is. `MailStore.restore(_ c: MailCache)` (MailStore.swift:700) also keeps the tokens.
