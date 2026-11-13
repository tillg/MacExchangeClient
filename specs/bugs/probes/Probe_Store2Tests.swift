import Foundation
import Testing
@testable import EWS
@testable import MailModel

@MainActor
struct Probe_Store2Tests {
    let work = Account(name: "Work", address: "me@work.com")
    let home = Account(name: "iCloud", address: "me@icloud.com")

    func msg(_ acct: Account, _ box: MailboxKind = .inbox, subject: String = "Hi", from: String = "Ann",
             read: Bool = false, minutesAgo: Double = 0, flag: FlagColor? = nil) -> Message {
        Message(accountID: acct.id, mailbox: box, from: Contact(name: from, email: "\(from.lowercased())@x.com"),
                to: [Contact(name: "Me", email: acct.address)], subject: subject, body: "Body of \(subject)",
                date: Date(timeIntervalSince1970: 1_000_000 - minutesAgo * 60), isRead: read, flag: flag)
    }

    /// Like a server summary (EWS FindItem/SyncFolderItems): no body, names only for From/To.
    func summary(_ acct: Account, _ rid: String, subject: String = "Hi", minutesAgo: Double = 0) -> Message {
        var m = Message(accountID: acct.id, from: Contact(name: "Ann Lee", email: ""), to: [Contact(name: "Me", email: "")],
                        subject: subject, body: "", date: Date(timeIntervalSince1970: 1_000_000 - minutesAgo * 60),
                        remoteID: rid, serverPreview: "Can we meet on Friday?", bodyLoaded: false)
        m.conversationID = nil
        return m
    }

    func store(_ msgs: [Message]) -> MailStore { MailStore(accounts: [work, home], messages: msgs) }

    func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("ProbeStore2-\(UUID())")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func invite(organizer: Contact? = Contact(name: "Org", email: "org@x.com")) -> Invite {
        Invite(start: Date(timeIntervalSince1970: 2_000_000), end: Date(timeIntervalSince1970: 2_003_600),
               organizer: organizer)
    }

    // MARK: Drafts lifecycle

    // MARK: Invites

    @Test func removeFromCalendarSelectsNext() {
        var a = msg(work, subject: "Canceled: X", minutesAgo: 1); a.invite = invite(); a.invite?.isCancellation = true
        let b = msg(work, subject: "B", minutesAgo: 2)
        let s = store([a, b])
        s.selectedMailbox = .account(work.id, .inbox)
        s.selection = [a.id]
        s.removeFromCalendar(a.id)
        #expect(s.message(a.id)?.mailbox == .trash)
        #expect(s.selection == [b.id])
    }

    // MARK: Accounts

    /// Signing in a further account resets what the user is looking at although nothing was removed.
    @Test func removeLocalAccountsWithNothingLocalKeepsTheView() {
        let s = MailStore(accounts: [], messages: [])
        let backend = EWSBackend(client: EWSClient(url: URL(string: "https://example.invalid/EWS/Exchange.asmx")!,
                                                   username: "u", password: "p"))
        s.add(work, backend: backend)
        var r = msg(work, .sent); r.remoteID = "R1"
        s.merge([r], account: work.id, mailbox: .sent)
        s.selectedMailbox = .account(work.id, .sent)
        s.selection = [s.messages[0].id]
        s.removeLocalAccounts()
        #expect(s.selectedMailbox == .account(work.id, .sent))
        #expect(s.selection == [s.messages[0].id])
    }

    // MARK: Conversations / inline images

    /// Images of a message arriving after the user moved on must not throw away the images of the message on screen.
    @Test func lateInlineImagesDoNotDropTheShownMessagesImages() {
        let a = msg(work, subject: "A", minutesAgo: 1), b = msg(work, subject: "B", minutesAgo: 2)
        let s = store([a, b])
        let png = InlineImage(contentType: "image/png", data: Data([1]))
        s.selection = [b.id]
        s.addInlineImages(["b@y": png], for: b.id)
        s.addInlineImages(["a@y": png], for: a.id)  // A's request, sent before switching to B, comes back late
        #expect(s.inlineImages(for: b.id) == ["b@y": png])
    }

    // MARK: Draft size

    // MARK: Attachments

    // MARK: Smart mailboxes, counts (property)

    @Test func countsMatchVisibleListsUnderRandomActions() {
        var rng = SystemRandomNumberGenerator()
        for seed in 0..<20 {
            _ = seed
            let boxes: [MailboxKind] = [.inbox, .drafts, .sent, .junk, .trash, .archive, .folder("P")]
            var ms: [Message] = []
            for i in 0..<200 {
                var m = msg(Bool.random(using: &rng) ? work : home, boxes.randomElement(using: &rng)!,
                            subject: "m\(i)", read: Bool.random(using: &rng), minutesAgo: Double(i))
                m.isVIP = Int.random(in: 0..<5, using: &rng) == 0
                m.flag = Int.random(in: 0..<4, using: &rng) == 0 ? FlagColor.allCases.randomElement(using: &rng) : nil
                ms.append(m)
            }
            let s = store(ms)
            let refs: [MailboxRef] = SmartMailbox.allCases.map { .smart($0) }
                + [work, home].flatMap { a in boxes.map { MailboxRef.account(a.id, $0) } }
            for _ in 0..<30 {
                let ids = Set(s.messages.shuffled(using: &rng).prefix(Int.random(in: 1..<10, using: &rng)).map(\.id))
                switch Int.random(in: 0..<7, using: &rng) {
                case 0: s.delete(ids)
                case 1: s.archive(ids)
                case 2: s.toggleJunk(ids)
                case 3: s.toggleRead(ids)
                case 4: s.setFlag(FlagColor.allCases.randomElement(using: &rng), for: ids)
                case 5: s.setFlag(nil, for: ids)
                default: s.markAllRead(in: refs.randomElement(using: &rng)!)
                }
                for ref in refs {
                    s.selectedMailbox = ref
                    let list = s.visibleMessages
                    #expect(s.count(ref) == list.count, "\(ref)")
                    #expect(s.unreadCount(ref) == list.filter { !$0.isRead }.count, "\(ref)")
                }
            }
        }
    }

    // MARK: Round trips of user state through the database

    @Test func flagColoursVIPAndConversationSurviveTheDatabase() throws {
        let url = tempDir().appendingPathComponent("Mail.sqlite")
        let s = store([])
        var ms: [Message] = []
        for (i, c) in ([nil] + FlagColor.allCases.map(Optional.some)).enumerated() {
            var m = msg(work, subject: "m\(i)", minutesAgo: Double(i)); m.remoteID = "R\(i)"; m.flag = c
            m.isVIP = i % 2 == 0; m.conversationID = i % 3 == 0 ? "C\(i)" : nil
            ms.append(m)
        }
        s.merge(ms, account: work.id, mailbox: .inbox)
        // Colours are local; set them again after the merge (the server only knows flagged).
        for (i, m) in ms.enumerated() { s.setFlag(m.flag, for: [s.messages[i].id]) }
        try MailDatabase(url: url).write(s.takeChanges().resolved())
        let back = try MailDatabase(url: url).messages().sorted { $0.date > $1.date }
        #expect(back.map(\.flag) == s.messages.sorted { $0.date > $1.date }.map(\.flag))
        #expect(back.map(\.isVIP) == s.messages.sorted { $0.date > $1.date }.map(\.isVIP))
        #expect(back.map(\.conversationID) == s.messages.sorted { $0.date > $1.date }.map(\.conversationID))
    }

    // MARK: Mark All as Read batching across accounts

    @Test func markAllReadInAllInboxesBatchesPerAccount() {
        var ms: [Message] = []
        for i in 0..<250 { var m = msg(work, subject: "w\(i)"); m.remoteID = "W\(i)"; ms.append(m) }
        for i in 0..<130 { var m = msg(home, subject: "h\(i)"); m.remoteID = "H\(i)"; ms.append(m) }
        let s = store(ms)
        s.markAllRead(in: .smart(.allInboxes))
        let sizes = s.outbox.map { ($0.account == work.id ? "w" : "h") + "\($0.change.remoteIDs.count)" }
        #expect(sizes.sorted() == ["h100", "h30", "w100", "w100", "w50"], "\(sizes)")
        #expect(Set(s.outbox.flatMap(\.change.remoteIDs)).count == 380)
    }

    // MARK: Round 2b

    struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    /// The draft kept after a failed send keeps the picture where it was placed.
    @Test func failedSendKeepsPlacedPictureInItsPlace() {
        let s = store([])
        s.merge([(.inbox, [])], account: work.id)
        var d = Draft(accountID: work.id, to: "a@x.com", subject: "S", body: "Look:\n\u{FFFC}\nnice")
        d.attachments = [DraftAttachment(name: "p.png", contentType: "image/png", data: Data([1, 2]))]
        s.failed(PendingChange(account: work.id, change: .send(d), previous: []), "busy")
        let kept = s.messages.first { $0.mailbox == .drafts }
        #expect(kept?.body.contains("\u{FFFC}") == true || kept?.html?.contains("cid:") == true,
                "body: \(String(reflecting: kept?.body)), html: \(String(describing: kept?.html))")
    }

    /// Conversation answers against a brute-force reference after random actions and syncs.
    @Test func conversationMatchesReferenceUnderRandomActions() {
        for seed in UInt64(1)...30 {
            var rng = SplitMix64(state: seed)
            let boxes: [MailboxKind] = [.inbox, .drafts, .sent, .junk, .trash, .archive, .folder("P")]
            var ms: [Message] = []
            for i in 0..<120 {
                var m = msg(Bool.random(using: &rng) ? work : home, boxes.randomElement(using: &rng)!,
                            subject: "m\(i)", minutesAgo: Double(i))
                m.conversationID = ["A", "B", "C", nil].randomElement(using: &rng)!
                m.remoteID = "R\(i)"
                ms.append(m)
            }
            let s = store([])
            s.merge(ms.filter { $0.accountID == work.id }, account: work.id, mailbox: .inbox)
            s.merge(ms.filter { $0.accountID == home.id }, account: home.id, mailbox: .inbox)
            for step in 0..<40 {
                let ids = Set(s.messages.shuffled(using: &rng).prefix(Int.random(in: 1..<6, using: &rng)).map(\.id))
                switch Int.random(in: 0..<6, using: &rng) {
                case 0: s.delete(ids)
                case 1: s.archive(ids)
                case 2: s.toggleJunk(ids)
                case 3: s.move(ids, to: boxes.randomElement(using: &rng)!)
                case 4:
                    let acct = Bool.random(using: &rng) ? work : home
                    var u = s.messages.filter { $0.accountID == acct.id }.shuffled(using: &rng).prefix(3).map { m -> Message in
                        var c = m; c.conversationID = ["A", "B", nil].randomElement(using: &rng)!; return c
                    }
                    u = u.map { var c = $0; c.id = UUID(); return c }
                    s.merge(u, account: acct.id, mailbox: boxes.randomElement(using: &rng)!)
                default:
                    if let p = s.outbox.randomElement(using: &rng) { s.failed(p, "x") }
                }
                for m in s.messages.prefix(15) {
                    let got = s.conversation(of: m.id).map(\.id)
                    let skip: Set<MailboxKind> = [.trash, .junk, .drafts]
                    let want = m.conversationID == nil ? [m.id] : s.messages.filter {
                        $0.id == m.id || ($0.conversationID == m.conversationID && $0.accountID == m.accountID && !skip.contains($0.mailbox))
                    }.sorted { $0.date > $1.date }.map(\.id)
                    #expect(got == want, "seed \(seed) step \(step)")
                    #expect(Set(got).count == got.count, "duplicates seed \(seed) step \(step)")
                }
            }
        }
    }

    /// An offline send waits in the outbox; after a relaunch it still has its files.
    @Test func queuedSendKeepsItsFilesAcrossRelaunch() throws {
        let url = tempDir().appendingPathComponent("Mail.sqlite")
        let s = store([])
        s.merge([(.inbox, [])], account: work.id)
        var d = Draft(accountID: work.id, to: "bo@x.com", subject: "Report", body: "See \u{FFFC} attached")
        d.attachments = [DraftAttachment(name: "p.png", contentType: "image/png", data: Data([9, 8, 7]))]
        s.send(d)
        try MailDatabase(url: url).write(s.takeChanges().resolved())
        let back = try MailDatabase(url: url).meta().outbox
        #expect(back.count == 1)
        if case let .send(d2)? = back.first?.change { #expect(d2 == d) } else { Issue.record("no send: \(back)") }
    }
}
