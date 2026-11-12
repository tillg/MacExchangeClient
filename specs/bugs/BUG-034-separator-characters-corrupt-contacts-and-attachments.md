---
title: "Names containing U+001E/U+001F corrupt the stored To/Cc and attachment lists"
priority: P4
area: MailDatabase
status: open
found: 2026-11-12
---

## Summary
To/Cc and attachments are stored as `name␟email␞…` / `name␟size␟type␞…` without escaping. A display name, address or file name containing U+001E or U+001F is split into extra contacts/attachments (or loses its text) after a relaunch.

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

    @Test func probeSeparatorCharactersInContactNamesSurvive() throws {
        var m = mail("sep", to: [Contact(name: "A\u{1E}B", email: "a@x.com"), Contact(name: "C", email: "c\u{1F}d@x.com")])
        m.cc = [Contact(name: "Unit\u{1F}Sep", email: "u@x.com")]
        let (_, url) = try db([m]); defer { cleanup(url) }
        let back = try MailDatabase(url: url).messages()
        #expect(back.first?.to == m.to)
        #expect(back.first?.cc == m.cc)
    }

    @Test func probeSeparatorCharactersInAttachmentNamesSurvive() throws {
        var m = mail("att")
        m.attachments = [MailModel.Attachment(name: "report\u{1E}2026.pdf", size: 10, contentType: "application/pdf"),
                         MailModel.Attachment(name: "a\u{1F}b.txt", size: 3, contentType: "text/plain")]
        m.hasAttachments = true
        let (_, url) = try db([m]); defer { cleanup(url) }
        let back = try MailDatabase(url: url).messages()
        #expect(back.first?.attachments == m.attachments)
    }
}
```

## Expected vs actual
```
Expectation failed: back.first?.to == m.to
Expectation failed: back.first?.cc == m.cc
Expectation failed: back.first?.attachments == m.attachments
```

## Why expected
Every field of a message is meant to survive a write/read (`everyFieldOfAMessageSurvives`). The comment at `MailDatabase.swift:429` assumes these "control characters … don't occur in names or addresses", which isn't enforced. Low priority: XML 1.0 forbids these characters, so Exchange can't deliver them; only locally typed/pasted text (failed sends kept in Drafts) or future backends can.

## Likely cause
`Sources/MailModel/MailDatabase.swift:430-453` — `contacts(_:)` / `attachments(_:)` join and split on U+001F/U+001E with no escaping or validation.
