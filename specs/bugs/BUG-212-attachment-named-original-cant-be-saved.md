---
title: "An attachment named \"Original\" can't be saved once an app has changed the opened copy"
priority: P4
area: attachments
status: open
found: 2026-11-13
---

## Summary
Save and Forward use the attachment as it came (d-bug-133): when the opened file in Mail Downloads/<message>/<index>/ was changed by an app, the content is fetched again into `<index>/Original/<name>`. For an attachment whose name is "Original" (any case on APFS, no extension) that folder path is the opened file itself, so `createDirectory` fails: Save says "Couldn't open “Original”: The file “Original” couldn’t be saved in the folder “0” because a file with the same name already exists." and nothing is saved; Forward can't include it.

## Expected
Plain correctness: d-bug-133 promises Save/Forward work after an edit; a file name must not collide with the app's own folder.

## Repro
Probe `Probe_R5I_Attachments/attachmentNamedOriginalCanBeSavedAfterAnEdit` in `Tests/MailModelTests/Probe_R5ITests.swift`:

```sh
swift test --package-path . --scratch-path .build/tests --skip-build --filter Probe_R5I_Attachments/attachmentNamedOriginalCanBeSavedAfterAnEdit
```
(after the test build from CLAUDE.md)

## Failure output
```
Expectation failed: saved != nil
  Couldn't open “Original”: The file “Original” couldn’t be saved in the folder “0” because a file with the same name already exists.
```

## Fix idea
In `MailStore.attachmentFile`, put the fresh copy beside the index folder (e.g. `<message>/<index>-original/`) instead of inside the folder that holds the opened file.
