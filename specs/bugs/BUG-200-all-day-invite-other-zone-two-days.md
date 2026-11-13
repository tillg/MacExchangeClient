---
title: "An all-day invite from a colleague in another time zone (London, New York, Tokyo) is shown as two days, or the wrong day"
priority: P3
area: invites / EWS
status: open
found: 2026-11-13
---
Draft id: R5H-02 (probe suites `Probe_R5*` in `probes/Probe_R5*Tests.swift`).

## Summary
Exchange sends an all-day meeting's Start/End as the organizer's midnights in UTC. The app reads only `Start`, `End` and `IsAllDayEvent` and puts them on the Mac's calendar, so a one-day all-day meeting from London (00:00Z–00:00Z, i.e. 01:00–01:00 in Berlin) reads "Friday, 20 November 2026 – Saturday, 21 November 2026, all day". From Tokyo it starts on Thursday. The day column / conflicts use the same shifted day.

## Expected
One all-day day: "Friday, 20 November 2026, all day" (`Invite.when` doc and functional.md: "an all-day invite as its first – last day"). EWS: all-day items are midnights in the item's `StartTimeZone`/`EndTimeZone` (MS docs, CalendarItem/MeetingRequest), which the request never asks for.

## Repro
Probe `Probe_R5H_Dates/allDayInviteFromAnotherZoneIsOneDay` in `Tests/MailModelTests/Probe_R5HTests.swift`:
```sh
swift test --package-path . --scratch-path .build/tests --skip-build --filter Probe_R5H_Dates/allDayInviteFromAnotherZoneIsOneDay
```

## Failure output
```
Expectation failed: when == "Friday, 20 November 2026, all day"
when line: Friday, 20 November 2026 – Saturday, 21 November 2026, all day
```

## Fix idea
Ask for `calendar:StartTimeZone` (or `StartTimeZoneId`, Exchange 2010+) in `EWSBackend.inviteProps`; for all-day items keep the calendar day in that zone (store start/end as local midnights of those dates) before `Invite.when`/`loadDay` use them.
