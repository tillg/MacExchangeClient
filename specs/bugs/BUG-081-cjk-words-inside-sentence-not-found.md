---
title: Index search can't find a Chinese or Japanese word inside a sentence (the old search could)
priority: P4
area: MailDatabase
status: open
found: 2026-11-12
---
## Summary
The `unicode61` tokenizer splits only on spaces and punctuation. Chinese and Japanese are written without spaces, so a whole sentence is one token and only its first characters match a prefix: "会议" (meeting) isn't found in "明天的会议取消了", "議事録" (minutes) not in "会議の議事録を送ります". The in-memory search found them.

## Repro
Probe file: `specs/bugs/probes/Probe_DB2Tests.swift` (copy r2db), test `probeWordInsideChineseOrJapaneseSentence()`. Self-contained:

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

    /// README: the start of words matches. Chinese and Japanese write without spaces, so the tokenizer sees a
    /// whole sentence as one "word": a word inside it is never found (the old search found it).
    @Test func probeWordInsideChineseOrJapaneseSentence() throws {
        let (d, url) = try db([mail("明天的会议取消了"), mail("会議の議事録を送ります")]); defer { cleanup(url) }
        #expect(try d.search("明天", accounts: nil).count == 1)   // control: start of the run
        #expect(try d.search("会议", accounts: nil).count == 1, "会议 (meeting) inside a sentence")
        #expect(try d.search("議事録", accounts: nil).count == 1, "議事録 (minutes) inside a sentence")
    }
}
```

## Expected vs actual
Expected 1 hit each (as for "明天", the start of the run, which passes). Actual: 0.

```
Expectation failed: try d.search("会议", accounts: nil).count == 1
  会议 (meeting) inside a sentence
Expectation failed: try d.search("議事録", accounts: nil).count == 1
  議事録 (minutes) inside a sentence
Test probeWordInsideChineseOrJapaneseSentence() failed after 0.028 seconds with 2 issues.
```

## Why expected
README: search "matches the start of words … Every word you type must match"; spec §5 calls the change "closer to the original" (Mail and Outlook match word prefixes) – both segment CJK text into words, so a CJK word is findable there.

## Likely cause
`Sources/MailModel/MailDatabase.swift:152` `tokenize='unicode61 remove_diacritics 2'`: no word segmentation for scripts without spaces.
