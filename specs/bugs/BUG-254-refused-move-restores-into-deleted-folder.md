---
title: A refused move out of a folder deleted on the server puts the message back into that folder, where it is invisible but still in Flagged and search
priority: P3
area: Outbox / folders
status: open
found: 2026-11-13
---

## Summary
Offline, the user moves a (flagged) message from "Projects" to the Inbox. Before the next launch "Projects" is deleted for good on the server, with its mail. At launch the folder list no longer has "Projects"; the message isn't removed (it is locally in the Inbox). Exchange answers the move with `ErrorItemNotFound`, and `failed()` sets the message's mailbox back to `folder:FX`, a folder the account no longer has. The message is now a ghost: no sidebar row shows it, no sync ever reports it gone (the folder isn't synced any more), but it is counted and listed in Flagged and found by search, for good.

## Expected
Plain correctness (state consistency): every message belongs to a mailbox the account has. d-bug-077: "a folder that doesn't exist on the server has no mail" (its mail goes when the list says it is gone); an undo must not bring mail back into it. Like d-bug-074, a refused move must not leave a ghost that no later sync reports.

## Repro
`Tests/MailModelTests/Probe_R5LTests.swift`, `Probe_R5LTests/r5l02_refusedMoveOutOfFolderDeletedOnServerLeavesNoGhost`.
```sh
swift build --package-path W --scratch-path W/.build/tests --target MailModelTests -Xswiftc -load-plugin-library -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
swift test --package-path W --scratch-path W/.build/tests --skip-build --filter Probe_R5LTests/r5l02_refusedMoveOutOfFolderDeletedOnServerLeavesNoGhost
```

## Failure output
```
Expectation failed: ghosts.isEmpty
messages in a mailbox the account no longer has: ["A1 in folder:FX"]; Flagged count 1
```

## Fix idea
In `MailStore.failed(.move)`, if `old.mailbox` is a folder that is no longer in `folders[account]`, remove the message (and forget it) instead of restoring it; an `ErrorItemNotFound` refusal of a move means the item is gone anyway.
