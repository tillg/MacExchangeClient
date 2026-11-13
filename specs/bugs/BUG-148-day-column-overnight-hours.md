---
title: 'Day column of an overnight invite starts at 2 o''clock and the invite''s slot is outside the grid'
priority: P4
area: Invite
status: open
found: 2026-11-13
---
## Summary
The day column's hour range takes the hour of every time, including an end time on the *next* day. For an invite from 22:00 to 02:00, the range becomes 2…22: the column starts at 2 o'clock (the night before the work day), and the invite's own hatched slot (22:00 to 24:00) is drawn below the grid's last hour, past the column's frame.

## Repro
Harness: copy built with `./run.sh build`, stress messages added to `Sources/MailReplica/SampleData.swift` (see `stress-SampleData.diff` in this folder), run via `snap.sh` (binary copied to `MailReplicaProbe` so it reads its own defaults domain, `MAIL_SAMPLE_DATA=1`; no Mail.sqlite, no Exchange).
`Invite(start: at(22), end: at(26))`, subject "Stress night deploy". `snap.sh out.png MAIL_SNAPSHOT_SIZE=1280x800 "MAIL_SNAPSHOT_SUBJECT=Stress night deploy"`.

## Expected vs actual
- Bug: png/R4-UI-02-overnight-column-bug.png: the grid starts at "2" and the visible area shows no hatched slot.
- Control: png/R4-UI-02-sameday-column-control.png: a same-day invite (12:30–13:00): the grid starts at 8 and the slot is hatched in place.
I couldn't take a screenshot of the bottom of the column: the window is limited to the screen height and the card scrolls. The slot's position comes from the code: `y(start)` = (22−2)·44 = 880 pt and `y(end)` = (24−2)·44, while the grid frame is (22−2)·44 + 8 pt high, so the slot falls outside the frame and the scroll content.
Expected: the range should include 22–24 (end clamped to 24 when it is on a later day), for example 8…24.

## Why expected
README: "the invite's day from your Exchange calendar next to the text … the invite's slot hatched".

## Likely cause
Sources/MailReplica/InviteView.swift:170-175 (`hours`): `cal.component(.hour, from:)` is applied to `invite.end` (and to event times) without checking that it is on the same day. `y()` (177-182) already clamps other-day times to 0/24, but `hours` doesn't.
