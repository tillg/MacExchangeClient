---
title: 'A send that Exchange throttles doesn''t hold back the account''s other changes: they go out at once, inside the back-off'
priority: P3
area: Outbox
status: open
found: 2026-11-13
---
Draft id: R5B-04 (probe suites `Probe_R5*` in `probes/Probe_R5*Tests.swift`).

## Summary
In `drain`, a `ServerBusy` on a `send`, `respond` or `reply` goes to `failed` (Drafts) and `continue`s before the account is set aside and before `busyUntil` is set. The account's next queued change (a mark as read in the probe) is sent right away to a server that asked to wait 60 s. The same happens on a `URLError` for a send. The next change then times out too before the account is set aside.

## Expected
README: "The same holds when Exchange is busy (it asks to wait, and your changes aren't sent again before then)". architecture.md › outbox: on `ServerBusy` "other changes of that account stay queued in order ... and with a back-off none of them is sent before it has passed (`busyUntil`)".

## Repro
Probe file: `Tests/MailModelTests/Probe_R5BTests.swift` (suite `Probe_R5BTests`), test(s) `r5b04_throttledSendHoldsTheAccountsOtherChanges`.

```sh
swift build --package-path . --scratch-path .build/tests --target MailModelTests -Xswiftc -load-plugin-library -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
swift test --package-path . --scratch-path .build/tests --skip-build --filter 'Probe_R5BTests/r5b04_throttledSendHoldsTheAccountsOtherChanges'
```

## Failure output
```
Expectation failed: server.served == 1
2 requests went to a server that asked to wait 60 s
Expectation failed: s.outbox.map(\.change) == [.setRead(["A"], true)]
s.outbox.map(\.change) → []
```

## Fix idea
In `MailStore.drain`, for `send`/`respond`/`reply` on `ServerBusy`/`URLError`, call `failed`, then also `unreachable.insert(p.account)` and set `busyUntil` from `retryAfter` instead of `continue`. It may be the same fix theme as BUG-161 (the back-off isn't account-wide).
