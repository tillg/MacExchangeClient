---
title: 'Delete in a folder inside Trash moves the mail to Trash instead of erasing it'
priority: P4
area: MailStore / actions
status: open
found: 2026-11-13
---
Draft id: R5A-05 (probe suites `Probe_R5*` in `probes/Probe_R5*Tests.swift`).

## Summary
Exchange keeps deleted folders in Deleted Items, and their mail counts as deleted (d-bug-025). Delete on a message in such a folder moves it to Trash itself, because `delete` erases only `mailbox == .trash`. The user has to delete it a second time in Trash, and an extra move is sent to the server. ⚠️ The rule in functional.md ("Messages in Trash are erased") doesn't name subfolders. Expecting the subfolder to count as Trash here follows from d-bug-025 and from Outlook (permanent delete in Deleted Items' subfolders), not from a written rule.

## Expected
DECISIONS d-bug-025 ("Mail in a deleted folder is deleted mail") and README ("deleting from Trash erases"). ⚠️ Outlook's behaviour from memory.

## Repro
Probe: `deleteInAFolderInsideTrashErases` in `Tests/MailModelTests/Probe_R5ATests.swift`.

```
swift build --package-path W --scratch-path W/.build/tests --target MailModelTests -Xswiftc -load-plugin-library -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
swift test --package-path W --scratch-path W/.build/tests --skip-build --filter Probe_R5A/deleteInAFolderInsideTrashErases
```

## Failure output
```
Expectation failed: s.message(m.id)?.mailbox.rawValue == nil
s.message(m.id)?.mailbox.rawValue → "trash"
```

## Fix idea
In `MailStore.delete`, erase when `isDeleted(m)` (Trash or a folder inside it), not only when `mailbox == .trash`.
