---
title: "Toggle Flag (⇧⌘L, toolbar Flag button) on a selection of ~140 messages freezes the window for seconds: each selected message is looked up by a scan of all messages"
priority: P3
area: MailStore
status: open
found: 2026-11-13
---
Draft id: R5G-01 (probe suites `Probe_R5*` in `probes/Probe_R5*Tests.swift`).

## Summary
Message ▸ Toggle Flag (`MailCommands.swift:69`) and the toolbar Flag button's primary action (`MessageViewer.swift:195`, `FlagMenu`) decide flag vs. unflag with `store.withConversations(store.selection).contains { store.message($0)?.flag != nil }`. `MailStore.message(_:)` is `messages.first { $0.id == id }`, a linear scan of all 180,000 messages. When nothing selected is flagged, `contains` runs it for every selected message. Mail loaded late in the array (folders read after the Inbox at launch, mail arriving this session) costs a full scan each. Select All in a 140-message folder and press ⇧⌘L: seconds, while Flag ▸ Red on the same selection takes 0.2 s.

## Expected
Under the repo's budget of 0.25 s per user action in a debug build (`MailStorePerformanceTests.limit`). functional.md: "Toggle Flag (⇧⌘L) | Clears the flag if any selected message is flagged, else flags red".

## Repro
`Probe_R5GFindings/toggleFlagOnASelectionStaysInBudget` (180,000 messages, 300 folders, Perf4 fixture; Select All of the last-loaded folder, unflagged messages only):
```
swift test --package-path W --scratch-path W/.build/tests --skip-build --filter Probe_R5GFindings/toggleFlagOnASelectionStaysInBudget
```
The probe runs the commands' expression through the public store API.

## Failure output
```
R5G Flag menu ▸ Red on the same 139 + redraw (control): 0.208s
R5G Toggle Flag on 139 selected + redraw: 7.389s
Expectation failed: toggle < F.limit   (toggle → 7.389149917, F.limit → 0.25)
```
(Machine busy with other test runs; an earlier quieter run: 1.22 s for 140, 5.7 s for 900 selected in Junk.)

## Fix idea
Give `MailStore` one-pass helpers (e.g. `anyFlagged(_ ids:)`, one pass over `messages`) and use them in `MailCommands` and `FlagMenu`; or make `message(_:)` use an ID→index map cached per `revision` (like `selectedCache`), which also turns this probe green.
