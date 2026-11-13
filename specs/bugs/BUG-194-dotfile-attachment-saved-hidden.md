---
title: "An attachment named \".something.pdf\" is saved as a hidden file the user can't find"
priority: P4
area: attachments
status: deferred
found: 2026-11-13
---
Draft id: R5D-10 (probe suites `Probe_R5*` in `probes/Probe_R5*Tests.swift`).

## Summary
`Attachment.fileName` keeps a leading dot, so Save/Save All write `.invoice.pdf` into the chosen folder, where the Finder hides it: the save looks like it did nothing.

## Expected
Plain correctness: a file the user just saved must be visible where they saved it. ⚠️ Mail strips the leading dot (recalled).

## Repro
Probe `Probe_R5D_Attachments/savedAttachmentIsNotHidden` in `Tests/MailModelTests/Probe_R5DTests.swift`:

```sh
swift test --package-path . --scratch-path .build/tests --skip-build --filter Probe_R5D_Attachments/savedAttachmentIsNotHidden
```
(after the test build from CLAUDE.md)

## Failure output
```
Expectation failed: hidden == false
saved as .invoice.pdf, hidden in the Finder
```

## Fix idea
In `Attachment.fileName`, drop leading dots (fall back to "Attachment" when nothing is left).

## Deferred (2026-11-13)
The fix (drop leading dots) conflicts with the existing test `MailStoreTests.openedAttachmentsAreFilesInTheDownloadsFolder`,
which expects "../../etc" to be saved as "..:..:etc" — itself a name the Finder hides. Existing tests aren't changed
without the user's permission, so this waits for a decision: is "..:..:etc" the intended name, or should leading dots
go (and that test change)? See DECISIONS.md run-2026-11-13-1235-8.
