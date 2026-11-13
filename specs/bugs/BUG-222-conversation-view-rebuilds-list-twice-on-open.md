---
title: "With conversations on (the default), opening the next unread message in a large mailbox rebuilds the list twice: 0.37-0.94 s per click in Archive (30,000)"
priority: P3
area: MailStore
status: open
found: 2026-11-13
---
Draft id: R5G-02 (probe suites `Probe_R5*` in `probes/Probe_R5*Tests.swift`).

## Summary
"Show messages as conversations" is on by default (`@AppStorage("showConversations") = true` → `groupsConversations`). Clicking an unread message after having opened another unread one runs `selection.didSet` (which shrinks `openedUnread`) and `markSelectionRead`. `markSelectionRead` calls `withConversations(selection)` → `threads` → `visibleMessages`. Because `openedUnread` (part of `ListKey`) just changed, this builds the whole grouped list (filter of 180,000 + sort + grouping) only to read the conversation members. Then `update` changes the message and `openedUnread.formUnion` changes the key again, so the redraw builds the list a second time. Without conversations, `threads` returns early and the list is built once.

## Expected
Under 0.25 s per user action (debug build, `MailStorePerformanceTests.limit`); one list build per click.

## Repro
`Probe_R5GFindings/openingUnreadInConversationViewStaysInBudget`:
```
swift test --package-path W --scratch-path W/.build/tests --skip-build --filter Probe_R5GFindings/openingUnreadInConversationViewStaysInBudget
```

## Failure output
Quiet-ish run: conversations 0.373 s, flat 0.237 s. Busy run with the split:
```
R5G one list rebuild of Archive, grouped (control): 0.304s
R5G open next unread: conversations 0.938s, flat 0.626s; before the redraw: conversations 0.497s, flat 0.043s
Expectation failed: grouped < F.limit   (grouped → 0.937778292, F.limit → 0.25)
```
Selection + `markSelectionRead` alone: 0.043 s flat vs 0.497 s grouped, i.e. one extra list build before the redraw.

## Fix idea
`MailStore.markSelectionRead` (and `selection.didSet`): take the conversation members from the existing `threadCache` without rebuilding the list for the new key (e.g. read `threadCache` when its revision matches, ignoring `openedUnread`), or apply the `openedUnread` change first and read the list once.
