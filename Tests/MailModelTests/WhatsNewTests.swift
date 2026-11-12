import Foundation
import MailModel
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
