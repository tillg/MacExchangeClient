---
title: 'One folder that Exchange refuses in the history''s first step stops the newest-200 fetch for all the account''s other folders'
priority: P4
area: Sync
status: open
found: 2026-11-13
---
Draft id: R5B-08 (probe suites `Probe_R5*` in `probes/Probe_R5*Tests.swift`).

## Summary
Phase 1 of `syncHistory` fetches the newest 200 of every incomplete folder. On any error it does `break`, so one folder that Exchange refuses (access denied, a folder deleted meanwhile) ends phase 1 for every folder after it, with no status. Those folders are then filled only by the slower page-by-page phase 2. In the probe Drafts never gets its newest messages. The refused folder comes first again on every run, so it stays that way for the session.

## Expected
README › How mail is fetched: "History ... first the newest 200 messages of every folder". `syncHistory` doc: "A failing folder doesn't stop the others". architecture.md: "phase 1 fetches the newest 200 of every incomplete folder".

## Repro
Probe file: `Tests/MailModelTests/Probe_R5BTests.swift` (suite `Probe_R5BTests`), test(s) `r5b08_oneRefusedFolderDoesNotStopTheNewestOfTheOthers`.

```sh
swift build --package-path . --scratch-path .build/tests --target MailModelTests -Xswiftc -load-plugin-library -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
swift test --package-path . --scratch-path .build/tests --skip-build --filter 'Probe_R5BTests/r5b08_oneRefusedFolderDoesNotStopTheNewestOfTheOthers'
```

## Failure output
```
Expectation failed: s.messages.contains { $0.remoteID == "D1" && $0.mailbox == .drafts }
Drafts got nothing; 3 requests, status: Drafts: Access is denied. (ErrorAccessDenied)
```

## Fix idea
In `syncHistory` phase 1, `break` only for a sign-in failure, a `URLError` or a throttling `ServerBusy`. For other errors, skip that folder (`continue`) and let phase 2 report it.
