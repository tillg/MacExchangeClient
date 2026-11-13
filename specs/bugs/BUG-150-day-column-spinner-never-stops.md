---
title: 'Invite day column spins forever when the calendar can''t be loaded'
priority: P4
area: Invite
status: open
found: 2026-11-13
---
## Summary
`DayColumn` shows a spinner while `events == nil`. `loadDay` returns without setting `dayEvents` when the account has no backend or is paused, and when the request throws (it only sets `status`). The spinner then turns forever above an empty grid.

## Repro
Harness: copy built with `./run.sh build`, stress messages added to `Sources/MailReplica/SampleData.swift` (see `stress-SampleData.diff` in this folder), run via `snap.sh` (binary copied to `MailReplicaProbe` so it reads its own defaults domain, `MAIL_SAMPLE_DATA=1`; no Mail.sqlite, no Exchange).
Any sample invite without `setDayEvents` ("Stress all day", "Stress offsite three days"): `snap.sh out.png MAIL_SNAPSHOT_SIZE=1280x800 "MAIL_SNAPSHOT_SUBJECT=Stress all day"`. (With sample data the guard path is hit. On Exchange, the catch path behaves the same.)

## Expected vs actual
- Bug: png/R4-UI-05-day-spinner-bug.png: a spinner under the day header after loading has finished.
- Control: png/R4-UI-05-day-loaded-control.png: an invite whose events are set, without a spinner.
Expected: after a failed or impossible load, no spinner (an empty day, or a short "Calendar not available").

## Why expected
README: "the invite's day from your Exchange calendar next to the text". When it can't be fetched, the view shouldn't claim that it is still loading.

## Likely cause
Sources/MailModel/MailStore.swift:967-975 (`loadDay`): neither the early return nor the catch records an outcome. Sources/MailReplica/InviteView.swift:160-162 treats nil as "loading".
