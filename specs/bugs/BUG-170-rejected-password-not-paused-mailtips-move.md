---
title: 'A rejected password seen by MailTips or by the move after an unsent answer doesn''t pause the account, so the wrong password is sent again'
priority: P3
area: EWS
status: open
found: 2026-11-13
---
Draft id: R5B-10 (probe suites `Probe_R5*` in `probes/Probe_R5*Tests.swift`).

## Summary
Two calls catch `AuthenticationError` without pausing the account. `loadMaxMessageSize` uses `try?`, so a 401 there is swallowed and the next check sends the rejected password again. `moveToTrash` (after Do Not Send a Response or Remove from Calendar) queues the move on `AuthenticationError` as d-bug-136 says, but doesn't pause. `drain` picks that queued move up at once and sends it with the rejected password (3 requests in the probe instead of 2). Each extra attempt counts toward the domain account's lockout.

## Expected
README: "If Exchange rejects the password, the app stops sending requests for that account until you relaunch, because repeated wrong passwords lock domain accounts." MailBackend.swift `AuthenticationError`: "Backends throw this so the store stops retrying".

## Repro
Probe file: `Tests/MailModelTests/Probe_R5BTests.swift` (suite `Probe_R5BTests`), test(s) `r5b10_rejectedPasswordOnMailTipsPausesTheAccount; r5b10_rejectedPasswordOnTheMoveAfterAnAnswerPausesTheAccount`.

```sh
swift build --package-path . --scratch-path .build/tests --target MailModelTests -Xswiftc -load-plugin-library -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
swift test --package-path . --scratch-path .build/tests --skip-build --filter 'Probe_R5BTests/r5b10'
```

## Failure output
```
r5b10_rejectedPasswordOnMailTipsPausesTheAccount: Expectation failed: s.isPaused(acct.id)
status: 
s.isPaused(acct.id) → false

r5b10_rejectedPasswordOnTheMoveAfterAnAnswerPausesTheAccount: Expectation failed: server.served == 2
3 requests; the rejected password was sent again
```

## Fix idea
In `loadMaxMessageSize`, use `do/catch` and call `pauseIfSignInFailed`. In `moveToTrash`, call `pauseIfSignInFailed(error, account:)` in the `AuthenticationError` case (the move stays queued).
