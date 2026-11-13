---
title: "Clicking a mailbox while \"Loading Mail…\" reads the database starts the history sync early; mail deleted on the server while the app was closed then stays forever"
priority: P3
area: Launch
status: open
found: 2026-11-13
---
Draft id: R5G-05 (probe suites `Probe_R5*` in `probes/Probe_R5*Tests.swift`).

## Summary
`loadMail` first reads meta and the Inboxes in a detached task. Until `restore(meta)` runs, `loadedBoxes` is nil, so the store doesn't know launch is loading. A mailbox clicked meanwhile makes `SidebarView` call `refresh()`, whose `startHistory()` passes its `loadedBoxes == nil` guard: the history starts with no sync positions and syncs folders from the start. `restore(meta)` then sets the stored token and `complete` mark (the history hadn't applied its first batch yet). When the batch is applied, `startPassIfFromScratch` sees a token, so the pass isn't treated as from the start: nothing is pruned, the folder stays complete at the pass's token, and the stored token (which would have reported the deletions) is gone. A message deleted on the server while the app was closed stays in the mailbox.

## Expected
architecture.md, Start-up: `finishLoading` "allows flushing and starts the history sync"; while loading, the quick check covers only mailboxes already in memory. A complete sync from the start is authoritative for its folder (d-bug-053): what it doesn't list goes.

## Repro
`EWSFlowTests/Probe_R5GRaces/aCheckBeforeTheStoredStateIsReadLeavesDeletedMail` (held loopback server; the stored Inbox holds R1 and R2, the server only R1):
```
swift test --package-path W --scratch-path W/.build/tests --skip-build --filter Probe_R5GRaces/aCheckBeforeTheStoredStateIsReadLeavesDeletedMail
```

## Failure output
```
Expectation failed: !stuck
R2 stays; inbox token P2, complete true
```

## Fix idea
Mark the store as loading from the start when it has stored mail to load (e.g. `MailStore.beginLoading()` called by `loadMail` before the detached read, setting `loadedBoxes = []`), so `startHistory`/`scheduleFlush`/`quickCheckRoles` wait as they do after `restore(meta)`.
