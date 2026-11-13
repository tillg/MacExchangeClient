---
title: 'Turning conversations off with the unread filter on keeps an opened conversation''s other messages in the list, read and unselected'
priority: P4
area: MailStore / Viewing settings
status: open
found: 2026-11-13
---

## Summary
With conversations and the unread filter on, opening a conversation row marks all its messages read and notes them as opened (`openedUnread`), so the row stays. Turning "Show messages as conversations" off (Settings ▸ Viewing) leaves `openedUnread` as it is: the list now shows each of those messages as its own row, all read, though only the newest is selected. They stay until the selection moves on.

## Expected
functional.md › Message list: a message unread when opened "stays in the list with the unread filter … while it is selected. It leaves once the selection moves on, the filter is toggled or another mailbox is selected"; the unselected members are not selected once rows are single messages.

## Repro
Probe `Probe_R5MStore/turningConversationsOffLetsGoOfUnselectedReadMessages` in `Tests/MailModelTests/Probe_R5MTests.swift`.

```
swift build --package-path W --scratch-path W/.build/tests --target MailModelTests -Xswiftc -load-plugin-library -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
swift test --package-path W --scratch-path W/.build/tests --skip-build --filter Probe_R5MStore/turningConversationsOffLetsGoOfUnselectedReadMessages
```

## Failure output
```
Expectation failed: !list.contains("Re: Plan") && !list.contains("Re: Re: Plan")
read, unselected messages listed under the unread filter: ["Plan", "Re: Plan", "Re: Re: Plan", "Other"], selected ["Plan"]
```

## Fix idea
In `MailStore.groupsConversations` didSet, intersect `openedUnread` with the (new) `withConversations(selection)`, as `selection`'s didSet does.
