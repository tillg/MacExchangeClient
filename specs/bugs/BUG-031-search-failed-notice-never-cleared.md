---
title: '"Search failed: …" stays under the window title after the search is cleared or succeeds'
priority: P3
area: MailStore
status: open
found: 2026-11-12
---
## Summary
After an index search fails, `status` is set to "Search failed: …". Clearing the search only clears the 2,000-results notice, and a later successful search only touches the limit notice, so the failure message stays until some unrelated status replaces it.

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

    final class Fail: @unchecked Sendable { var on = false }

    @Test func probe_searchFailedNoticeGoesWhenSearchCleared() async {
        let s = store([msg(work, subject: "Lunch")])
        s.searchDebounce = .zero
        s.searcher = { _, _ in throw DatabaseError(errorDescription: "broken") }
        s.searchText = "lun"
        await s.searchTask?.value
        #expect(s.status?.contains("broken") == true)
        s.searchText = ""
        #expect(s.status == nil, "status: \(String(describing: s.status))")
    }

    @Test func probe_searchFailedNoticeGoesAfterNextSuccess() async {
        let m = msg(work, subject: "Lunch")
        let s = store([m])
        s.searchDebounce = .zero
        let fail = Fail()
        s.searcher = { q, _ in if fail.on { throw DatabaseError(errorDescription: "broken") }; return [m.id] }
        fail.on = true
        s.searchText = "lun"
        await s.searchTask?.value
        fail.on = false
        s.searchText = "lunch"
        await s.searchTask?.value
        #expect(s.searchHits?.query == "lunch")
        #expect(s.status == nil, "status: \(String(describing: s.status))")
    }
}
```

## Expected vs actual
Both:
```
Expectation failed: s.status == nil
  status: Optional("Search failed: broken")
```

## Why expected
The limit notice is explicitly removed when the search is cleared or a later search is below the limit (`searchLimitIsAnnouncedAndCleared`); a search-scoped error should follow the same lifetime. A stale error under the title misleads the user that search is still broken.

## Likely cause
`Sources/MailModel/MailStore.swift:231` (only `limitNotice` is cleared) and :270-274 (success path only resets `limitNotice`); the failure text set at :278 is never cleared.
