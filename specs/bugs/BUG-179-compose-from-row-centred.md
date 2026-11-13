---
title: 'Compose window: the "From:" row is centred instead of lined up with To, Cc and Subject'
priority: P4
area: UI / ComposeView
status: open
found: 2026-11-13
---
Draft id: R5E-02 (probe suites `Probe_R5*` in `probes/Probe_R5*Tests.swift`).

## Summary
With more than one account the compose window has a From: row. Its label and picker sit in the middle of the window, not in the label column (labels right-aligned at 92 pt, value after it) like To:, Cc:, Subject: and Message Size:. The wider the window, the further right it drifts.

## Expected
All header fields line up: label column, then the value at the left edge of the value column (as the other rows of the same `field()` helper do; Mail's compose header aligns them). Plain layout correctness.

## Repro
No probe: UI only. Snapshot:
```sh
defaults delete MailReplicaSnapshot; tools/snapshot.sh $PWD/tmp/e02.png MAIL_SNAPSHOT_SIZE=640x520 MAIL_SNAPSHOT_ANSWER=forward "MAIL_SNAPSHOT_SUBJECT=Photos from the weekend"
```
PNG: `specs/bugs/png/BUG-179-compose-from-row-centred.png` (crop: `…-crop.png`). Also visible at 700 pt wide in dark mode.

## Failure output
"From:" label at x≈189 pt and picker centred, while "To:", "Cc:", "Subject:" labels end at x≈103 pt.

## Fix idea
`ComposeView` From field: the picker is `.fixedSize()` so the row's `HStack` has no flexible child and is centred; add a `Spacer()` after the picker (as the Start:/End: rows do) or `.frame(maxWidth: .infinity, alignment: .leading)`.
