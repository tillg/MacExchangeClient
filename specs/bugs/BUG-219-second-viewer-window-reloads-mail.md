---
title: "New Viewer Window loads the mail database into the running app again: an unsaved queued send is no longer saved, a send on its way is reported as interrupted"
priority: P2
area: MailReplicaApp
status: open
found: 2026-11-13
---
Draft id: R5F-02 (probe suites `Probe_R5*` in `probes/Probe_R5*Tests.swift`).

## Summary
`MailReplicaApp` puts `.task { await pollForMail() }` on the viewer window's content (MailReplicaApp.swift:25). SwiftUI runs that task once per window, and `pollForMail` starts with `AppSetup.loadMail(into: store)` (then its own 15 s poll loop). File ▸ New Viewer Window (⌥⌘N) therefore loads the database into the store that already holds everything, and `restore(meta)` acts as at launch:
- It resets the change marks (`outboxChanged = interrupted`, `foldersChanged = false`). A message sent while offline or without a password in the seconds since the last save (the poll saves every 15 s) is then left out of the next save: it is only in memory, and quitting before another outbox change loses it.
- A send on its way right now was saved marked in flight by `saveBeforeSending`; `restore(meta)` reads that mark as "the app quit while sending": it copies the message to Drafts and says "“…” may already have been sent: the app quit while sending it. … check Sent before sending it again."
- It appends the stored outbox again: every waiting change is queued twice (same IDs; a successful drain removes both, so nothing goes out twice). `loadedBoxes = []` makes the store "loading" again, and a second poll loop doubles the server checks.

## Expected
Loading stored mail happens once per launch (`AppSetup.loadMail` doc: "Loads stored mail in stages"; architecture: launch steps 1-3). Plain correctness: opening a window must not change mail state or report a send as interrupted.

## Repro
The task runs once per viewer window: view harness (the same `.task` modifier on `MessageViewer` in a mirror of MailReplicaApp's scenes, sample data), `specs/bugs/probes-views/run-harness.sh two-viewers` → "R5F FAIL: expected loadMail/pollForMail to start once per app, got the window task started 2 times".

The effect on the store: `swift test --package-path W --scratch-path W/.build/tests --skip-build --filter Probe_R5F_Windows` (file `Tests/MailModelTests/Probe_R5FTests.swift`). The tests run the same three calls `AppSetup.loadMail` makes (AccountsSettings.swift:34-46) a second time, as the new window's task does; the in-flight test uses a held loopback server so the send stays on its way.

## Failure output
```
Test secondViewerWindowKeepsAnUnsavedSendForTheNextSave() recorded an issue: Expectation failed: saved.count == 1
  the next save writes 0 outbox entries; the queued send is only in memory
Expectation failed: onDisk == 1
  on disk after the next save: 0 outbox entries
Test secondViewerWindowDuringASendDoesNotReportAnInterruptedSend() recorded an issue: Expectation failed: copies.isEmpty
  a message being sent was copied to [drafts] by the second window's loadMail
Expectation failed: s.status == nil
  status: “Quarterly report” may already have been sent: the app quit while sending it. It's in Drafts on this Mac; check Sent before sending it again.
Test secondViewerWindowDoesNotDuplicateTheOutbox() recorded an issue: Expectation failed: sendsAfter == 1
  the waiting send is queued 2 times after a second viewer window opened
```
(The doubled send has the same ID; a successful drain removes both copies, so it isn't sent twice.)

## Fix idea
Both: start `loadMail` and the poll loop once per app (a static flag in `AppSetup`, or from `App.init`/the delegate), and make `MailStore.restore(_ meta:)` safe to call on a loaded store (skip outbox entries whose ID is already queued, don't treat a send still in memory as interrupted, OR the change marks instead of overwriting them). The probes call the load sequence twice themselves, so they pass only with the store-side part.
