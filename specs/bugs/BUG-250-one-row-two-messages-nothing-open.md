---
title: 'Two results of one conversation selected in a search become one selected row after clearing it, but nothing opens ("2 messages selected", Reply disabled)'
priority: P4
area: MailStore / search, conversations
status: open
found: 2026-11-13
---

## Summary
While searching, the list isn't grouped, so two messages of the same conversation can be selected together. When the search is cleared the list is grouped again: `listSelection` maps both to the conversation's row, so one row is highlighted, but `selection` still holds two messages. `selectedMessage` is nil, the message pane shows "2 messages selected", Reply/Forward are disabled and the row isn't marked read.

## Expected
README › Conversations: "In the list a conversation is one row" and opening the row shows its messages in the message pane; functional.md: selecting exactly one (row) opens it. Plain consistency: one highlighted row, one open conversation.

## Repro
Probe `Probe_R5MStore/oneSelectedRowAfterClearingTheSearchOpensIt` in `Tests/MailModelTests/Probe_R5MTests.swift`.

```
swift build --package-path W --scratch-path W/.build/tests --target MailModelTests -Xswiftc -load-plugin-library -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
swift test --package-path W --scratch-path W/.build/tests --skip-build --filter Probe_R5MStore/oneSelectedRowAfterClearingTheSearchOpensIt
```

## Failure output
```
Expectation failed: rows != 1 || open != nil
list shows 1 selected row, but selection holds 2 messages and nothing is open
```

## Fix idea
When grouping resumes (search cleared, `groupsConversations` turned on), collapse `selection` to `listSelection` (one ID per row), or have `selectedMessage` treat a selection that is one row as that row.
