---
title: In-memory fallback search ignores the README's matching rules (To/Cc/preview, every word, accents)
priority: P2
area: MailStore
status: design-question (README documents the launch fallback as "as before"; not counted as a bug)
found: 2026-11-12
---
## Summary
The in-memory search runs for sample data, on every launch until all stored mail has loaded, and whenever the index fails. It is still the old substring scan. README ("Search") promises the same rules on every path: every word must match, in any of subject, sender, To, Cc, server preview or a loaded body, and case and accents don't matter. The fallback breaks all three, so search during launch (or after an index error) misses mail the README says it finds. Three facets, one root cause:

1. It ignores To, Cc and `serverPreview`. Unloaded Exchange mail (most of it) is unsearchable by text.
2. A multi-word query is matched as one phrase.
3. Matching is accent-sensitive.

Note: `specs/change/fast-search.md` (§ "no searcher") said to keep the in-memory path unchanged. That conflicts with the README promise for the launch window, so decide which document wins.

# Facet 1: To/Cc/preview ignored

## Repro
File `specs/bugs/probes/Probe_StoreFlowsTests.swift` (run: `swift test ... --skip-build --filter Probe_StoreFlows`). Self-contained:

```swift
import Foundation
import Testing
@testable import MailModel

@MainActor
struct Probe_StoreFlowsTests {
    let work = Account(name: "Work", address: "me@work.com")
    let home = Account(name: "iCloud", address: "me@icloud.com")

    func msg(_ acct: Account, _ box: MailboxKind = .inbox, subject: String = "Hi", from: String = "Ann",
             body: String? = nil, to: [Contact]? = nil, cc: [Contact] = [], minutesAgo: Double = 0) -> Message {
        Message(accountID: acct.id, mailbox: box, from: Contact(name: from, email: "\(from.lowercased())@x.com"),
                to: to ?? [Contact(name: "Me", email: acct.address)], cc: cc, subject: subject,
                body: body ?? "Body of \(subject)", date: Date(timeIntervalSince1970: 1_000_000 - minutesAgo * 60))
    }
    func store(_ msgs: [Message]) -> MailStore { MailStore(accounts: [work, home], messages: msgs) }
    func tempDir() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("ProbeStoreFlows-\(UUID())") }

    @Test func probe_memorySearchFindsRecipients() {
        let s = store([msg(work, subject: "Hi", to: [Contact(name: "Zoe Quill", email: "zoe@q.com")])])
        s.searchText = "quill"
        #expect(s.visibleMessages.count == 1)
    }

    @Test func probe_memorySearchFindsServerPreviewOfUnloadedBody() {
        var m = msg(work, subject: "Hi", body: "")
        m.bodyLoaded = false
        m.serverPreview = "the quarterly forecast"
        m.remoteID = "r1"
        let s = store([m])
        s.searchText = "forecast"
        #expect(s.visibleMessages.count == 1)
    }
}
```

## Expected vs actual
Both:
```
Expectation failed: s.visibleMessages.count == 1
  s.visibleMessages.count → 0
```

## Why expected
README Search: matches "in any of subject, sender, To, Cc, the server's preview or a loaded body". The FTS index covers those fields (README Search index), the memory fallback doesn't.

## Likely cause
`Sources/MailModel/MailStore.swift:185` — field list `[m.subject, m.from.name, m.from.email, m.body]` lacks `m.to`, `m.cc`, `m.serverPreview`.

# Facet 2: multi-word query is one phrase
## Summary
Without the index (sample data, every launch until stored mail is loaded, and after an index failure) the query is matched as one substring. `budget review` doesn't find "Review of the budget" although README says every word must match, in any order.

## Repro
File `specs/bugs/probes/Probe_StoreFlowsTests.swift` (run: `swift test ... --skip-build --filter Probe_StoreFlows`). Self-contained:

```swift
import Foundation
import Testing
@testable import MailModel

@MainActor
struct Probe_StoreFlowsTests {
    let work = Account(name: "Work", address: "me@work.com")
    let home = Account(name: "iCloud", address: "me@icloud.com")

    func msg(_ acct: Account, _ box: MailboxKind = .inbox, subject: String = "Hi", from: String = "Ann",
             body: String? = nil, to: [Contact]? = nil, cc: [Contact] = [], minutesAgo: Double = 0) -> Message {
        Message(accountID: acct.id, mailbox: box, from: Contact(name: from, email: "\(from.lowercased())@x.com"),
                to: to ?? [Contact(name: "Me", email: acct.address)], cc: cc, subject: subject,
                body: body ?? "Body of \(subject)", date: Date(timeIntervalSince1970: 1_000_000 - minutesAgo * 60))
    }
    func store(_ msgs: [Message]) -> MailStore { MailStore(accounts: [work, home], messages: msgs) }
    func tempDir() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("ProbeStoreFlows-\(UUID())") }

    @Test func probe_memorySearchMatchesEveryWordAnywhere() {
        let s = store([msg(work, subject: "Review of the budget")])
        s.searchText = "budget review"
        #expect(s.visibleMessages.count == 1)
    }
}
```

## Expected vs actual
```
Expectation failed: s.visibleMessages.count == 1
  s.visibleMessages.count → 0
```

## Why expected
README Search: "Every word you type must match, in any of subject, sender, To, Cc, the server's preview or a loaded body." The memory path is the documented fallback during launch and after a failed index search (`aFailedIndexSearchFallsBackToMemory`), so the same query gives different results depending on timing. (Substring vs word-prefix is intentionally different per `searchTypedBeforeTheIndexIsReady`; word splitting is not addressed there.)

## Likely cause
`Sources/MailModel/MailStore.swift:185` — `$0.lowercased().contains(q)` with the whole query; no split into words.

# Facet 3: accent-sensitive
## Summary
The memory search lowercases but doesn't fold diacritics, so `muller` finds nothing for sender Müller while the index search would.

## Repro
File `specs/bugs/probes/Probe_StoreFlowsTests.swift` (run: `swift test ... --skip-build --filter Probe_StoreFlows`). Self-contained:

```swift
import Foundation
import Testing
@testable import MailModel

@MainActor
struct Probe_StoreFlowsTests {
    let work = Account(name: "Work", address: "me@work.com")
    let home = Account(name: "iCloud", address: "me@icloud.com")

    func msg(_ acct: Account, _ box: MailboxKind = .inbox, subject: String = "Hi", from: String = "Ann",
             body: String? = nil, to: [Contact]? = nil, cc: [Contact] = [], minutesAgo: Double = 0) -> Message {
        Message(accountID: acct.id, mailbox: box, from: Contact(name: from, email: "\(from.lowercased())@x.com"),
                to: to ?? [Contact(name: "Me", email: acct.address)], cc: cc, subject: subject,
                body: body ?? "Body of \(subject)", date: Date(timeIntervalSince1970: 1_000_000 - minutesAgo * 60))
    }
    func store(_ msgs: [Message]) -> MailStore { MailStore(accounts: [work, home], messages: msgs) }
    func tempDir() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("ProbeStoreFlows-\(UUID())") }

    @Test func probe_memorySearchIgnoresAccents() {
        let s = store([msg(work, subject: "Hi", from: "Müller")])
        s.searchText = "muller"
        #expect(s.visibleMessages.count == 1)
    }
}
```

## Expected vs actual
```
Expectation failed: s.visibleMessages.count == 1
  s.visibleMessages.count → 0
```

## Why expected
README Search: "Case and accents don't matter (`muller` finds \"Müller\")". Memory search is used for sample data, during launch and after an index error.

## Likely cause
`Sources/MailModel/MailStore.swift:185` (and `normalizedSearch` :216) — `lowercased().contains` instead of `range(of:options:[.caseInsensitive,.diacriticInsensitive])` / folding.
