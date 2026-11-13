import Foundation
@testable import MailModel
import Testing

@Test func whatsNewIsNewestFirstWithValidDatesAndFeatures() {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd"
    let dates = WhatsNew.days.map(\.date)
    #expect(!dates.isEmpty)
    #expect(dates.allSatisfy { f.date(from: $0) != nil })
    #expect(dates == dates.sorted(by: >))
    #expect(Set(dates).count == dates.count)
    #expect(WhatsNew.days.allSatisfy { !$0.features.isEmpty })
}

/// BUG-199: a day's heading is that day in every time zone (New York included), not the day before.
@Test func whatsNewDayTitleIsTheSameDayInEveryTimeZone() {
    for zone in ["America/New_York", "Pacific/Honolulu", "Europe/Berlin", "Asia/Tokyo"] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: zone)!
        let title = ChangeLogDay(date: "2026-11-13", features: ["x"]).title(calendar: cal, locale: Locale(identifier: "en_US"))
        #expect(title == "Friday, November 13, 2026", "\(zone): \(title)")
    }
}
