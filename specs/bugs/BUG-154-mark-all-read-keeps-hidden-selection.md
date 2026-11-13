---
title: 'Mark All as Read with the unread filter (or in Unread) leaves the selected messages selected after they leave the list'
priority: P3
area: MailStore / selection
status: open
found: 2026-11-13
---
Draft id: R5A-01 (probe suites `Probe_R5*` in `probes/Probe_R5*Tests.swift`).

## Summary
With the unread filter on, select several unread messages (a multi-selection isn't opened, so not marked read), then Mailbox > Mark All Messages as Read. The messages leave the list but stay selected. The toolbar actions stay enabled, and a following Delete or Archive acts on mail the user no longer sees (in Trash, Delete erases it unseen). Mark as Read and Clear Flag were fixed for this in BUG-119; `markAllRead` calls `update` directly, without `keepingSelectionVisible`.

## Expected
README "Message actions": "a message that leaves the list (also by ... Mark as Read ... while only unread or flagged mail is shown) never stays selected, so a second Delete can't erase it from Trash unseen"; functional.md "No hidden selection"; DECISIONS d-bug-119.

## Repro
Probe: `markAllReadDoesNotKeepHiddenMessagesSelected` in `Tests/MailModelTests/Probe_R5ATests.swift`.

```
swift build --package-path W --scratch-path W/.build/tests --target MailModelTests -Xswiftc -load-plugin-library -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
swift test --package-path W --scratch-path W/.build/tests --skip-build --filter Probe_R5A/markAllReadDoesNotKeepHiddenMessagesSelected
```

## Failure output
```
Expectation failed: s.selection.isSubset(of: visible)
selection 2 hidden after Mark All as Read
s.selection → [3E4D…, 612B…]
visible → []
```

## Fix idea
Wrap the `update` in `markAllRead(in:)` in `keepingSelectionVisible(ids, selectNext: false)`, as `toggleRead` does.
