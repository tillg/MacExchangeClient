import Foundation
import Testing
@testable import MailModel

/// Round 5, hunter E (UI). Most UI findings are proven by snapshot PNGs (see specs/bugs/drafts/R5E-*.md);
/// the ones whose cause is in MailModel get a probe here.
@MainActor
struct Probe_R5EFindings {
    let work = Account(name: "Work", address: "me@work.com")

    func mail(from name: String, _ email: String, minutesAgo: Double) -> Message {
        var m = Message(accountID: work.id, mailbox: .inbox, from: Contact(name: name, email: email),
                        to: [Contact(name: "Me", email: work.address)], subject: "Plan", body: "Text",
                        date: Date(timeIntervalSince1970: 1_000_000 - minutesAgo * 60), isRead: true)
        m.conversationID = "C"
        return m
    }

    /// R5E-10: two different people with the same first name in one conversation row are shown as one sender,
    /// with the full name of only one of them (README: "the full name when it is one sender").
    @Test func conversationRowKeepsTwoSendersWithTheSameFirstName() {
        let s = MailStore(accounts: [work], messages: [
            mail(from: "Jan Müller", "jan.mueller@x.com", minutesAgo: 0),
            mail(from: "Jan Schmidt", "jan.schmidt@x.com", minutesAgo: 10),
        ])
        s.groupsConversations = true
        s.selectedMailbox = .smart(.allInboxes)
        let row = s.visibleMessages.first.flatMap { s.conversationRow($0.id) }
        #expect(row?.count == 2)
        // Expected: both people appear (e.g. "Jan & Jan" or both full names), not one person's full name.
        #expect(row?.senders != "Jan Müller", "senders: \(row?.senders ?? "nil")")
    }
}
