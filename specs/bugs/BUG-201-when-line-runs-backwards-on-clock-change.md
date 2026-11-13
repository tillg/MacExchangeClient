---
title: "On the night the clocks go back, an invite's when line reads \"at 2:30 – 2:15\", as if it ended before it starts"
priority: P4
area: invites
status: open
found: 2026-11-13
---
Draft id: R5H-03 (probe suites `Probe_R5*` in `probes/Probe_R5*Tests.swift`).

## Summary
`Invite.when` writes start and end as wall-clock times only. On 25 October 2026 in Berlin, 02:00–03:00 happens twice; a 45-minute meeting 02:30 CEST – 02:15 CET shows "Sunday, 25 October 2026 at 2:30 – 2:15".

## Expected
Plain correctness: the line must not read as ending before it starts (e.g. add the zone, "2:30 CEST – 2:15 CET", when the offset differs between start and end).

## Repro
Probe `Probe_R5H_Dates/whenLineAcrossClockChangeDoesNotRunBackwards`:
```sh
swift test --package-path . --scratch-path .build/tests --skip-build --filter Probe_R5H_Dates/whenLineAcrossClockChangeDoesNotRunBackwards
```

## Failure output
```
Expectation failed: !runsBackwards
when line: Sunday, 25 October 2026 at 2:30 – 2:15 (45 minutes; no zone or offset tells the two 2 o'clocks apart)
```

## Fix idea
In `Invite.when`, when `calendar.timeZone.secondsFromGMT(for: start) != …(for: end)`, format both times with `.timeZone(.specificName(.short))`.
