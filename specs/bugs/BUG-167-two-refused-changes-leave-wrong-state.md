---
title: 'Two refused changes of the same message leave it in the state of the first change, which the server never had'
priority: P3
area: Outbox
status: open
found: 2026-11-13
---
Draft id: R5B-07 (probe suites `Probe_R5*` in `probes/Probe_R5*Tests.swift`).

## Summary
Each queued change keeps the message as it was just before that change. If both changes of one property are refused (move to Archive, then on to Junk; or mark read, then unread again), `failed` undoes the first one only if the value it set still holds, and it doesn't. It then undoes the second one to the value before it, which is the first change's value. The message ends up in Archive (or read) here while the server has it in the Inbox (unread). Since nothing changes on the server, no later sync corrects it: the local state stays wrong for good.

## Expected
README: "If the server refuses a change, it is undone". Plain correctness: after every change is refused, the local state must equal the server's. d-bug-023 ("A refused change undoes only what it set, while that still holds") targets later changes that *succeeded*, not a chain that was refused as a whole.

## Repro
Probe file: `Tests/MailModelTests/Probe_R5BTests.swift` (suite `Probe_R5BTests`), test(s) `r5b07_twoRefusedMovesPutTheMessageBackWhereTheServerHasIt; r5b07_twoRefusedReadChangesLeaveTheServersState`.

```sh
swift build --package-path . --scratch-path .build/tests --target MailModelTests -Xswiftc -load-plugin-library -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
swift test --package-path . --scratch-path .build/tests --skip-build --filter 'Probe_R5BTests/r5b07'
```

## Failure output
```
r5b07_twoRefusedMovesPutTheMessageBackWhereTheServerHasIt: Expectation failed: s.message(mid(s, "A"))?.mailbox == .inbox
status: Exchange refused a change: Access is denied. (ErrorAccessDenied)
s.message(mid(s, "A"))?.mailbox → MailboxKind(rawValue: "archive")

r5b07_twoRefusedReadChangesLeaveTheServersState: Expectation failed: s.message(mid(s, "A"))?.isRead == false
status: Exchange refused a change: Access is denied. (ErrorAccessDenied)
```

## Fix idea
In `MailStore.failed`, when the refused change's value no longer holds because a later queued change of the same property overwrote it, rewrite that later change's `previous` copy to this change's `previous` value (so its undo goes to the server's state) instead of doing nothing.
