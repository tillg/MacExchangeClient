---
title: 'A picture attachment that can''t be loaded shows a spinner forever'
priority: P3
area: Attachments
status: open
found: 2026-11-13
---
## Summary
A picture attachment shows a placeholder with a spinner until its file is loaded. If loading fails (offline, server error, account paused, data not available, data that NSImage can't decode), `image` stays nil and the spinner keeps turning forever. The failure shows only as a status line under the window title.

## Repro
Harness: copy built with `./run.sh build`, stress messages added to `Sources/MailReplica/SampleData.swift` (see `stress-SampleData.diff` in this folder), run via `snap.sh` (binary copied to `MailReplicaProbe` so it reads its own defaults domain, `MAIL_SAMPLE_DATA=1`; no Mail.sqlite, no Exchange).
Message "Stress attachments": the last attachment, `zz-missing-photo.jpg`, has no local data (the data array is one short). `snap.sh out.png MAIL_SNAPSHOT_SIZE=1280x800 "MAIL_SNAPSHOT_SUBJECT=Stress attachments"`.

## Expected vs actual
- Bug: png/R4-UI-04-missing-picture-bug.png: a large grey box with a spinner. The title area already reads "Couldn't open “zz-missing-p…”", so the load has finished and failed.
- Control: png/R4-UI-04-loaded-picture-control.png: pictures with data (Mom's photos) show in place.
Expected: after a failure, show the file as its icon (as for other files), so it can be retried, opened or saved, and stop the spinner.

## Why expected
README: "Pictures appear in place, other files as their Finder icon with name and size". A spinner that never stops says "loading" for something that has already failed.

## Likely cause
Sources/MailReplica/AttachmentsView.swift:97-112 (`AttachmentPicture`): `image = nil`, and then it is set only on success. The `else` branch can't tell "loading" from "failed".
