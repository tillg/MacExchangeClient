import Foundation
import MailModel

@MainActor
enum SampleData {
    static func store() -> MailStore {
        let icloud = Account(name: "iCloud", address: "alex@icloud.com")
        let work = Account(name: "Work", address: "alex.morgan@northwind.example")
        func c(_ n: String, _ e: String) -> Contact { Contact(name: n, email: e) }
        let me = [c("Alex Morgan", icloud.address)], meWork = [c("Alex Morgan", work.address)]
        func ago(_ h: Double) -> Date { Date().addingTimeInterval(-h * 3600) }

        let msgs: [Message] = [
            Message(accountID: work.id, from: c("Priya Raman", "priya@northwind.example"), to: meWork,
                    cc: [c("Jonas Weber", "jonas@northwind.example")],
                    subject: "Q4 roadmap review – agenda",
                    body: "Hi Alex,\n\nAhead of Thursday's review, here is the agenda:\n\n1. Recap of Q3 delivery\n2. Q4 priorities and owners\n3. Hiring plan\n\nPlease add anything I've missed by Wednesday noon.\n\nThanks,\nPriya",
                    date: ago(0.3), isVIP: true, attachments: ["Q4-Roadmap.pdf"]),
            Message(accountID: icloud.id, from: c("Sam Lee", "sam.lee@me.com"), to: me,
                    subject: "Hiking on Saturday?",
                    body: "Weather looks great this weekend. Want to do the ridge trail? I can drive – pick you up at 8.\n\nSam",
                    date: ago(1.2)),
            Message(accountID: work.id, from: c("GitHub", "noreply@github.com"), to: meWork,
                    subject: "[northwind/api] PR #482: Add rate limiting middleware",
                    body: "jonas-weber requested your review on this pull request.\n\nAdds a token-bucket rate limiter to all public endpoints.",
                    date: ago(2), category: .updates),
            Message(accountID: icloud.id, from: c("Apple", "no_reply@email.apple.com"), to: me,
                    subject: "Your receipt from Apple", body: "Receipt\nApple ID: alex@icloud.com\n\niCloud+ 200 GB  2,99 €\n\nTotal 2,99 €",
                    date: ago(5), isRead: true, category: .transactions),
            Message(accountID: icloud.id, from: c("Tidewater Outfitters", "news@tidewater.example"), to: me,
                    subject: "30% off everything this weekend 🌊",
                    body: "Our biggest sale of the season starts now. Jackets, packs and boots – all 30% off until Sunday.",
                    date: ago(9), category: .promotions),
            Message(accountID: work.id, from: c("Jonas Weber", "jonas@northwind.example"), to: meWork,
                    subject: "Re: Staging outage postmortem",
                    body: "Root cause was the expired TLS cert on the internal load balancer. I've added an alert 14 days before expiry.\n\n> Can we get a short write-up by Friday?",
                    date: ago(26), isRead: true, flag: .red),
            Message(accountID: icloud.id, from: c("Mom", "mom@family.example"), to: me,
                    subject: "Photos from the weekend",
                    body: "Here are the photos from Grandpa's birthday! The cake one is my favourite.\n\nLove, Mom",
                    date: ago(30), isRead: true, isVIP: true, attachments: ["IMG_2041.jpeg", "IMG_2042.jpeg"]),
            Message(accountID: work.id, from: c("Lufthansa", "online@booking.lufthansa.example"), to: meWork,
                    subject: "Your booking confirmation FRA → SFO",
                    body: "Booking code: K7Q2XP\n\nLH 454  Frankfurt → San Francisco\nDeparts 14 Nov 10:05",
                    date: ago(50), isRead: true, flag: .orange, category: .transactions),
            Message(accountID: work.id, from: c("Figma", "team@figma.example"), to: meWork,
                    subject: "What's new in Dev Mode", body: "Inspect, compare and ship faster with our latest updates.",
                    date: ago(70), isRead: true, category: .promotions),
            Message(accountID: work.id, from: c("Elena Petrova", "elena@client.example"), to: meWork,
                    subject: "Contract draft v3",
                    body: "Alex, attached is v3 with legal's edits on sections 4 and 7. Can we sign off this week?\n\nBest,\nElena",
                    date: ago(120), isRead: true, attachments: ["Contract_v3.docx"]),
            Message(accountID: icloud.id, from: me[0], to: [c("Sam Lee", "sam.lee@me.com")], subject: "Re: Concert tickets",
                    body: "Got them! Row 12.", date: ago(80), isRead: true).with(.sent),
            Message(accountID: work.id, from: meWork[0], to: [c("Priya Raman", "priya@northwind.example")],
                    subject: "Hiring plan notes", body: "Draft – two backend roles, one designer…", date: ago(40),
                    isRead: true).with(.drafts),
            Message(accountID: icloud.id, from: c("Prize Center", "winner@lucky.example"), to: me,
                    subject: "You have WON!!!", body: "Click here to claim your prize.", date: ago(15)).with(.junk),
            Message(accountID: work.id, from: c("Jonas Weber", "jonas@northwind.example"), to: meWork,
                    subject: "Offsite venue options", body: "Three options attached, my vote is the lake house.",
                    date: ago(400), isRead: true).with(.archive),
        ]
        // A made-up meeting invite for tomorrow, with a made-up day around it.
        let cal = Calendar.current
        let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: .now))!
        func at(_ h: Double) -> Date { tomorrow.addingTimeInterval(h * 3600) }
        let inviteSubject = "Q4 numbers review"
        let invite = Message(
            accountID: work.id, from: c("Priya Raman", "priya@northwind.example"), to: meWork,
            subject: inviteSubject, body: "Let's go through the Q4 numbers before the board meeting.\n\nPriya",
            date: ago(0.8),
            invite: Invite(start: at(12.5), end: at(13), location: "Room 2.33 – Harbour View",
                           organizer: c("Priya Raman", "priya@northwind.example"),
                           required: [c("Alex Morgan", work.address), c("Jonas Weber", "jonas@northwind.example"),
                                      c("Elena Petrova", "elena@northwind.example"), c("Sam Okafor", "sam@northwind.example")],
                           optional: [c("Mia Chen", "mia@northwind.example")]))
        let store = MailStore(accounts: [icloud, work], messages: msgs + [invite])
        store.setDayEvents([
            CalendarEvent(subject: "Company offsite week", start: tomorrow, end: at(24), isAllDay: true, busy: .free),
            CalendarEvent(subject: "Weekly sync", start: at(9), end: at(10)),
            CalendarEvent(subject: "Management prep", start: at(10), end: at(13)),
            CalendarEvent(subject: "Budget check-in", start: at(12), end: at(12.5), busy: .tentative),
            CalendarEvent(subject: inviteSubject, start: at(12.5), end: at(13), busy: .tentative),
            CalendarEvent(subject: "1:1 Jonas", start: at(14), end: at(15)),
            CalendarEvent(subject: "Focus time", start: at(15.5), end: at(17), busy: .free),
        ], for: invite.id)
        return store
    }
}

extension Message {
    func with(_ box: MailboxKind) -> Message { var m = self; m.mailbox = box; return m }
}
