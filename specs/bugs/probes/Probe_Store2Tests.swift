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

    /// A failed Save Draft must not tell the user that a message couldn't be *sent*.
    @Test func failedSaveDraftDoesNotSayCouldntSend() {
        let s = store([])
        s.merge([(.inbox, [])], account: work.id)
        let d = Draft(accountID: work.id, to: "bo@x.com", subject: "Plan", body: "draft text")
        s.failed(PendingChange(account: work.id, change: .saveDraft(d), previous: []), "busy")
        #expect(s.status?.contains("send") != true, "status: \(s.status ?? "nil")")
    }


    // MARK: Reply before body loaded

    /// Reply from the list's context menu on a server message that was never opened: only the summary is there.
    @Test func replyToUnopenedServerMessageHasAddressAndQuote() {
        let s = store([])
        s.merge([summary(work, "A")], account: work.id, mailbox: .inbox)
        let id = s.messages[0].id
        let d = s.draft(.reply, to: id)
        #expect(d.to.contains("@"), "to: '\(d.to)'")
        #expect(d.body.contains("Friday"), "body: \(d.body)")
    }

    @Test func forwardOfUnopenedServerMessageQuotesIt() {
        let s = store([])
        s.merge([summary(work, "A")], account: work.id, mailbox: .inbox)
        let d = s.draft(.forward, to: s.messages[0].id)
        #expect(d.body.contains("Friday"), "body: \(d.body)")
    }

    // MARK: Invites

    /// Respond with Comments, then the invite is gone (sync deleted it / erased) before Send: the comment and
    /// the answer silently vanish.
    @Test func answerDraftForVanishedInviteIsNotSilentlyDropped() {
        var m = msg(work); m.remoteID = "INV"; m.invite = invite(); m.isInvite = true
        let s = store([m])
        s.merge([(.inbox, [])], account: work.id)
        var d = s.answerDraft(.decline, to: m.id)
        d.body = "Sorry, I am out that week."
        s.merge([], deleted: ["INV"], account: work.id, mailbox: .inbox)  // removed elsewhere meanwhile
        s.send(d)
        #expect(!s.outbox.isEmpty || s.status != nil, "outbox: \(s.outbox.count), status: \(s.status ?? "nil")")
    }


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

    /// An Exchange account whose password is missing (connected without a backend) is not sample data: signing in
    /// a second account must not remove it while its mail stays in All Inboxes.
    @Test func removeLocalAccountsKeepsExchangeAccountWithoutPassword() {
        var r = msg(work); r.remoteID = "R1"
        let sample = msg(home, subject: "sample")
        let s = MailStore(accounts: [work, home], messages: [sample])
        s.merge([r], account: work.id, mailbox: .inbox)  // work's mail came from the server (or the database)
        s.removeLocalAccounts()
        let orphans = s.messages.filter { m in !s.accounts.contains { $0.id == m.accountID } }
        #expect(orphans.isEmpty, "messages without account: \(orphans.count); accounts: \(s.accounts.map(\.name))")
    }

    /// The same account's draft kept after a failed send (local, stored) is dropped from memory but not from disk.
    @Test func removeLocalAccountsDoesNotDropStoredDraftsOnlyFromMemory() {
        let s = MailStore(accounts: [work, home], messages: [])
        s.merge([(.inbox, [])], account: work.id)  // work: Exchange account (here without password/backend)
        s.failed(PendingChange(account: work.id, change: .send(Draft(accountID: work.id, to: "a@x.com", subject: "S")),
                               previous: []), "busy")
        let kept = s.messages[0].id
        _ = s.takeChanges()
        s.removeLocalAccounts()
        let removed = s.takeChanges().removed
        #expect(s.message(kept) != nil || removed.contains(kept),
                "in memory: \(s.message(kept) != nil), removed from disk: \(removed.contains(kept))")
    }

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




    @Test func failedSendWithEmptySubjectNamesIt() {
        let s = store([])
        s.merge([(.inbox, [])], account: work.id)
        s.failed(PendingChange(account: work.id, change: .send(Draft(accountID: work.id, to: "a@x.com", body: "b")), previous: []), "busy")
        #expect(s.status?.contains("“”") != true, "status: \(s.status ?? "nil")")
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

    /// Sending from an account that is no longer there (sample account removed by signing in) must not
    /// silently send from the remaining Exchange account.
    @Test func draftOfRemovedSampleAccountIsNotSentFromExchange() {
        let s = store([msg(home, subject: "sample")])
        let d = Draft(accountID: home.id, to: "bo@x.com", subject: "Test", body: "written in sample mode")
        let exchange = Account(name: "Exchange", address: "me@corp.com")
        s.removeLocalAccounts()  // sign-in: sample accounts go
        s.accounts.append(exchange)
        s.merge([(.inbox, [])], account: exchange.id)  // the Exchange account (server mail)
        s.send(d)
        let queued = s.outbox.filter { if case .send = $0.change { return true }; return false }
        #expect(queued.isEmpty, "queued sends: \(queued.map { s.account($0.account)?.name ?? "?" })")
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

    /// Forward of an Exchange message whose files can't be fetched (body not loaded, account without
    /// connection): the forward must not become sendable without its files, silently.
    @Test func forwardWhoseFilesCannotLoadIsNotSilentlySendable() async {
        var m = summary(work, "A", subject: "Contract")
        m.hasAttachments = true
        let s = store([])
        s.merge([m], account: work.id, mailbox: .inbox)
        var d = s.draft(.forward, to: s.messages[0].id)
        #expect(d.loadingOriginal != nil)
        await s.includeOriginalAttachments(in: &d)
        #expect(d.loadingOriginal != nil || !d.attachments.isEmpty || s.status != nil,
                "loadingOriginal: \(String(describing: d.loadingOriginal)), files: \(d.attachments.count), status: \(s.status ?? "nil")")
    }

    /// One of two files can't be loaded: the forward is released with only the other one.
    @Test func forwardWithOneUnavailableFileStaysBlocked() async {
        var m = msg(work, subject: "Two files"); m.attachments = ["a.pdf", "b.pdf"]
        let s = store([m])
        s.downloadsFolder = tempDir()
        s.setAttachmentData([Data([1])], for: m.id)  // b.pdf's content can't be had
        var d = s.draft(.forward, to: m.id)
        await s.includeOriginalAttachments(in: &d)
        #expect(d.attachments.count == 2 || d.loadingOriginal != nil,
                "files: \(d.attachments.map(\.name)), loadingOriginal: \(String(describing: d.loadingOriginal)), status: \(s.status ?? "nil")")
    }

    /// Include Attachments With Replies ▸ When Adding Recipients: replying to the original sender of an unopened
    /// message is not "adding a recipient".
    @Test func replyToSenderOfUnopenedMessageIsNotANewRecipient() {
        var m = summary(work, "A"); m.hasAttachments = true
        let s = store([])
        s.merge([m], account: work.id, mailbox: .inbox)
        var d = s.draft(.reply, to: s.messages[0].id)
        d.to = "Ann Lee <ann@x.com>"  // the sender, typed by hand because To was empty
        s.setBody(MessageBody(text: "Hi", attachments: ["a.pdf"], from: Contact(name: "Ann Lee", email: "ann@x.com")),
                  for: s.messages[0].id)  // what the server really has
        let afterLoad = s.addsNewRecipient(d)
        // Same question before the body was loaded:
        let s2 = store([])
        s2.merge([m], account: work.id, mailbox: .inbox)
        var d2 = s2.draft(.reply, to: s2.messages[0].id); d2.to = "Ann Lee <ann@x.com>"
        #expect(afterLoad == false)
        #expect(s2.addsNewRecipient(d2) == false)
    }

    /// Moving a picture to another place in the text is a change: closing the window must ask.
    @Test func movingAPlacedPictureIsAChange() {
        var d = Draft(accountID: work.id, to: "a@x.com", subject: "S", body: "\u{FFFC}Hello world")
        d.attachments = [DraftAttachment(name: "p.png", contentType: "image/png", data: Data([1]))]
        let start = d
        d.body = "Hello world\u{FFFC}"
        #expect(d.hasChanges(since: start))
    }
}
