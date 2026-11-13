---
title: 'A mail folder inside Contacts, Calendar or Tasks shows at the top level, and one named Archive becomes the account''s Archive'
priority: P4
area: EWS
status: open
found: 2026-11-13
---
Draft id: R5B-02 (probe suites `Probe_R5*` in `probes/Probe_R5*Tests.swift`).

## Summary
`folders()` keeps only `Folder` elements from FindFolder (`page.all("Folder")`). `ContactsFolder`, `CalendarFolder` and `TasksFolder` are dropped before `folderTree` and `archiveFolder` see the list. A mail folder whose parent is such a folder then has a parent "outside the result", so it counts as top-level. It shows in the sidebar although an ancestor isn't a mail folder. If it is called Archive, it becomes the account's Archive mailbox, and Archive (moves, ⌃⌘A) then files mail into a folder inside Contacts.

## Expected
ews.md › Folders: a user folder is "Kept if it and every ancestor has class `IPF.Note` or none". The same section also says "A parent outside the result means top level", but here the parent *is* in the FindFolder answer, only under another tag. Archive: "the top-level `FindFolder` result named archive". ⚠️ That Outlook lets you create "Mail and Post Items" folders inside Contacts or Calendar is recalled, not checked on the live server. The response shape is hand-written.

## Repro
Probe file: `Tests/MailModelTests/Probe_R5BTests.swift` (suite `Probe_R5BTests`), test(s) `r5b02_mailFolderInsideContactsIsNotShownOrTakenAsArchive`.

```sh
swift build --package-path . --scratch-path .build/tests --target MailModelTests -Xswiftc -load-plugin-library -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
swift test --package-path . --scratch-path .build/tests --skip-build --filter 'Probe_R5BTests/r5b02_mailFolderInsideContactsIsNotShownOrTakenAsArchive'
```

## Failure output
```
Expectation failed: !folders.contains { $0.id == "F1" || $0.id == "F2" }
["F1 as archive", "F2 as folder:F2"]
```

## Fix idea
In `EWSBackend.folders()`, collect every folder element (Folder, CalendarFolder, ContactsFolder, TasksFolder, SearchFolder) for the parent chain, and filter to `Folder` only for what is shown. `archiveFolder` should use the same full ID set to decide what is top-level.
