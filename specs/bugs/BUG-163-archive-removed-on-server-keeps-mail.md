---
title: 'An Archive folder deleted on the server keeps its mail and sync position in Archive for good'
priority: P3
area: Sync
status: open
found: 2026-11-13
---
Draft id: R5B-03 (probe suites `Probe_R5*` in `probes/Probe_R5*Tests.swift`).

## Summary
`setRemoteFolders` treats as gone only the folders of the account's tree (`folders[account]`), which holds the user's own folders and never the standard roles. When the server's folder list no longer has an Archive (the folder was deleted, or emptied from Deleted Items), Archive keeps its old mail, in counts, Flagged and search, and keeps its sync token. Nothing syncs it again, because `remoteFolders` has no Archive, so the mail stays even after relaunches.

## Expected
d-bug-077: "A folder of the account's tree ... that the new folder list doesn't have is gone: its messages are removed (memory and disk), its sync token, completion and history notes are dropped". limitations.md: folders deleted elsewhere: "a deleted folder's mail goes then" (after a relaunch). Plain correctness: mail of a folder that doesn't exist is shown.

## Repro
Probe file: `Tests/MailModelTests/Probe_R5BTests.swift` (suite `Probe_R5BTests`), test(s) `r5b03_archiveRemovedOnTheServerTakesItsMailWithIt`.

```sh
swift build --package-path . --scratch-path .build/tests --target MailModelTests -Xswiftc -load-plugin-library -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
swift test --package-path . --scratch-path .build/tests --skip-build --filter 'Probe_R5BTests/r5b03_archiveRemovedOnTheServerTakesItsMailWithIt'
```

## Failure output
```
Expectation failed: s.count(.account(acct.id, .archive)) == 0
Archive still shows the mail of a folder the server no longer has as Archive
s.count(.account(acct.id, .archive)) → 1
Expectation failed: s.syncToken(acct.id, .archive) == nil
s.syncToken(acct.id, .archive) → "TA"
```

## Fix idea
In `MailStore.setRemoteFolders`, compute `gone` from the previous remote roles (`remoteFolders[account]`, or the stored tree plus `.archive` when the account had one) as well as from the tree, so a vanished `.archive` is cleared like a user folder.
