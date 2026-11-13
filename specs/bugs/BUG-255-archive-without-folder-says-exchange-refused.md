---
title: Archive in an Exchange account without an Archive folder moves the message, then jumps it back with "Exchange refused a change", though nothing was sent
priority: P4
area: MailStore / actions
status: open
found: 2026-11-13
---

## Summary
ews.md: "with no top-level one [Archive folder] the account has no Archive". The sidebar, the Archive toolbar button, ⌃⌘A, the context menu and the Move menu still offer Archive for such an account. Archive moves the message out of the list (and selects the next one); then `perform(.move)` finds no `.archive` folder and throws a `MailError`, which `drain` treats like a server refusal: the message jumps back and the status says "Exchange refused a change: There is no Archive folder on the server". No request was sent (the server served 0), so Exchange refused nothing; the app knew before moving that the account has no Archive.

## Expected
Plain correctness of the status: README "If the server refuses a change, it is undone" is about server refusals; a change that is never sent can't have been refused (the same point as BUG-166). ⚠️ From memory of Mail: Archive in an account without an archive mailbox either creates one or isn't offered; it doesn't move mail out and back.

## Repro
`Tests/MailModelTests/Probe_R5LTests.swift`, `Probe_R5LTests/r5l03_archiveWithoutArchiveFolderIsNotReportedAsRefusedByExchange`.
```sh
swift build --package-path W --scratch-path W/.build/tests --target MailModelTests -Xswiftc -load-plugin-library -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
swift test --package-path W --scratch-path W/.build/tests --skip-build --filter Probe_R5LTests/r5l03_archiveWithoutArchiveFolderIsNotReportedAsRefusedByExchange
```

## Failure output
```
Expectation failed: s.status?.contains("Exchange refused") != true
status: Exchange refused a change: There is no Archive folder on the server; requests sent: 0
```

## Fix idea
In `MailStore.move`/`archive`, leave out messages of server accounts whose known folder list has no `.archive` (status "“Exchange” has no Archive mailbox"), and disable Archive for them in `MessageViewer`/`MailCommands`. (Creating the folder belongs to create-sub-inbox.md.)
