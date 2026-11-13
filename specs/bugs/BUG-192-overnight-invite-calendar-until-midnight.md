---
title: "An invite that runs past midnight reads the calendar only until midnight: conflicts after 00:00 are never shown"
priority: P3
area: invites
status: open
found: 2026-11-13
---
Draft id: R5D-08 (probe suites `Probe_R5*` in `probes/Probe_R5*Tests.swift`).

## Summary
`MailStore.loadDay` asks the calendar for `[startOfDay(invite.start), +1 day)`. For a meeting 22:00–02:00 (or a multi-day offsite) entries after midnight are never fetched, so `Invite.conflicts` can't see them: no conflict note though the user is busy, and the day column (which `DayLayout.hours` already widens to 24 h for an overnight end) shows nothing there.

## Expected
functional.md Meeting invites: "a yellow conflict note when timed, non-free calendar events overlap"; BUG-142/148 made overnight invites a supported case (when line, 24 h column).

## Repro
Probe `Probe_R5D_Invites/overnightInviteReadsTheCalendarUntilItsEnd` in `Tests/MailModelTests/Probe_R5DTests.swift`:

```sh
swift test --package-path . --scratch-path .build/tests --skip-build --filter Probe_R5D_Invites/overnightInviteReadsTheCalendarUntilItsEnd
```
(after the test build from CLAUDE.md)

## Failure output
```
Expectation failed: askedEnd >= end
calendar read until 2026-11-20T23:00:00Z; the meeting ends at 2026-11-21T01:00:00Z
```

## Fix idea
In `MailStore.loadDay`, set `to = max(startOfDay+1 day, invite.end)` (and for conflicts at least cover `invite.start..<invite.end`).
