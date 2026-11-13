---
title: 'Invite card shows only the start day for a meeting that ends on a later day'
priority: P3
area: Invite
status: open
found: 2026-11-13
---
## Summary
The invite card's "when" line is built from the start's date plus the start and end *times*. A meeting that ends on another day (three-day offsite, overnight deploy window) is shown as if it ended the same day.

## Repro
Harness: copy built with `./run.sh build`, stress messages added to `Sources/MailReplica/SampleData.swift` (see `stress-SampleData.diff` in this folder), run via `snap.sh` (binary copied to `MailReplicaProbe` so it reads its own defaults domain, `MAIL_SAMPLE_DATA=1`; no Mail.sqlite, no Exchange).
Invites: `Invite(start: at(9), end: at(2*24+17))` ("Stress offsite three days") and `Invite(start: at(22), end: at(26))` ("Stress night deploy").
`snap.sh out.png MAIL_SNAPSHOT_SIZE=1280x800 "MAIL_SNAPSHOT_SUBJECT=Stress offsite three days"` (and the night deploy subject).

## Expected vs actual
- Bug: png/R4-UI-01-multiday-bug.png: Saturday 9:00 to Monday 17:00 reads "Saturday, 14. November 2026 at 9:00 – 17:00".
- Bug: png/R4-UI-01-overnight-bug.png: 22:00 to 02:00 next day reads "Saturday, 14. November 2026 at 22:00 – 2:00" (looks like the meeting ends before it starts).
- Control: png/R4-UI-01-singleday-control.png: same-day invite, correct.
Expected: the end's date when it differs, as Outlook writes it ("Sat 14.11.2026 09:00 – Mon 16.11.2026 17:00").

## Why expected
README: invites show "when and where … as in Outlook". The card is the only place the user sees the meeting's length before answering.

## Likely cause
Sources/MailReplica/InviteView.swift:71-76 (`when`): `day` comes from `invite.start` only and the end is formatted with `date: .omitted`. The all-day branch has the same issue: a multi-day all-day invite says "<first day>, all day".
