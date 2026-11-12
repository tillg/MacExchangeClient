---
title: "Text with a NUL character is cut off when stored, and a search containing NUL throws"
priority: P4
area: MailDatabase
status: open
found: 2026-11-12
---

## Summary
Strings are bound with `sqlite3_bind_text(…, -1, …)` and read with `String(cString:)`, both of which stop at U+0000. A subject/body with a NUL is silently truncated on disk; a search query with a NUL is cut inside its quoted phrase and FTS5 fails with "unterminated string" (store shows "Search failed…").

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

    @Test func probeNulCharacterInSubjectAndBodySurvives() throws {
        let m = mail("before\u{0}after", body: "line one\u{0}line two")
        let (d, url) = try db([m]); defer { cleanup(url) }
        _ = d
        let back = try MailDatabase(url: url).messages()
        #expect(back.first?.subject.debugDescription == m.subject.debugDescription)
        #expect(back.first?.body.debugDescription == m.body.debugDescription)
    }

    @Test func probeNulCharacterInSearchNeverThrows() throws {
        let (d, url) = try db([mail("hello")]); defer { cleanup(url) }
        #expect(throws: Never.self) { _ = try d.search("hel\u{0}\"lo", accounts: nil) }
    }
}
```

## Expected vs actual
```
back.first?.subject.debugDescription → "\"before\""      m.subject → "\"before\\0after\""
back.first?.body.debugDescription → "\"line one\""      m.body → "\"line one\\0line two\""
an error was thrown when none was expected: "Mail database: unterminated string"
```

## Why expected
`everyFieldOfAMessageSurvives` sets the contract that every field round-trips; spec test 5: hostile input "returns results or an empty list, never throws". (Low priority: EWS XML can't carry NUL, so it needs locally entered/pasted text, e.g. a failed send kept in Drafts.)

## Likely cause
`Sources/MailModel/MailDatabase.swift:536` (`sqlite3_bind_text(pointer, i, v, -1, …)` — should pass the UTF-8 byte count) and `:552` (`String(cString:)` — should use `sqlite3_column_bytes`). `matchExpression` (`:223-227`) doesn't strip NUL either.
