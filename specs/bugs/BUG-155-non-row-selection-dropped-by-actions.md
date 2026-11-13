---
title: 'After a reply arrives in the open conversation, flagging, marking or swiping its row clears the selection'
priority: P2
area: MailStore / conversations
status: open
found: 2026-11-13
---
Draft id: R5A-02 (probe suites `Probe_R5*` in `probes/Probe_R5*Tests.swift`).

## Summary
With conversations on: open a message, and a reply arrives in its conversation. The row now stands for the reply, but `selection` still holds the older message (by design, `listSelection` maps it to the row). `keepingSelectionVisible` compares that raw selection with the list's row IDs, so the selected message always counts as having left the list. Then:
- Flag, Clear Flag, Mark as Read/Unread (menu, toolbar, swipe, context menu) on the conversation, which stays in the list, clear the selection, and the message pane goes blank.
- Swipe > Trash, or context menu Delete/Archive/Junk, on that row leaves nothing selected instead of the next row.
The same happens after picking an older message in search results and clearing the search.

## Expected
functional.md "No hidden selection": "A selected message that stays in the list stays selected"; "Read/unread and flag changes don't move the selection"; after a delete or move "the next message is selected". README: actions on the row act on all its messages, and the row stays selected when a reply arrives (`aReplyArrivingKeepsTheConversationSelected`).

## Repro
Probe: `flaggingTheOpenConversationAfterAReplyArrivedKeepsItSelected, swipeDeleteOfRowWhoseOlderMessageIsSelectedSelectsNextRow` in `Tests/MailModelTests/Probe_R5ATests.swift`.

```
swift build --package-path W --scratch-path W/.build/tests --target MailModelTests -Xswiftc -load-plugin-library -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
swift test --package-path W --scratch-path W/.build/tests --skip-build --filter Probe_R5A/flaggingTheOpenConversationAfterAReplyArrivedKeepsItSelected
```

## Failure output
```
flaggingTheOpenConversationAfterAReplyArrivedKeepsItSelected: Expectation failed: s.listSelection == [row]
s.listSelection → []

swipeDeleteOfRowWhoseOlderMessageIsSelectedSelectsNextRow: Expectation failed: s.selection == [other]
s.selection → []
```

## Fix idea
In `keepingSelectionVisible`, use `listSelection` (rows) for `before`/`gone`/`following`, as `actOnSelection` and `drop` already do.
