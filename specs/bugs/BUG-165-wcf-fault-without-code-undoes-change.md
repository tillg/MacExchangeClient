---
title: 'A SOAP fault without an Exchange ResponseCode (IIS/WCF internal error) undoes the change as "refused"'
priority: P3
area: EWS
status: deferred
found: 2026-11-13
---
Draft id: R5B-05 (probe suites `Probe_R5*` in `probes/Probe_R5*Tests.swift`).

## Summary
`EWSClient.call` turns every SOAP `Fault` other than `ErrorServerBusy` into an `EWSError`. When the fault has no Exchange `ResponseCode`, the code is "SOAP fault". The fault here is the WCF dispatcher's `a:InternalServiceFault` ("The server was unable to process the request due to an internal error"), which the EWS service host sends when it fails before Exchange handles the request. `drain` then treats it as a refusal: the user's mark as read is undone with "Exchange refused a change: … (SOAP fault)" and never retried.

## Expected
d-bug-061: "a body that isn't an Exchange answer means Exchange didn't act, so nothing was refused", and such changes stay queued. ews.md › Transport: an answer "without any `ResponseCode`" throws `ServerBusy` ("nothing was refused"). The same paragraph says "any other `Fault` throws its `ResponseCode`/`faultstring`", but this fault has no `ResponseCode`, so it isn't an Exchange refusal. ⚠️ The WCF fault body is hand-written from the standard WCF dispatcher fault and not captured from the live server.

## Repro
Probe file: `Tests/MailModelTests/Probe_R5BTests.swift` (suite `Probe_R5BTests`), test(s) `r5b05_wcfFaultWithoutExchangeCodeKeepsTheChangeQueued`.

```sh
swift build --package-path . --scratch-path .build/tests --target MailModelTests -Xswiftc -load-plugin-library -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
swift test --package-path . --scratch-path .build/tests --skip-build --filter 'Probe_R5BTests/r5b05_wcfFaultWithoutExchangeCodeKeepsTheChangeQueued'
```

## Failure output
```
Expectation failed: s.message(mid(s, "A"))?.isRead == true
status: Exchange refused a change: The server was unable to process the request due to an internal error. (SOAP fault)
Expectation failed: s.outbox.map(\.change) == [.setRead(["A"], true)]
s.outbox.map(\.change) → []
```

## Fix idea
In `EWSClient.call`, a `Fault` without an Exchange `ResponseCode` in its detail should throw `ServerBusy` (not refused), like an answer without any `ResponseCode`.

## Deferred (2026-11-13)
needs a decision on which faults count as "server down" vs "refused"; the WCF fault shape is hand-written (⚠️), not seen from the live server. See DECISIONS.md run-2026-11-13-1235-12.
