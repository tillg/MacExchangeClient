---
title: A move queued offline into a folder that is then deleted on the server makes the message vanish from the app; the status says "There is no  folder"
priority: P3
area: Outbox / folders
status: open
found: 2026-11-13
---

## Summary
Offline, the user moves a message from the Inbox to "Projects". Before the next launch "Projects" leaves the server's folder list: purged from Deleted Items (or Shift-Deleted), hidden, or renamed to a top-level "Archive" (it then has the Archive role, not `folder:` any more). (A plain Outlook delete only moves the folder into Deleted Items, where the move still succeeds.) At launch the queued move is sent first: `perform(.move)` reads the folder list, and `setRemoteFolders` treats "Projects" as removed and deletes its mail from the app, including the message that is only *locally* in it (its move never reached the server). On the app's usual launch path the folder list arrives while the stored mail beyond the Inbox is still loading, and `withoutRemovedFolders` drops the message from the loaded mail (and from disk) instead. Then the move fails ("no folder"), and `failed()` can't undo it because the message is gone. On the server the message is still in the Inbox, unchanged, so the Inbox's next delta check doesn't bring it back: it stays missing until that folder syncs from scratch. The status reads "Exchange refused a change: There is no  folder on the server" (blank name: the folder is no longer in the tree when the name is looked up).

Not covered by BUG-166 (there the folder list fails to load) nor by the limitations line "a deleted folder's mail goes then": this message is not in the deleted folder on the server.

## Expected
README: "If the server refuses a change, it is undone"; functional.md / d-bug-023: a refused move puts the mailbox back. Plain correctness: mail that is still on the server must not disappear from the app.

## Repro
`Tests/MailModelTests/Probe_R5LTests.swift`, `Probe_R5LTests/r5l01_moveQueuedIntoFolderDeletedOnServerKeepsTheMessage` (session 1 offline: Inbox synced, A1 moved to FX; relaunch against the loopback server whose folder list has no FX, then one empty Inbox delta check; second phase: the same launch with the folder list read while the stored mail is still loading, as `AppSetup.loadMail` does).
```sh
swift build --package-path W --scratch-path W/.build/tests --target MailModelTests -Xswiftc -load-plugin-library -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
swift test --package-path W --scratch-path W/.build/tests --skip-build --filter Probe_R5LTests/r5l01_moveQueuedIntoFolderDeletedOnServerKeepsTheMessage
```

## Failure output
```
Expectation failed: kept?.mailbox == .inbox
message A1 after the refused move: gone from the app; status: Exchange refused a change: There is no  folder on the server
Expectation failed: kept2?.mailbox == .inbox
loading path: message A1 gone from the app; status: Exchange refused a change: There is no  folder on the server
```

## Fix idea
In `MailStore.setRemoteFolders` and `withoutRemovedFolders` (loading path), don't remove messages of a gone folder that have a queued move into it (put them back to the move's `previous` mailbox and drop that outbox entry), or remove only messages whose server state is in that folder. Build the "no folder" text from the name before the tree changes.
