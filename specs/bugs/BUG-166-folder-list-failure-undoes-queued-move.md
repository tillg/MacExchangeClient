---
title: 'A queued move is undone as "refused" when reading the folder list fails'
priority: P3
area: Outbox
status: open
found: 2026-11-13
---
Draft id: R5B-06 (probe suites `Probe_R5*` in `probes/Probe_R5*Tests.swift`).

## Summary
A move needs the folder list. When it isn't read yet (a drop or Archive right after launch), `perform(.move)` reads it first. If GetFolder fails with an Exchange error (the mailbox store is briefly unavailable, BUG-127's `ErrorMailboxStoreUnavailable`), that error leaves `perform` as an `EWSError`. `drain` then treats it as Exchange refusing the move: the message jumps back to the Inbox with "Exchange refused a change: The mailbox database is temporarily unavailable.", and the move is never retried. Exchange never saw the move.

## Expected
README: "If the server refuses a change, it is undone"; "Offline, changes wait until the next refresh". d-bug-136 makes the same distinction for the move after an answer: the folder list is read there so that a failure to read it doesn't undo the user's action. Plain correctness: a request that was never sent can't have been refused.

## Repro
Probe file: `Tests/MailModelTests/Probe_R5BTests.swift` (suite `Probe_R5BTests`), test(s) `r5b06_failedFolderListDoesNotUndoAQueuedMove`.

```sh
swift build --package-path . --scratch-path .build/tests --target MailModelTests -Xswiftc -load-plugin-library -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
swift test --package-path . --scratch-path .build/tests --skip-build --filter 'Probe_R5BTests/r5b06_failedFolderListDoesNotUndoAQueuedMove'
```

## Failure output
```
Expectation failed: s.message(mid(s, "A"))?.mailbox == .archive
status: Exchange refused a change: The mailbox database is temporarily unavailable. (ErrorMailboxStoreUnavailable)
s.message(mid(s, "A"))?.mailbox → MailboxKind(rawValue: "inbox")
Expectation failed: s.outbox.count == 1
s.outbox.count → 0
```

## Fix idea
In `MailStore.perform(.move)`, wrap the `b.folders()` call: on any error, rethrow it as `ServerBusy` (keep queued, set the account aside) instead of letting it reach `failed`.
