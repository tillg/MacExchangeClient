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
}
