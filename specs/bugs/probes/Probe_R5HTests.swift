import Foundation
import Testing
@testable import EWS
@testable import MailModel

/// Round 5, hunter H: dates, times, locales, plurals, subject prefixes.
/// R5H-01 (What's New date one day early west of UTC) is in the view and proven by snapshot PNGs, not here.
@MainActor
struct Probe_R5H_Dates {
    let work = Account(name: "Work", address: "me@work.com")
    let iso = ISO8601DateFormatter()
    var berlin: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/Berlin")!; return c }
    let en = Locale(identifier: "en_GB")

    func doc(_ body: String) throws -> XMLDocument {
        try XMLDocument(xmlString: """
            <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" \
            xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages" \
            xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types"><s:Body>\(body)</s:Body></s:Envelope>
            """)
    }

    func replySubject(_ subject: String) -> String {
        let m = Message(accountID: work.id, mailbox: .inbox, from: Contact(name: "Ann", email: "ann@x.com"),
                        to: [Contact(name: "Me", email: work.address)], subject: subject, body: "Text",
                        date: Date(timeIntervalSince1970: 1_790_000_000), isRead: true)
        return MailStore(accounts: [work], messages: [m]).draft(.reply, to: m.id).subject
    }

    /// R5H-02: a one-day all-day invite from a colleague in London (or New York, Tokyo) is named as two days
    /// ("Friday, 20 November – Saturday, 21 November, all day") on a Mac in Berlin.
    @Test func allDayInviteFromAnotherZoneIsOneDay() throws {
        // As Exchange sends it: the organizer's midnights, in UTC. London organizer, all day Friday 20 November.
        let d = try doc("""
            <t:MeetingRequest><t:ItemId Id="M1"/><t:Body BodyType="Text">x</t:Body>
            <t:Start>2026-11-20T00:00:00Z</t:Start><t:End>2026-11-21T00:00:00Z</t:End>
            <t:IsAllDayEvent>true</t:IsAllDayEvent></t:MeetingRequest>
            """)
        let item = try #require(d.first("MeetingRequest"))
        let invite = try #require(EWSBackend.parseBody(item).invite)
        let when = invite.when(calendar: berlin, locale: en)
        #expect(when == "Friday, 20 November 2026, all day", "when line: \(when)")
    }

    /// R5H-03: on the night the clocks go back, a meeting 02:30 CEST – 02:15 CET (45 minutes) reads "at 2:30 – 2:15",
    /// as if it ended before it starts.
    @Test func whenLineAcrossClockChangeDoesNotRunBackwards() throws {
        let invite = Invite(start: try #require(iso.date(from: "2026-10-25T00:30:00Z")),
                            end: try #require(iso.date(from: "2026-10-25T01:15:00Z")))
        let when = invite.when(calendar: berlin, locale: en)
        let t = Date.FormatStyle(date: .omitted, time: .shortened, locale: en, calendar: berlin, timeZone: berlin.timeZone)
        let backwards = "at \(invite.start.formatted(t)) – \(invite.end.formatted(t))"  // "at 2:30 – 2:15"
        let runsBackwards = when.hasSuffix(backwards)
        #expect(!runsBackwards, "when line: \(when) (45 minutes; no zone or offset tells the two 2 o'clocks apart)")
    }

    /// R5H-04: a recurring meeting's invite is read and shown as a one-off: the recurrence is never asked for.
    @Test func recurringInviteKnowsItRepeats() {
        let asked = EWSBackend.inviteProps
        #expect(asked.contains("calendar:Recurrence") || asked.contains("calendar:IsRecurring"),
                "invite properties asked: \(asked)")
    }

    /// R5H-05: reply prefixes "Re[2]:" and a prefix after a leading blank aren't recognised: a second "Re:" is stacked.
    @Test func replyDoesNotStackNumberedOrIndentedPrefix() {
        let numbered = replySubject("Re[2]: Budget"), indented = replySubject(" Re: Budget")
        #expect(numbered == "Re: Budget", "Re[2]: → \(numbered)")
        #expect(indented == "Re: Budget", "' Re:' → \(indented)")
    }
}
