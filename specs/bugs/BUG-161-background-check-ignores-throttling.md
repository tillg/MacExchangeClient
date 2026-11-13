---
title: 'Exchange throttling during the background check of off-screen folders doesn''t set the account aside: every other folder is asked again'
priority: P3
area: Sync
status: open
found: 2026-11-13
---
Draft id: R5B-01 (probe suites `Probe_R5*` in `probes/Probe_R5*Tests.swift`).

## Summary
After the history, phase 3 asks each complete folder that isn't on screen for changes. When Exchange throttles the account there (`ErrorServerBusy` fault with `BackOffMilliseconds`), the loop only stops for `URLError` or a sign-in failure. A throttling error just moves on to the next folder, so a throttled server gets one more request per folder (three in the probe; one per user folder on a real mailbox). Each request it rejects makes the throttling worse.

## Expected
architecture.md › History: "a `URLError` or a `ServerBusy` with a back-off (throttling) sets that account aside until the next check", and "Phase 3 syncs changes of every complete folder ... for the accounts not set aside". README: when Exchange is busy, "it asks to wait". d-bug-098-followup: "Throttling is per account and passes".

## Repro
Probe file: `Tests/MailModelTests/Probe_R5BTests.swift` (suite `Probe_R5BTests`), test(s) `r5b01_backgroundCheckStopsAtThrottling`.

```sh
swift build --package-path . --scratch-path .build/tests --target MailModelTests -Xswiftc -load-plugin-library -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
swift test --package-path . --scratch-path .build/tests --skip-build --filter 'Probe_R5BTests/r5b01_backgroundCheckStopsAtThrottling'
```

## Failure output
```
Expectation failed: server.served == 1
a throttled account was asked 3 times in one background run
```

## Fix idea
In `MailStore.syncHistory` phase 3, the `catch` should also `break` for `ServerBusy` with a `retryAfter` (the same rule as phase 2). The send branch of `drain` has the same gap: see BUG-164.
