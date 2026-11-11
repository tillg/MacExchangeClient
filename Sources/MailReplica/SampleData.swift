import AppKit
import MailModel

@MainActor
enum SampleData {
    static func store() -> MailStore {
        let icloud = Account(name: "iCloud", address: "alex@icloud.com")
        let work = Account(name: "Work", address: "alex.morgan@northwind.example")
        func c(_ n: String, _ e: String) -> Contact { Contact(name: n, email: e) }
        let me = [c("Alex Morgan", icloud.address)], meWork = [c("Alex Morgan", work.address)]
        func ago(_ h: Double) -> Date { Date().addingTimeInterval(-h * 3600) }
        // Work's own folders: Inbox ▸ Projects ▸ Northwind Launch, Inbox ▸ Receipts, Clients ▸ Contoso.
        let projects = MailboxKind.folder("projects"), launch = MailboxKind.folder("launch"),
            receipts = MailboxKind.folder("receipts"), clients = MailboxKind.folder("clients"), contoso = MailboxKind.folder("contoso")

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
                    date: ago(9), category: .promotions).withHTML(tidewaterHTML),
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
                    date: ago(120), isRead: true, attachments: ["Contract_v3.docx"]).withHTML(elenaHTML),
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
            // Mail in folders of the user's own (the tree below).
            Message(accountID: work.id, from: c("Mia Chen", "mia@northwind.example"), to: meWork,
                    subject: "Launch checklist – final", body: "All items are green except the press kit, due Tuesday.",
                    date: ago(6)).with(launch),
            Message(accountID: work.id, from: c("Jonas Weber", "jonas@northwind.example"), to: meWork,
                    subject: "Launch day rota", body: "I've put everyone on the rota; swap with each other if needed.",
                    date: ago(20)).with(launch),
            Message(accountID: work.id, from: c("Priya Raman", "priya@northwind.example"), to: meWork,
                    subject: "Project kickoff notes", body: "Notes from Monday's kickoff are in the shared folder.",
                    date: ago(100), isRead: true).with(projects),
            Message(accountID: work.id, from: c("Elena Petrova", "elena@client.example"), to: meWork,
                    subject: "Invoice 2026-114", body: "Please find our invoice for October attached.",
                    date: ago(60), attachments: ["Invoice-2026-114.pdf"]).with(contoso),
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
        store.setFolders([Folder(box: projects, name: "Projects", parent: .inbox),
                          Folder(box: launch, name: "Northwind Launch", parent: projects),
                          Folder(box: receipts, name: "Receipts", parent: .inbox),
                          Folder(box: clients, name: "Clients"), Folder(box: contoso, name: "Contoso", parent: clients)],
                         account: work.id)
        store.setDayEvents([
            CalendarEvent(subject: "Company offsite week", start: tomorrow, end: at(24), isAllDay: true, busy: .free),
            CalendarEvent(subject: "Weekly sync", start: at(9), end: at(10)),
            CalendarEvent(subject: "Management prep", start: at(10), end: at(13)),
            CalendarEvent(subject: "Budget check-in", start: at(12), end: at(12.5), busy: .tentative),
            CalendarEvent(subject: inviteSubject, start: at(12.5), end: at(13), busy: .tentative),
            CalendarEvent(subject: "1:1 Jonas", start: at(14), end: at(15)),
            CalendarEvent(subject: "Focus time", start: at(15.5), end: at(17), busy: .free),
        ], for: invite.id)
        // The signature logo of Elena's mail, an image attached to the message (cid:).
        if let elena = store.messages.first(where: { $0.subject == "Contract draft v3" }) {
            store.setInlineImages(["logo@client.example": InlineImage(contentType: "image/png", data: logo())], for: elena.id)
        }
        return store
    }

    /// A made-up company logo, drawn in code.
    private static func logo() -> Data {
        let image = NSImage(size: NSSize(width: 150, height: 40), flipped: false) { r in
            NSColor(red: 0.13, green: 0.36, blue: 0.47, alpha: 1).setFill()
            NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 16, weight: .semibold),
                                                        .foregroundColor: NSColor.white]
            NSAttributedString(string: "Client & Co.", attributes: attrs).draw(at: NSPoint(x: 22, y: 10))
            return true
        }
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return Data() }
        return rep.representation(using: .png, properties: [:]) ?? Data()
    }
}

extension Message {
    func with(_ box: MailboxKind) -> Message { var m = self; m.mailbox = box; return m }
    func withHTML(_ html: String) -> Message { var m = self; m.html = html; return m }
}

/// A made-up newsletter in the usual table layout, with a hero image from the web (blocked until loaded).
private let tidewaterHTML = """
    <table width="100%" cellpadding="0" cellspacing="0" style="background:#eef3f6"><tr><td align="center" style="padding:24px 0">
    <table width="560" cellpadding="0" cellspacing="0" style="background:#ffffff;border-radius:8px;font-family:Georgia,serif">
    <tr><td style="background:#0b4f6c;color:#ffffff;padding:20px 28px;font-size:22px;letter-spacing:2px">TIDEWATER OUTFITTERS</td></tr>
    <tr><td><img src="https://images.tidewater.example/hero-fall.jpg" width="560" height="180" alt="Fall sale"></td></tr>
    <tr><td style="padding:24px 28px;color:#1d2b33">
    <h1 style="margin:0 0 12px;font-size:28px;color:#0b4f6c">30% off everything 🌊</h1>
    <p style="font-size:15px;line-height:1.5">Our biggest sale of the season starts now. Jackets, packs and boots –
    <b>all 30% off</b> until Sunday.</p>
    <table cellpadding="0" cellspacing="0"><tr>
    <td style="background:#f26b3a;border-radius:4px;padding:12px 22px">
    <a href="https://tidewater.example/sale" style="color:#ffffff;text-decoration:none;font-weight:bold">Shop the sale</a></td>
    </tr></table>
    </td></tr>
    <tr><td style="padding:16px 28px;color:#7a8a93;font-size:11px;border-top:1px solid #e3e9ec">
    You get this because you signed up at tidewater.example. <a href="https://tidewater.example/unsubscribe" style="color:#7a8a93">Unsubscribe</a>
    </td></tr></table></td></tr></table>
    """

/// A plain business mail with the logo in the signature as an attached image.
private let elenaHTML = """
    <p>Alex, attached is v3 with legal's edits on sections 4 and 7. Can we sign off this week?</p>
    <p>Best,<br>Elena</p>
    <p style="color:#666;font-size:12px">Elena Petrova · Legal Counsel<br>
    <img src="cid:logo@client.example" width="150" height="40" alt="Client &amp; Co."></p>
    """
