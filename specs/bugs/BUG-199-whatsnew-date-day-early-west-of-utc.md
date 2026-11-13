---
title: "Help ▸ What's New dates each day one day early on a Mac west of UTC (2026-11-13 shown as Thursday, 12 November)"
priority: P4
area: UI / WhatsNewView
status: open
found: 2026-11-13
---
Draft id: R5H-01 (probe suites `Probe_R5*` in `probes/Probe_R5*Tests.swift`).

## Summary
`WhatsNewView.title` parses the "yyyy-MM-dd" day with `.iso8601.year().month().day()`, which reads it as midnight UTC, then formats it in the Mac's zone. West of UTC (Americas) every heading is the day before; in Berlin it is right.

## Expected
The heading names the day written in `WhatsNew.days` (CLAUDE.md change-log rule: one entry per day) in every zone. Plain correctness.

## Repro
UI, proven by snapshot (no MailModel cause):
```sh
tools/snapshot.sh $PWD/tmp/wn-ny.png MAIL_SNAPSHOT_WHATSNEW=1 TZ=America/New_York
tools/snapshot.sh $PWD/tmp/wn-berlin.png MAIL_SNAPSHOT_WHATSNEW=1 TZ=Europe/Berlin   # control
```
PNGs: `png/BUG-199-whatsnew-new-york.png` (bug), `png/BUG-199-whatsnew-berlin.png` (control).

## Failure output
New York: first heading "Thursday, 12. November 2026" for the 2026-11-13 entry. Berlin: "Friday, 13. November 2026".

## Fix idea
Parse with the current zone (`Date.ISO8601FormatStyle(timeZone: .current)`), or format with `timeZone: .gmt`.

## Store-level probe (found separately as R5G-08)
`Probe_R5GWhatsNew/dayTitleIsTheSameDayInEveryTimeZone` in `probes/Probe_R5GTests.swift` mirrors the parsing line of `WhatsNewView.swift`.
