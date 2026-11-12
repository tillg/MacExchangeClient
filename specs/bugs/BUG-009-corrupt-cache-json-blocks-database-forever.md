---
title: "An unreadable Cache.json blocks creating Mail.sqlite on every launch; nothing is ever saved again"
priority: P3
area: MailDatabase
status: open
found: 2026-11-12
---

## Summary
When `Mail.sqlite` doesn't exist and `Cache.json` exists but can't be decoded (truncated write, disk error, or bug 01), `importCache` throws without creating a database or moving the cache aside. `AppSetup.loadMail` then runs without a database ("Changes aren't saved until relaunch"), and every relaunch hits the same error — the app never persists anything again until the user finds and deletes the file by hand.

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

    @Test func probeCorruptCacheJSONDoesNotBlockTheDatabaseForever() async throws {
        let dir = tempURL().deletingLastPathComponent(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cacheURL = dir.appendingPathComponent("Cache.json"), dbURL = dir.appendingPathComponent("Mail.sqlite")
        try Data("{\"accounts\": [ truncated".utf8).write(to: cacheURL)
        // Launch after launch, as AppSetup.loadMail does: import while there is no database.
        var errors: [String] = []
        for _ in 0..<3 where !FileManager.default.fileExists(atPath: dbURL.path) {
            let s = MailStore(accounts: [work], messages: [])
            do { _ = try await MailDatabase.importCache(from: cacheURL, into: dbURL, store: s) } catch { errors.append(error.localizedDescription) }
        }
        #expect(FileManager.default.fileExists(atPath: dbURL.path), "after 3 launches: \(errors)")
    }
}
```

## Expected vs actual
Expected: after a failed import of an unreadable cache, a later launch gets a database (cache set aside, e.g. renamed, mail re-synced from Exchange). Actual, after 3 launches:
```
Expectation failed: FileManager.default.fileExists(atPath: dbURL.path)   → false
(each attempt: "The old mail cache couldn't be read")
```

## Why expected
The app's own message promises recovery: `AccountsSettings.swift` `failedToLoad` → "Changes aren't saved until relaunch." The import doc says "Interrupted at any point, the next launch imports again" — but here the next launch can never succeed. Everything in the cache is re-fetchable from the server, so refusing to start the database protects nothing.

## Likely cause
`Sources/MailModel/MailDatabase.swift:384-386` throws on `MailCache.load == nil` and leaves `Cache.json` in place; `Sources/MailReplica/AccountsSettings.swift:24-31` retries the import on every launch because `Mail.sqlite` still doesn't exist.
