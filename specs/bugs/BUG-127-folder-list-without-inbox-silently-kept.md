---
title: 'If GetFolder answers the standard folders with errors, the check ends silently and the Inbox is not checked again until relaunch'
priority: P4
area: EWS
status: open
found: 2026-11-13
---
## Summary
`folders()` asks GetFolder non-strictly and drops every standard folder whose answer is an error. When all of them fail (here `ErrorMailboxStoreUnavailable`) but FindFolder succeeds, the account gets a folder list without Inbox. The quick check finds no Inbox, skips it and clears the status: no message at all. The list is kept for the whole session (it is only read when nil), so the Inbox is never checked until relaunch. ⚠️ Response shape not confirmed on a live server: a mailbox-wide error would likely also fail FindFolder (which is strict, so it would be reported and retried); this needs per-folder errors on GetFolder only.

## Repro
Harness (`FlowServer`, `FX`, `store(_:)`, `complete(_:_:)`, `serverMessage`, `waitFor`): top of `specs/bugs/probes/Probe_EWSFlowTests.swift` in the copy (`// file:// fixture (FIFO)`: a named pipe at a `file://` URL serves the scripted responses in order to the real EWSClient; no network, no fake class). The full harness is quoted in R3-EWSFlow-01.

```swift
    /// GetFolder answers each standard folder with an error (mailbox store unavailable, e.g. during a mailbox move).
    /// The check ends without any status and the empty folder list is kept for the session: the Inbox is never
    /// checked again until relaunch.
    // file:// fixture
    @Test func probeFolderListWithoutInboxIsReportedOrRetried() async throws {
        let e = FX.err("GetFolder", "ErrorMailboxStoreUnavailable", "The mailbox database is temporarily unavailable.")
        let server = FlowServer([FX.resp("GetFolder", String(repeating: e, count: 6)), FX.findFolder()],
                                    fallback: FX.sync("", token: "T1", last: true))
        defer { server.stop() }
        let s = store(server, folders: false)
        await s.refresh(history: false)
        let afterFirst = server.served, status = s.status
        await s.refresh(history: false)
        #expect(status != nil || server.served > afterFirst,
                "status \(String(describing: status)); requests: first check \(afterFirst), second check \(server.served - afterFirst)")
    }
```

## Expected vs actual
Expected: a status (the Inbox couldn't be found / read), or the folder list asked again on the next check.
Actual:
```
Expectation failed: status != nil || server.served > afterFirst
  status nil; requests: first check 2, second check 0
```

## Why expected
README: errors show under the window title; the Inbox is checked every 15 s. (Read from the code, not run: sign-in, `AccountsSettings.swift:159`, uses the same `folders()` call.)

## Likely cause
`Sources/EWS/EWSBackend.swift:28-31, 403-409` (`strict: false`, failed folders silently dropped) and `Sources/MailModel/MailStore.swift:1091-1093` (list kept once non-nil; a missing role is `continue`d without a status).
