---
title: 'While the next search answer is on its way, the list jumps back to the plain mailbox (or "No Results") when the previous results came from memory'
priority: P4
area: MailStore
status: open
found: 2026-11-13
---
## Summary
The list keeps "the previous results" only if they came from the index (`searchHits`). When the previous results came from the memory scan (typed before the index was ready, or the index failed for that query), typing one more character makes the list jump back to the selected mailbox's normal content until the index answers. The same happens for the first query of a search, so in an empty mailbox "No Results" flashes although the search finds mail.

## Repro
Probe file: `specs/bugs/probes/Probe_Search3Tests.swift` (helpers `msg`, `store`, `tempDB`, `indexed`, `Gate` are in that file).

```swift
@Test func probe_typingOnAfterIndexBecomesReadyShowsMailboxNotResults() async throws {
    let hit = msg(work, subject: "Report Q3", minutesAgo: 5, remote: "a"),
        other = msg(work, subject: "Lunch", minutesAgo: 1, remote: "b")
    let s = store([hit, other])
    s.selectedMailbox = .account(work.id, .inbox)
    s.searchText = "report"
    #expect(s.visibleMessages.map(\.subject) == ["Report Q3"])  // memory
    for a in [work] { s.merge([], account: a.id) }
    let (db, url) = try tempDB()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try db.write(s.storedState())
    let gate = Gate(slow: ["report", "report q"])
    s.searchDebounce = .zero
    s.searcher = { q, a in await gate.pass(q); return try db.search(q, accounts: a) }
    var started = gate.entered.makeAsyncIterator()
    _ = await started.next()
    #expect(s.visibleMessages.map(\.subject) == ["Report Q3"])  // memory still answers
    s.searchText = "report q"
    _ = await started.next()
    #expect(s.visibleMessages.map(\.subject) == ["Report Q3"], "\(s.visibleMessages.map(\.subject))")
    gate.release("report"); gate.release("report q")
    await s.searchTask?.value
}

@Test func probe_afterFailedQueryNextPendingShowsMailbox() async throws {
    let hit = msg(work, subject: "Report Q3", minutesAgo: 5), other = msg(work, subject: "Lunch", minutesAgo: 1)
    let s = store([hit, other])
    s.selectedMailbox = .account(work.id, .inbox)
    let gate = Gate(slow: ["report q"])
    final class Flag: @unchecked Sendable { var fail = true }
    let flag = Flag()
    s.searchDebounce = .zero
    s.searcher = { q, _ in
        if flag.fail { throw DatabaseError(errorDescription: "busy") }
        await gate.pass(q)
        return [hit.id]
    }
    s.searchText = "report"; await s.searchTask?.value
    #expect(s.visibleMessages.map(\.subject) == ["Report Q3"])  // memory fallback
    flag.fail = false
    var started = gate.entered.makeAsyncIterator()
    s.searchText = "report q"
    _ = await started.next()
    #expect(s.visibleMessages.map(\.subject) == ["Report Q3"], "\(s.visibleMessages.map(\.subject))")
    gate.release("report q")
    await s.searchTask?.value
}

// Same mechanism, first query of a search in an empty mailbox:
@Test func probe_firstPendingAnswerInEmptyMailboxShowsNoResults() async throws {
    let archived = msg(work, .archive, subject: "Report archived", remote: "a")
    let s = store([archived])
    let (db, url) = try indexed(s, accounts: [work])
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let gate = Gate(slow: ["report"])
    s.searcher = { q, a in await gate.pass(q); return try db.search(q, accounts: a) }
    s.selectedMailbox = .account(work.id, .inbox)  // empty
    var started = gate.entered.makeAsyncIterator()
    s.searchText = "report"
    _ = await started.next()
    #expect(!s.visibleMessages.isEmpty, "list while the answer is pending: \(s.visibleMessages.map(\.subject))")
    gate.release("report")
    await s.searchTask?.value
}
```

## Expected vs actual
Expected: while "report q" is pending, the list keeps the previous results `["Report Q3"]`. Actual: the Inbox as it is, including the non-matching "Lunch":

```
Test probe_typingOnAfterIndexBecomesReadyShowsMailboxNotResults() recorded an issue at Probe_Search3Tests.swift:210:9: Expectation failed: s.visibleMessages.map(\.subject) == ["Report Q3"]
  s.visibleMessages.map(\.subject) → ["Lunch", "Report Q3"]
Test probe_afterFailedQueryNextPendingShowsMailbox() recorded an issue at Probe_Search3Tests.swift:236:9: Expectation failed: s.visibleMessages.map(\.subject) == ["Report Q3"]
  s.visibleMessages.map(\.subject) → ["Lunch", "Report Q3"]
Test probe_firstPendingAnswerInEmptyMailboxShowsNoResults() recorded an issue at Probe_Search3Tests.swift:537:9: Expectation failed: !s.visibleMessages.isEmpty
  s.visibleMessages → []
```
With an empty list and non-empty search text, `MessageListView` shows `ContentUnavailableView.search` ("No Results for …") for at least the 150 ms debounce.

## Why expected
`specs/change/fast-search.md` §4: "While the hits for the current query haven't arrived yet, keep showing the previous result list. Don't flash an empty list or 'No Results'." (test 14 of that spec only covers the case where the previous answer came from the index). A list that suddenly contains non-matching mail ("Lunch") while the search field says "report q" looks like a wrong result.

## Likely cause
`Sources/MailModel/MailStore.swift:179-181` (`visibleMessages`): `useIndex` is true as soon as `fallbackQuery != typed`, and then `q = hits?.query ?? ""`. With no index answer yet (`searchHits == nil`), `q` is empty and the function falls through to the plain mailbox filter. The memory results that were on screen are keyed only by `fallbackQuery` (set at :38 when the searcher arrives and at :292 on an index error), which stops matching the moment the text changes. Nothing remembers "the previous results" except `searchHits`.
