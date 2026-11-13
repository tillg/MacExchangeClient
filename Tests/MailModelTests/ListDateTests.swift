import Foundation
import Testing
@testable import MailModel

/// The message list's date column: time today, "Yesterday", the weekday 2–6 calendar days back, else the date.
/// BUG-220: a future date got a weekday, and last week's same weekday with a later time looked like this week's.
struct ListDateTests {
    let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return c
    }()
    /// Friday 2026-11-13 10:00 in Berlin.
    var now: Date { cal.date(from: DateComponents(year: 2026, month: 11, day: 13, hour: 10))! }
    func at(_ day: Int, _ hour: Int) -> Date { cal.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour))! }

    @Test func kinds() {
        #expect(ListDate.kind(of: at(13, 8), now: now, calendar: cal) == .time)
        #expect(ListDate.kind(of: at(12, 23), now: now, calendar: cal) == .yesterday)
        #expect(ListDate.kind(of: at(8, 9), now: now, calendar: cal) == .weekday)  // Sunday, 5 days ago
        #expect(ListDate.kind(of: at(7, 9), now: now, calendar: cal) == .weekday)  // Saturday, 6 days ago
        #expect(ListDate.kind(of: at(6, 18), now: now, calendar: cal) == .date)  // last Friday, later time than now
        #expect(ListDate.kind(of: at(14, 9), now: now, calendar: cal) == .date)  // tomorrow (future): not a weekday
        #expect(ListDate.kind(of: at(13, 20), now: now, calendar: cal) == .time)  // later today
    }
}
