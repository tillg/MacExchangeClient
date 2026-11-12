---
title: Import from Cache.json reports failure after the database is already in place when Cache.json.imported exists; the session then saves nothing
priority: P4
area: MailDatabase
status: open
found: 2026-11-12
---
## Summary
`importCache` builds the database, moves it to Mail.sqlite, and only then renames Cache.json to Cache.json.imported. If that name is taken (the user followed "To go back" by copying the file back instead of renaming it), the rename throws: the import is reported as failed although Mail.sqlite is complete and in place, `loadMail` shows "Couldn't load mail from disk … Changes aren't saved until relaunch" and nothing is saved in this session. Cache.json is left behind for good.

## Repro
Probe file: `specs/bugs/probes/Probe_DB2Tests.swift` (copy r2db), test `probeImportWhenAnImportedCacheIsAlreadyThere()`. Self-contained:

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

    /// README "To go back": delete Mail.sqlite* and rename Cache.json.imported to Cache.json. A user who copies
    /// it back instead (keeping the .imported file) upgrades again: the database is built and put in place, then
    /// renaming the cache fails, the import reports an error and the session runs without saving.
    @Test func probeImportWhenAnImportedCacheIsAlreadyThere() async throws {
        let dir = tempURL().deletingLastPathComponent(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cacheURL = dir.appendingPathComponent("Cache.json"), dbURL = dir.appendingPathComponent("Mail.sqlite")
        let old = MailStore(accounts: [work], messages: [])
        old.apply(SyncResult(upserts: [mail("A", rid: "A")], deletedRemoteIDs: [], token: "t", more: false), account: work.id, mailbox: .inbox)
        try old.cache().save(to: cacheURL)
        try FileManager.default.copyItem(at: cacheURL, to: cacheURL.appendingPathExtension("imported"))
        let s = MailStore(accounts: [work], messages: [])
        var err: String?
        do { _ = try await MailDatabase.importCache(from: cacheURL, into: dbURL, store: s) } catch { err = error.localizedDescription }
        #expect(err == nil, "import: \(err ?? "")")
        #expect(FileManager.default.fileExists(atPath: dbURL.path) == (err == nil), "database in place although the import failed")
    }
}
```

## Expected vs actual
Expected the import to succeed (the database is complete) or to leave no database behind. Actual: error thrown with the database in place.

```
Expectation failed: err == nil
  import: “Cache.json” couldn’t be moved to “ProbeDB2-…” because an item with the same name already exists.
Expectation failed: FileManager.default.fileExists(atPath: dbURL.path) == (err == nil)
  database in place although the import failed
Test probeImportWhenAnImportedCacheIsAlreadyThere() failed after 0.021 seconds with 2 issues.
```

## Why expected
README (Upgrading): "The database is built under a temporary name and gets its real name only once the count matches … Afterwards the old file is renamed to Cache.json.imported" and "To go back, delete Mail.sqlite* and rename Cache.json.imported to Cache.json". The import's own doc: "only then gives the database its name and renames the cache" – a failure after the database has its name shouldn't turn the whole launch into a no-save session.

## Likely cause
`Sources/MailModel/MailDatabase.swift:414`: `moveItem(at: cacheURL, to: …imported)` throws when the target exists; it runs after the database was moved into place (:406) and the error propagates to `AppSetup.loadMail` → `failedToLoad` (database = nil).
