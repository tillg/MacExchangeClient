import Foundation
import Testing
@testable import MailModel

/// Meeting invites: conflicts and the day column, with made-up events.
struct InviteTests {
    let day = ISO8601DateFormatter().date(from: "2026-11-23T00:00:00Z")!
    func at(_ h: Double) -> Date { day.addingTimeInterval(h * 3600) }
    func ev(_ s: String, _ from: Double, _ to: Double, _ busy: BusyStatus = .busy, allDay: Bool = false) -> CalendarEvent {
        CalendarEvent(subject: s, start: at(from), end: at(to), isAllDay: allDay, busy: busy)
    }

    var invite: Invite { Invite(start: at(12.5), end: at(13), location: "Room") }

    @Test func conflictsAreOverlapsExceptTheInviteItselfAndFreeTime() {
        let events = [ev("Mgmt JF", 10, 13), ev("Lunch", 12, 12.5), ev("Planning", 12.75, 13.5, .tentative),
                      ev("Projektzahlen", 12.5, 13, .tentative), ev("Holiday", 0, 24, .free, allDay: true), ev("Later", 13, 14)]
        let c = invite.conflicts(in: events, subject: "Projektzahlen")
        #expect(c.map(\.subject) == ["Mgmt JF", "Planning"])
        #expect(invite.isOwnEntry(events[3], subject: "Projektzahlen"))
    }

    @Test func overlappingEventsShareTheWidthSideBySide() {
        let events = [ev("A", 9, 10), ev("B", 10, 13), ev("C", 12, 12.5), ev("D", 12.5, 13), ev("E", 14, 15)]
        let cols = DayLayout.columns(events)
        #expect(cols.map(\.column) == [0, 0, 1, 1, 0])
        #expect(cols.map(\.of) == [1, 2, 2, 2, 1])
    }

    @Test func allDayEventsStayOutOfTheTimeGrid() {
        let cols = DayLayout.columns([ev("Holiday", 0, 24, .free, allDay: true), ev("A", 9, 10)])
        #expect(cols.map(\.event.subject) == ["A"])
    }

    /// A 0-minute entry is drawn as tall as a short one: it takes room, so it never sits on top of an entry
    /// starting at the same time, and identical entries are distinct in the column.
    @Test func zeroLengthEventAndMeetingAtTheSameTimeAreSideBySide() {
        let cols = DayLayout.columns([ev("Reminder", 9, 9), ev("Meeting", 9, 10)])
        #expect(Set(cols.map(\.column)).count == 2)
        var problems: [String] = []
        for seed in UInt64(0)..<2000 {
            var rng = SplitMix(state: seed)
            var evs: [CalendarEvent] = []
            for _ in 0..<Int.random(in: 2...8, using: &rng) {
                let s = Double(Int.random(in: 32..<40, using: &rng)) / 4
                evs.append(ev("Busy", s, s + Double(Int.random(in: -2...4, using: &rng)) / 4))
            }
            let placed = DayLayout.columns(evs)
            if placed.count != evs.count { problems.append("seed \(seed): count"); continue }
            if Set(placed).count != placed.count { problems.append("seed \(seed): duplicate Placed values") }
            for (i, a) in placed.enumerated() {
                for b in placed[(i + 1)...] where a.event.start == b.event.start && a.column == b.column {
                    problems.append("seed \(seed): two events at \(a.event.start) in column \(a.column)")
                }
                if a.column >= a.of { problems.append("seed \(seed): column \(a.column) of \(a.of)") }
            }
        }
        #expect(problems.isEmpty, "\(problems.count) problems, e.g. \(problems.prefix(3))")
    }

    var utc: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }

    /// The column's hours: 8–18, widened to the invite and the day's entries; times on another day count as the
    /// day's start or end; an all-day invite doesn't widen it.
    @Test func dayColumnHours() {
        #expect(DayLayout.hours(for: invite, events: [], calendar: utc) == 8...18)
        #expect(DayLayout.hours(for: Invite(start: at(7.5), end: at(19.25)), events: [], calendar: utc) == 7...20)
        #expect(DayLayout.hours(for: Invite(start: at(22), end: at(26)), events: [], calendar: utc) == 8...24)
        #expect(DayLayout.hours(for: invite, events: [ev("Night", -2, 1)], calendar: utc) == 0...18)
        #expect(DayLayout.hours(for: Invite(start: at(0), end: at(24), isAllDay: true), events: [ev("A", 9, 10)], calendar: utc) == 8...18)
    }

    /// When the calendar can't be read (no server, paused, an error), the day column stops waiting for it.
    @MainActor @Test func dayThatCantBeLoadedIsMarkedUnavailable() async {
        let acct = Account(name: "Work", address: "me@work.com")
        var m = Message(accountID: acct.id, from: Contact(name: "A", email: "a@x.com"), to: [], subject: "Meet", body: "B", date: .now)
        m.invite = invite
        let s = MailStore(accounts: [acct], messages: [m])
        #expect(!s.unavailableDays.contains(m.id))
        await s.loadDay(for: m.id)
        #expect(s.unavailableDays.contains(m.id) && s.dayEvents[m.id] == nil)
        s.setDayEvents([], for: m.id)
        #expect(!s.unavailableDays.contains(m.id))
    }

    @Test func oldCachesWithoutInviteFieldsStillLoad() throws {
        let m = Message(accountID: UUID(), from: Contact(name: "A", email: "a@x.com"), to: [], subject: "S", body: "B",
                        date: .now, remoteID: "R")
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(m)) as! [String: Any]
        json["isInvite"] = nil
        json["invite"] = nil
        let old = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(Message.self, from: old)
        #expect(decoded.subject == "S")
        #expect(decoded.invite == nil)
        #expect(decoded.isInvite == nil)
    }
}
