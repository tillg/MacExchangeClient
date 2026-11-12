---
title: 'Selecting a mailbox while a check is running doesn''t check it (README: "at once when you select a mailbox")'
priority: P4
area: MailStore
status: open
found: 2026-11-13
---
## Summary
The sidebar calls `refresh()` when the selection changes. If a check is already running (the 15-second poll, the history start, a pull to refresh), the new call returns at once because of `isRefreshing`, and the running check had fixed its mailboxes before the selection changed. The newly selected mailbox is only checked by the next poll, up to 15 s later.

## Repro
Harness (`FlowServer`, `FX`, `store(_:)`, `complete(_:_:)`, `serverMessage`, `waitFor`): top of `specs/bugs/probes/Probe_EWSFlowTests.swift` in the copy (`// file:// fixture (FIFO)`: a named pipe at a `file://` URL serves the scripted responses in order to the real EWSClient; no network, no fake class). The full harness is quoted in R3-EWSFlow-01.

```swift
    // file:// fixture (FIFO)
    /// README: the quick check runs "at once when you select a mailbox". Selecting one while a check is running
    /// (every 15 s, so often) does nothing: the running check doesn't include it and the new one returns at once.
    // file:// fixture
    @Test func probeMailboxSelectedDuringCheckIsChecked() async throws {
        let server = FlowServer([], hold: true)
        defer { server.stop() }
        let s = store(server)
        complete(s, .inbox); complete(s, .archive)
        let first = Task { await s.refresh(history: false) }
        try await waitFor { s.isRefreshing }
        try await Task.sleep(for: .milliseconds(100))   // the Inbox request is waiting for the server
        s.selectedMailbox = .account(acct.id, .archive)
        let second = Task { await s.refresh(history: false) }   // what the sidebar does on selection
        try await Task.sleep(for: .milliseconds(100))
        server.push(FX.sync("", token: "T1", last: true))   // Inbox
        server.push(FX.sync(FX.create(FX.summary("NEWARCH", subject: "Filed elsewhere")), token: "T1", last: true))  // Archive
        await first.value; await second.value
        try await Task.sleep(for: .milliseconds(200))
        #expect(s.messages.contains { $0.remoteID == "NEWARCH" }, "requests \(server.served), unasked responses \(server.pending)")
    }
```

## Expected vs actual
Expected: the Archive is asked right after it is selected (its new message shows).
Actual:
```
Expectation failed: s.messages.contains { $0.remoteID == "NEWARCH" }
  requests 1, unasked responses 1
```

## Why expected
README ✅ How mail is fetched: "Quick check: every 15 seconds, and at once when you select a mailbox."

## Likely cause
`Sources/MailModel/MailStore.swift:1083` (`guard !isRefreshing else { return }`) drops the request instead of remembering it; `quickCheckRoles(acct)` (:1092) is evaluated once at the start of the running check.
