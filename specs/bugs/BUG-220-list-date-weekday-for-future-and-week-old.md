---
title: "Message list shows only a weekday for a date in the future, and for last week's same weekday after the current time"
priority: P3
area: MessageListView
status: open
found: 2026-11-13
---
Draft id: R5F-04 (probe suites `Probe_R5*` in `probes/Probe_R5*Tests.swift`).

## Summary
`MessageRow.listDate` (MessageListView.swift:176-184) shows the weekday when `dateComponents([.day], from: d, to: .now).day < 7`. That counts whole 24-hour spans, not calendar days, and has no lower bound:
- A message dated in the future (a sender's wrong clock, spam, a meeting update dated ahead) gives a negative count and shows just a weekday: a mail dated 13.12.2026 shows "Sunday", as if from this week.
- A message from the same weekday last week, later in the day than now, is 6 days and some hours old: on Friday 13:44 a mail from last Friday 23:54 shows "Friday", the same as today's weekday, though Today's mail shows a time and the rule's Today/Yesterday steps are calendar days.

## Expected
functional.md: "date (time today, "Yesterday", weekday within 7 days, else short date)". A future date is not within the last 7 days; "within 7 days" counted in calendar days, as Today/Yesterday are (`isDateInToday`/`isDateInYesterday`), so the weekday never repeats today's. ⚠️ Mail's exact cut-off is recalled, not read; the future date is wrong under any reading.

## Repro
Evidence: view harness (calls the real `MessageRow.listDate`).
```
specs/bugs/probes-views/run-harness.sh build
specs/bugs/probes-views/run-harness.sh listdate
```

## Failure output
```
R5F today is Friday
R5F listDate(30 days in the future = 13.12.2026, 13:44) = "Sunday"
R5F FAIL: expected the short date "13.12.2026" for 30 days in the future, got "Sunday"
R5F listDate(7 calendar days ago, 23:54 = 6.11.2026, 23:54) = "Friday"
R5F FAIL: expected the short date "6.11.2026" for 7 calendar days ago, 23:54, got "Friday"
```

## Fix idea
Count calendar days between `startOfDay(d)` and `startOfDay(now)` and use the weekday only for `2...6`; anything after today (or before) gets the short date.
