---
title: "Attachment names stored by older versions no longer decode: old Cache.json can never be imported and waiting outbox changes are silently dropped"
priority: P1
area: Models
status: open
found: 2026-11-12
---

## Summary
`Attachment` became a struct (94d679c) with synthesized `Codable`, so JSON written before that — where `attachments` was `["name.pdf"]` — no longer decodes. A `Cache.json` from the pre-SQLite version with any message with attachments fails to load as a whole, so `importCache` throws on every launch (no database, nothing saved, cache never imported). In `Mail.sqlite`, an outbox row from 9f0dcba..94d679c whose `previous` holds such a message is silently dropped by `meta()`, losing a change that was never sent to Exchange.

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

    /// Cache.json as written by the version that moved to SQLite (9f0dcba): attachments were plain names.
    @Test func probeCacheFromBeforeAttachmentSizesStillLoads() async throws {
        let json = #"{"accounts":["00000000-0000-0000-0000-000000000001",{"complete":["inbox"],"messages":[{"accountID":"00000000-0000-0000-0000-000000000001","attachments":["Rechnung.pdf"],"body":"Hallo","bodyLoaded":true,"category":"primary","cc":[],"date":800000000,"from":{"email":"ann@x.com","name":"Ann"},"hasAttachments":true,"id":"00000000-0000-0000-0000-000000000002","isRead":false,"isVIP":false,"mailbox":"inbox","remoteID":"R1","subject":"S","to":[],"htmlChecked":true}],"outbox":[{"account":"00000000-0000-0000-0000-000000000001","change":{"move":{"_0":["R1"],"to":"archive"}},"id":"00000000-0000-0000-0000-000000000003","previous":[]}],"syncTokens":["inbox","T1"]}]}"#
        let dir = tempURL().deletingLastPathComponent(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cacheURL = dir.appendingPathComponent("Cache.json"), dbURL = dir.appendingPathComponent("Mail.sqlite")
        try Data(json.utf8).write(to: cacheURL)
        // Control: the same file without the attachment name decodes.
        try Data(json.replacingOccurrences(of: #"["Rechnung.pdf"]"#, with: "[]").utf8).write(to: cacheURL)
        #expect(MailCache.load(from: cacheURL) != nil)
        try Data(json.utf8).write(to: cacheURL)
        let cache = MailCache.load(from: cacheURL)
        #expect(cache != nil, "Cache.json with attachment names doesn't decode")
        let acct = Account(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "W", address: "w@x.com")
        let s = MailStore(accounts: [acct], messages: [])
        var err: String?
        do { _ = try await MailDatabase.importCache(from: cacheURL, into: dbURL, store: s) } catch { err = error.localizedDescription }
        #expect(err == nil, "import: \(err ?? "")")
        #expect(s.messages.first?.attachments == ["Rechnung.pdf"])
        #expect(s.outbox.count == 1)
    }

    /// An outbox row written to Mail.sqlite before attachments had a size (9f0dcba..94d679c): `previous` holds
    /// the message as it was, with attachment names only.
    @Test func probeOutboxRowFromBeforeAttachmentSizesStillLoads() throws {
        let url = tempURL(); defer { cleanup(url) }
        _ = try MailDatabase(url: url)
        let change = #"{"account":"00000000-0000-0000-0000-000000000001","change":{"move":{"_0":["R1"],"to":"archive"}},"id":"00000000-0000-0000-0000-000000000003","previous":[{"accountID":"00000000-0000-0000-0000-000000000001","attachments":["Vertrag.pdf"],"body":"x","bodyLoaded":true,"category":"primary","cc":[],"date":800000000,"from":{"email":"ann@x.com","name":"Ann"},"hasAttachments":true,"id":"00000000-0000-0000-0000-000000000002","isRead":true,"isVIP":false,"mailbox":"inbox","remoteID":"R1","subject":"S","to":[]}]}"#
        var raw: OpaquePointer?
        #expect(sqlite3_open(url.path, &raw) == SQLITE_OK)
        #expect(sqlite3_exec(raw, "INSERT INTO outbox VALUES(0, CAST('\(change)' AS BLOB))", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(raw)
        let meta = try MailDatabase(url: url).meta()
        #expect(meta.outbox.count == 1, "the waiting move to Archive was dropped")
        // Control: the same row without the attachment name loads.
        let url2 = tempURL(); defer { cleanup(url2) }
        _ = try MailDatabase(url: url2)
        #expect(sqlite3_open(url2.path, &raw) == SQLITE_OK)
        let plain = change.replacingOccurrences(of: #"["Vertrag.pdf"]"#, with: "[]")
        #expect(sqlite3_exec(raw, "INSERT INTO outbox VALUES(0, CAST('\(plain)' AS BLOB))", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(raw)
        #expect(try MailDatabase(url: url2).meta().outbox.count == 1)
    }
}
```

## Expected vs actual
Controls (same JSON with `"attachments":[]`) load fine. With an attachment name:
```
Expectation failed: cache != nil   cache → nil
Expectation failed: err == nil     err → "The old mail cache couldn't be read"
Expectation failed: s.outbox.count == 1   s.outbox.count → 0
Expectation failed: meta.outbox.count == 1   meta.outbox.count → 0
```

## Why expected
The code deliberately supports old formats: `MailDatabase.attachments(_:)` says "Older rows hold names only" (test `attachmentNamesFromOlderRowsStillRead`), `MailCacheTests.cacheFromBeforeFoldersStillLoads` / `cacheWithoutHTMLFieldsStillLoads` keep older caches loading, and `importCache` exists only to migrate old `Cache.json` files. Model comments repeatedly say fields are optional "so caches written before … still load".

## Likely cause
`Sources/MailModel/Models.swift` `struct Attachment: Codable` (synthesized decoder, expects an object) — no `init(from:)` accepting a bare string. Hits `MailCache.load` (`MailCache.swift:27`, `try?` → nil → `MailDatabase.swift:384-386` throws) and `MailDatabase.meta()` (`MailDatabase.swift:265`, `try? decoder.decode(PendingChange…)` drops the row silently).

## Shipped format
`git log` shows `var attachments: [String]` in `Models.swift` from the initial commit up to `b75308d`, and `94d679c` changed it to `[Attachment]`. Caches and outbox rows written by those builds really exist, so this is a regression for users upgrading from them.
