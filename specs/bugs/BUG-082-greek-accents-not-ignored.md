---
title: 'Search doesn''t ignore Greek accents: "καλημερα" doesn''t find "Καλημέρα"'
priority: P4
area: MailDatabase
status: open
found: 2026-11-12
---
## Summary
The index removes diacritics from Latin letters only. Greek words with a tonos (ά, έ, ή, ί, ό, ύ, ώ) are not found when typed without it, which is how Greek is usually typed in search. Latin controls (cafe→Café, zurich→Zürich, sao→São) pass.

## Repro
Probe file: `specs/bugs/probes/Probe_DB2Tests.swift` (copy r2db), test `probeAccentsOfOtherScripts(query:subject:)`. Self-contained:

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

    func probeAccentsOfOtherScripts(query: String, subject: String) throws {
        let (d, url) = try db([mail(subject)]); defer { cleanup(url) }
        #expect(try d.search(query, accounts: nil).count == 1, "\(query) → \(subject)")
    }
}
```

## Expected vs actual
Expected 1 hit for each pair. Actual: 0 for all three Greek pairs.

```
Test probeAccentsOfOtherScripts(query:subject:) recorded an issue with 2 arguments query → "καλημερα", subject → "Καλημέρα σας" … Expectation failed
Test probeAccentsOfOtherScripts(query:subject:) recorded an issue with 2 arguments query → "αθηνα", subject → "Ταξίδι στην Αθήνα" … Expectation failed
Test probeAccentsOfOtherScripts(query:subject:) recorded an issue with 2 arguments query → "ελληνικα", subject → "ΕΛΛΗΝΙΚΆ" … Expectation failed
Test probeAccentsOfOtherScripts(query:subject:) with 6 test cases failed after 0.052 seconds with 3 issues.
```

## Why expected
README: "Case and accents don't matter (`muller` finds \"Müller\")".

## Likely cause
`Sources/MailModel/MailDatabase.swift:152`: `unicode61 remove_diacritics 2` folds only Latin-script diacritics; the query text isn't folded either (`matchExpression`, :223).
