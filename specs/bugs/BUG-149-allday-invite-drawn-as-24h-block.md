---
title: 'All-day invite is drawn in the day column as a 24-hour hatched block from 0:00'
priority: P4
area: Invite
status: open
found: 2026-11-13
---
## Summary
For an all-day invite, the day column ignores `isAllDay`. It widens the grid to 0…24 and hatches the whole day as a timed slot, so the column starts at midnight and every hour is covered. All-day *events* go in the all-day row at the top instead.

## Repro
Harness: copy built with `./run.sh build`, stress messages added to `Sources/MailReplica/SampleData.swift` (see `stress-SampleData.diff` in this folder), run via `snap.sh` (binary copied to `MailReplicaProbe` so it reads its own defaults domain, `MAIL_SAMPLE_DATA=1`; no Mail.sqlite, no Exchange).
`Invite(start: tomorrow, end: at(24), isAllDay: true)`, subject "Stress all day". `snap.sh out.png MAIL_SNAPSHOT_SIZE=1280x800 "MAIL_SNAPSHOT_SUBJECT=Stress all day"`.

## Expected vs actual
- Bug: png/R4-UI-03-allday-invite-bug.png: the grid runs from 0, and a hatched block covers every hour.
- Control: png/R4-UI-03-allday-event-control.png: an all-day calendar event ("Company offsite week") is shown in the all-day row, and the grid starts at 8.
Expected: the all-day invite is marked in the all-day row (hatched there), and the grid keeps its 8–18 default.

## Why expected
The view's own rule for all-day entries (InviteView.swift:154-159, `allDay`), and Outlook's day view.

## Likely cause
Sources/MailReplica/InviteView.swift:170-175 and 198-203: `hours` and the `Hatch` slot use `invite.start/end` without checking `invite.isAllDay`.
