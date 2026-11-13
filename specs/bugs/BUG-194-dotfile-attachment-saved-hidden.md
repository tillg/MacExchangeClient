---
title: "An attachment named \".something.pdf\" is saved as a hidden file the user can't find"
priority: P4
area: attachments
status: open
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
