---
title: 'Day column: zero-length (or end-before-start) events take no room, so they are drawn on top of the event starting at the same time'
priority: P4
area: Invite
status: open
found: 2026-11-12
---
## Summary
`DayLayout.columns` treats an event whose end is not after its start as occupying no time. A 0-minute appointment at 9:00 (Outlook allows them, for example reminders or "call X") and a 9:00–10:00 meeting each get column 0 of 1. InviteView draws every event at least 14 pt tall, so both boxes appear at the same spot, on top of each other. Two identical 0-minute entries also produce identical `Placed` values, while the day column's `ForEach` uses the `Placed` value itself as its id.

## Repro
```swift
import Foundation
import Testing
@testable import MailModel

struct Probe_Model2Tests {
    let day = ISO8601DateFormatter().date(from: "2026-11-23T00:00:00Z")!
    func at(_ h: Double) -> Date { day.addingTimeInterval(h * 3600) }
    func ev(_ s: String, _ from: Double, _ to: Double) -> CalendarEvent { CalendarEvent(subject: s, start: at(from), end: at(to)) }

    @Test func zeroLengthEventAndMeetingAtTheSameTimeAreSideBySide() {
        let cols = DayLayout.columns([ev("Reminder", 9, 9), ev("Meeting", 9, 10)])
        // Drawn at the same top (the view gives every event at least 14 pt): they must not share a column.
        #expect(Set(cols.map(\.column)).count == 2, "\(cols.map { ($0.event.subject, $0.column, $0.of) })")
    }

    struct SplitMix: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    /// Zero-length, negative and duplicate events: every Placed is distinct, events starting together never share a column.
    @Test func dayLayoutWithDegenerateEventsOverRandomDays() {
        var problems: [String] = []
        for seed in UInt64(0)..<2000 {
            var rng = SplitMix(state: seed)
            var evs: [CalendarEvent] = []
            for _ in 0..<Int.random(in: 2...8, using: &rng) {
                let s = Double(Int.random(in: 32..<40, using: &rng)) / 4
                let len = Double(Int.random(in: -2...4, using: &rng)) / 4
                evs.append(ev("Busy", s, s + len))
            }
            let placed = DayLayout.columns(evs)
            if placed.count != evs.count { problems.append("seed \(seed): count"); continue }
            if Set(placed).count != placed.count { problems.append("seed \(seed): duplicate Placed values") }
            for (i, a) in placed.enumerated() {
                for b in placed[(i + 1)...] where a.event.start == b.event.start && a.column == b.column {
                    problems.append("seed \(seed): two events at \(a.event.start) in column \(a.column)")
                }
            }
        }
        #expect(problems.isEmpty, "\(problems.count) problems, e.g. \(problems.prefix(3))")
    }
}
```
Control (passes): `dayLayoutPropertiesOverRandomDays`, 2,000 seeded days of positive-length events. No overlapping pair shares a column, column < of, and overlapping events have equal widths.

## Expected vs actual
```
Test zeroLengthEventAndMeetingAtTheSameTimeAreSideBySide() recorded an issue: Expectation failed: Set(cols.map(\.column)).count == 2
Test dayLayoutWithDegenerateEventsOverRandomDays() recorded an issue: Expectation failed: problems.isEmpty
  1921 problems, e.g. ["seed 0: two events at 2026-11-23 09:30:00 +0000 in column 0", "seed 0: two events at 2026-11-23 09:45:00 +0000 in column 0", "seed 1: two events at 2026-11-23 09:30:00 +0000 in column 1"]
  (… "seed 9: duplicate Placed values" …)
```

## Why expected
README: the day column shows "overlapping events side by side". InviteView draws each event `max(14, …)` pt tall (`Sources/MailReplica/InviteView.swift:208`), so a 0-minute entry visibly overlaps whatever starts at the same time. Note: round 1's control `zeroLengthEventsAtSameTimeShareColumns` explicitly accepted `of == 1` for two zero-length events. This finding rests on the view's minimum height and on the duplicate `ForEach` ids, not on the model's own definition of overlap.

## Likely cause
`Sources/MailModel/Invite.swift:98-99`: `if e.start >= groupEnd { flush() }` and `columnEnds.firstIndex { $0 <= e.start }` use the raw end. A zero-length or negative event ends a group at its own start, so the next event at that time starts a new group in column 0. Giving each event a minimum duration (the view's 14 pt ≈ 19 min) for layout would match what is drawn.
