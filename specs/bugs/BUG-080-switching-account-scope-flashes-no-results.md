---
title: Switching from one account's mailbox to another's during a search shows an empty list (No Results) until the new answer arrives
priority: P4
area: MailStore
status: open
found: 2026-11-12
---
## Summary
With a search active, selecting another account's mailbox changes the scope. Until the debounced query for the new scope returns (150 ms + query), `visibleMessages` filters the previous answer – which only holds the old account's hits – by the new account, so the list is empty and shows No Results, then fills.

## Repro
Probe file: `specs/bugs/probes/Probe_DB2Tests.swift` (copy r2db), test `probeSwitchingAccountScopeDoesNotFlashEmptyResults()`. Self-contained:

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

    /// Spec: while the hits for the current query haven't arrived, keep showing the previous results; never
    /// flash an empty list. Switching from one account's mailbox to another's with the same search text.
    @Test func probeSwitchingAccountScopeDoesNotFlashEmptyResults() async throws {
        let w = mail("Report work", rid: "W"), h = mail("Report home", account: home, rid: "H")
        let (d, url) = try db([w, h]); defer { cleanup(url) }
        let s = MailStore(accounts: [work, home], messages: [w, h])
        s.searchDebounce = .zero
        s.searcher = { q, a in try d.search(q, accounts: a) }
        s.selectedMailbox = .account(work.id, .inbox)
        s.searchText = "report"
        await s.searchTask?.value
        #expect(s.visibleMessages.map(\.subject) == ["Report work"])
        s.searchDebounce = .milliseconds(150)
        s.selectedMailbox = .account(home.id, .inbox)
        // During the pause and the query: what does the list show?
        let meanwhile = s.visibleMessages.map(\.subject)
        await s.searchTask?.value
        #expect(s.visibleMessages.map(\.subject) == ["Report home"])
        #expect(!meanwhile.isEmpty, "the list is empty (No Results) until the new answer arrives")
    }
}
```

## Expected vs actual
Expected the list never to be empty while the next answer is pending (spec). Actual: `[]` meanwhile, `["Report home"]` after.

```
Test probeSwitchingAccountScopeDoesNotFlashEmptyResults() recorded an issue at Probe_DB2Tests.swift: Expectation failed: !meanwhile.isEmpty
  the list is empty (No Results) until the new answer arrives
    meanwhile → []
Test probeSwitchingAccountScopeDoesNotFlashEmptyResults() failed after 0.291 seconds with 1 issue.
```

## Why expected
specs/change/fast-search.md §4: "While the hits for the current query haven't arrived yet, keep showing the previous result list. Don't flash an empty list or 'No Results'."

## Likely cause
`Sources/MailModel/MailStore.swift:171-178`: the previous `searchHits` are reused because they match the query text (`searchHits` is keyed by query only, :35/:264), then `hitList` filters them by the new scope, which removes all of them.
