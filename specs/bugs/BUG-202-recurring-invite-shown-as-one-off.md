---
title: "A recurring meeting's invite is shown as a one-off meeting: nothing says it repeats"
priority: P3
area: invites / EWS
status: open
found: 2026-11-13
---
Draft id: R5H-04 (probe suites `Probe_R5*` in `probes/Probe_R5*Tests.swift`).

## Summary
`EWSBackend.inviteProps` asks only Start, End, Location, IsAllDayEvent, Organizer and attendees. For a weekly series the card shows just the first occurrence's date and time ("Monday, 23 November 2026 at 10:00 – 11:00"); accepting answers the whole series, which the user can't tell. Conflicts are checked for the first occurrence only.

## Expected
The invite shows that it repeats (Outlook: "Occurs every Monday from … to …"). EWS: `MeetingRequest` has `IsRecurring` and `Recurrence` (MS docs, MeetingRequest element). Not in limitations.md or docs/feature-map.md.

## Repro
Probe `Probe_R5H_Dates/recurringInviteKnowsItRepeats`:
```sh
swift test --package-path . --scratch-path .build/tests --skip-build --filter Probe_R5H_Dates/recurringInviteKnowsItRepeats
```

## Failure output
```
Expectation failed: asked.contains("calendar:Recurrence") || asked.contains("calendar:IsRecurring")
invite properties asked: <t:FieldURI FieldURI="calendar:Start"/>…<t:FieldURI FieldURI="calendar:OptionalAttendees"/>
```

## Fix idea
Add `calendar:IsRecurring` (and `calendar:Recurrence` for the pattern) to `inviteProps`, carry it in `Invite`, and add "repeats …" to the when line.
