---
title: 'Invite: the fixed 300 pt day column squeezes the message text to a few words per line'
priority: P4
area: UI / InviteView
status: open
found: 2026-11-13
---
Draft id: R5E-04 (probe suites `Probe_R5*` in `probes/Probe_R5*Tests.swift`).

## Summary
An invite shows its text beside a day column that is always 300 pt wide. At the minimum window width (900 pt) the message pane is about 440 pt, leaving the text about 100 pt: "Let's go through / the Q4 numbers / before the board / meeting." The calendar keeps its full width while the mail itself becomes hard to read.

## Expected
The message text stays readable: the day column narrows (or moves below the text) when the pane is narrow. Plain layout correctness (the column is secondary information; README: invite day column is ⚠️ estimated, no fixed width is sourced).

## Repro
No probe: UI only. Snapshot:
```sh
defaults delete MailReplicaSnapshot; tools/snapshot.sh $PWD/tmp/e05.png MAIL_SNAPSHOT_SIZE=900x500 "MAIL_SNAPSHOT_SUBJECT=Q4 numbers review"
```
PNG: `specs/bugs/png/BUG-181-invite-text-squeezed.png`.

## Failure output
Body text column about 100 pt wide, 3 words per line; day column 300 pt.

## Fix idea
`MessageContent` (invite branch): give `DayColumn` a flexible width (`.frame(minWidth: 180, idealWidth: 300, maxWidth: 300)`) and the text a `layoutPriority(1)`, or stack them vertically below a pane width (`ViewThatFits`).
