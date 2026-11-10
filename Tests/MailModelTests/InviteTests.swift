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
