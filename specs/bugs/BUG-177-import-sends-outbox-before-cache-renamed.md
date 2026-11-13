---
title: "Importing Cache.json sends its waiting mail before the import is done; quitting then sends it twice"
priority: P2
area: storage
status: open
found: 2026-11-13
---
Draft id: R5C-07 (probe suites `Probe_R5*` in `probes/Probe_R5*Tests.swift`).

## Summary
`MailDatabase.importCache` calls `store.restore(cache)`, which calls `scheduleFlush()`. The outbox starts draining at once, while the database is still being written (31 s for a big cache, README) and `Cache.json` still has its old name. `saveBeforeSending` can't save the in-flight mark either, since `AppSetup.database` is still nil. If the user quits during "Updating Mail Storage…" after the send went out, the next launch imports `Cache.json` again ("Quit midway, and the next launch imports again") and sends the same message a second time. The normal launch path doesn't have this problem: `restore(meta)` sets `loadedBoxes`, which holds the outbox until all mail is loaded and the database is open.

## Expected
architecture/README: changes waiting for Exchange go out after loading; a send is "marked and saved before the request goes out: a quit or crash meanwhile can't send it twice" (`MailStore.drain`). Sending mail twice is a P1-class outcome; the trigger is rare (one-time import with a pending send).

## Repro
`Probe_R5CStorage/importSendsNothingWhileTheCacheCanStillBeImportedAgain`: a cache with 30,000 messages and one pending send; real EWSClient/EWSBackend against a loopback endpoint that notes, when the send arrives, whether `Cache.json` still exists.
`swift test --package-path . --scratch-path .build/tests --skip-build --filter Probe_R5CStorage/importSendsNothingWhileTheCacheCanStillBeImportedAgain`

## Failure output
```
Expectation failed: seen.value == false   (the send arrived while Cache.json was still there)
```

## Fix idea
`MailStore.restore(_ c: MailCache)`: don't call `scheduleFlush()` (or set `loadedBoxes = []` and finish loading after the import). Have `AppSetup.loadMail` start the flush once the import has returned and `database` is set.
