---
title: 'Quick check and history page forever when the server answers "more" with the same SyncState'
priority: P4
area: MailStore
status: open
found: 2026-11-13
---
## Summary
Both paging loops follow `IncludesLastItemInRange=false` without checking that the SyncState moved on. A server that keeps answering "more" with the same state (a server-side fault, not normal Exchange behaviour) makes the quick check never return, so `isRefreshing` stays true and every later check, pull to refresh and mailbox selection is skipped; the history asks for the same page without end and the sidebar shows "Synchronizing …" for good. The folder list loop guards against exactly this ("never the same page twice").

## Repro
Harness (`FlowServer`, `FX`, `store(_:)`, `complete(_:_:)`, `serverMessage`, `waitFor`): top of `specs/bugs/probes/Probe_EWSFlowTests.swift` in the copy (`// file:// fixture (FIFO)`: a named pipe at a `file://` URL serves the scripted responses in order to the real EWSClient; no network, no fake class). The full harness is quoted in R3-EWSFlow-01.

```swift
    /// file:// fixture (plain file, as round 2): the quick check's paging loop against a server that repeats
    /// "more" with the same SyncState.
    // file:// fixture
    @Test func probeQuickCheckPagingEndsStaticFile() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ews-\(UUID().uuidString).xml")
        try Data(FX.sync("", token: "T1", last: false).utf8).write(to: url)
        let s = MailStore(accounts: [], messages: [])
        s.add(acct, backend: EWSBackend(client: EWSClient(url: url, username: "u", password: "p")))  // file:// fixture
        s.setRemoteFolders([RemoteFolder(role: .inbox, id: "INBOX")], account: acct.id)
        complete(s, .inbox, token: "T1")
        let task = Task { await s.refresh(history: false) }
        try await Task.sleep(for: .seconds(3))
        let stillRunning = s.isRefreshing
        try Data(FX.sync("", token: "T1", last: true).utf8).write(to: url)
        await task.value
        #expect(!stillRunning, "the check is still running after 3 s (same page asked again and again)")
    }

    /// file:// fixture (plain file): the history's paging has the same gap. A server repeating "more" with the same
    /// SyncState keeps the history asking for the same page without end (the progress bar never goes away).
    @Test func probeHistoryPagingEndsStaticFile() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ews-\(UUID().uuidString).xml")
        try Data(FX.sync("", token: "T1", last: false).utf8).write(to: url)
        let s = MailStore(accounts: [], messages: [])
        s.add(acct, backend: EWSBackend(client: EWSClient(url: url, username: "u", password: "p")))  // file:// fixture
        s.setRemoteFolders([RemoteFolder(role: .inbox, id: "INBOX", totalCount: 1)], account: acct.id)
        let task = Task { await s.syncHistory() }
        try await Task.sleep(for: .seconds(4))
        let progress = s.progress, token = s.syncToken(acct.id, .inbox)
        try Data(FX.sync("", token: "T1", last: true).utf8).write(to: url)
        await task.value
        #expect(progress == nil, "history still running after 4 s, token \(String(describing: token)), progress \(String(describing: progress))")
    }
```

## Expected vs actual
Expected: the loop stops (and reports) when a page doesn't advance.
Actual:
```
probeQuickCheckPagingEndsStaticFile: Expectation failed: !stillRunning
  the check is still running after 3 s (same page asked again and again)
probeHistoryPagingEndsStaticFile: Expectation failed: progress == nil
  history still running after 4 s, token Optional("T1"), progress Optional(MailModel.SyncProgress(text: "Synchronizing “Exchange”", fraction: Optional(0.0)))
```
(Both use a plain `file://` response file, as in round 2.)

## Why expected
Consistency with `EWSBackend.folders()` (`EWSBackend.swift:38`: `offset = … $0 > o ? $0 : nil  // never the same page twice`). Low priority: needs a misbehaving server or proxy.

## Likely cause
`Sources/MailModel/MailStore.swift:1095-1100` (quick check `while more`), `:1195-1199` plus `nextHistoryFolder` (:1234-1243) picking the same incomplete folder again, and `:1215-1220` (background delta): none compares the new token with the one sent.
