import Foundation
import SQLite3
import Testing
@testable import MailModel

/// Round 2 probes for MailDatabase and the MailStore save/load path. Real temp files, no mocks.
@MainActor
@Suite(.serialized)
struct Probe_DB2Tests {
    let work = Account(name: "Work", address: "me@work.com")
    let home = Account(name: "Home", address: "me@home.com")

    func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ProbeDB2-\(UUID())/Mail.sqlite")
    }

    func mail(_ subject: String, body: String = "", preview: String? = nil, from: Contact = Contact(name: "Ann", email: "ann@x.com"),
              to: [Contact] = [], account: Account? = nil, box: MailboxKind = .inbox, minutesAgo: Double = 0,
              rid: String? = nil) -> Message {
        Message(accountID: (account ?? work).id, mailbox: box, from: from, to: to, subject: subject, body: body,
                date: Date(timeIntervalSinceReferenceDate: 800_000_000 - minutesAgo * 60), remoteID: rid ?? UUID().uuidString,
                serverPreview: preview, bodyLoaded: !body.isEmpty)
    }

    func db(_ msgs: [Message]) throws -> (MailDatabase, URL) {
        let url = tempURL()
        let db = try MailDatabase(url: url)
        if !msgs.isEmpty { try db.write(StoreChanges(upserts: msgs)) }
        return (db, url)
    }

    func cleanup(_ url: URL) { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    /// What `AppSetup.loadMail` does at launch.
    func launch(_ accounts: [Account], from url: URL) throws -> MailStore {
        let d = try MailDatabase(url: url)
        let s = MailStore(accounts: accounts, messages: [])
        let first = accounts.map { MailboxKey(account: $0.id, mailbox: .inbox) }
        s.restore(try d.meta())
        s.restore(try d.messages(in: first), boxes: first)
        s.finishLoading(try d.messages(notIn: first))
        return s
    }

    // MARK: Launch / accounts

    /// An account that is no longer set up: launch reads its sync positions and folders only for configured
    /// accounts (`restore(meta)` filters), but `finishLoading` takes every other row of the database.
    @Test func probeMailOfAccountNoLongerSetUpIsNotLoaded() throws {
        let url = tempURL(); defer { cleanup(url) }
        let d = try MailDatabase(url: url)
        try d.write(StoreChanges(upserts: [mail("work inbox", rid: "W1"), mail("old home inbox", account: home, rid: "H1"),
                                           mail("old home archive", account: home, box: .archive, rid: "H2")],
                                 sync: [SyncState(account: work.id, mailbox: .inbox, token: "w", complete: true),
                                        SyncState(account: home.id, mailbox: .inbox, token: "h", complete: true)],
                                 folders: [home.id: [Folder(box: .folder("hf"), name: "Home Folder")]]))
        // Next launch: only Work is set up.
        let s = try launch([work], from: url)
        #expect(s.folders[home.id] == nil)              // control: meta is filtered
        #expect(s.syncToken(home.id, .inbox) == nil)     // control
        let foreign = s.messages.filter { $0.accountID == home.id }.map(\.subject)
        #expect(foreign.isEmpty, "mail of a removed account loaded: \(foreign)")
        #expect(s.visibleMessages.map(\.subject) == ["work inbox"], "All Inboxes shows \(s.visibleMessages.map(\.subject))")
    }

    // MARK: Failed send kept in Drafts

    /// "A message that fails to send is … kept in Drafts on this Mac." Its attached files must still open
    /// after a relaunch.
    @Test func probeFailedSendDraftKeepsItsAttachmentsAfterRelaunch() async throws {
        let url = tempURL(); defer { cleanup(url) }
        let d = try MailDatabase(url: url)
        let s = MailStore(accounts: [work], messages: [])
        s.apply(SyncResult(upserts: [mail("hello", rid: "R1")], deletedRemoteIDs: [], token: "t", more: false),
                account: work.id, mailbox: .inbox)
        var draft = Draft(accountID: work.id, to: "bob@x.com", subject: "Contract", body: "see attached")
        draft.attachments = [DraftAttachment(name: "contract.pdf", contentType: "application/pdf", data: Data("PDFDATA".utf8))]
        s.send(draft)
        let p = try #require(s.outbox.first)
        s.failed(p, "The server refused")
        let kept = try #require(s.messages.first { $0.mailbox == .drafts })
        // Control: before quitting, the file opens.
        let before = await s.attachmentFile(0, of: kept.id)
        #expect(before != nil)
        if let before { try? FileManager.default.removeItem(at: before.deletingLastPathComponent().deletingLastPathComponent()) }
        try d.write(s.takeChanges())
        // Relaunch.
        let s2 = try launch([work], from: url)
        let back = try #require(s2.messages.first { $0.mailbox == .drafts })
        #expect(back.attachments.map(\.name) == ["contract.pdf"])
        let file = await s2.attachmentFile(0, of: back.id)
        #expect(file != nil, "after relaunch: \(s2.status ?? "")")
    }

    // MARK: Search query building

    /// Words the store keeps (Swift says they hold a letter or digit) but the index's tokenizer reads as
    /// punctuation: they must not empty the whole search, nor throw.
    @Test(arguments: ["Ⓐ", "ⓜ", "🄰", "Ⓜ️"])
    func probeSymbolLetterWordDoesNotEmptySearch(word: String) throws {
        let (d, url) = try db([mail("Rechnung März")]); defer { cleanup(url) }
        #expect(try d.search("rechnung", accounts: nil).count == 1)  // control
        var hits: [Message.ID] = []
        var thrown: String?
        do { hits = try d.search("rechnung \(word)", accounts: nil) } catch { thrown = "\(error)" }
        #expect(thrown == nil, "threw \(thrown ?? "")")
        #expect(hits.count == 1, "\(word.unicodeScalars.map { String($0.value, radix: 16) }) emptied the search")
    }

    // MARK: Files

    /// README: the database is readable only by you; SQLite's -wal and -shm hold the same mail.
    @Test func probeJournalFilesAreReadableOnlyByTheUser() throws {
        let (d, url) = try db([mail("secret")]); defer { cleanup(url) }
        _ = try d.search("secret", accounts: nil)
        for suffix in ["", "-wal", "-shm"] {
            let path = url.path + suffix
            guard FileManager.default.fileExists(atPath: path) else { continue }
            let perms = (try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
            #expect(perms & 0o077 == 0, "\(suffix.isEmpty ? "db" : suffix) has \(String(perms, radix: 8))")
        }
    }

    /// A second handle on the same file (as the import does) sees what the first wrote, also in search.
    @Test func probeSecondHandleSeesWritesInSearch() throws {
        let (a, url) = try db([mail("alpha")]); defer { cleanup(url) }
        let b = try MailDatabase(url: url)
        #expect(try b.search("alpha", accounts: nil).count == 1)
        try a.write(StoreChanges(upserts: [mail("bravo")]))
        #expect(try b.search("bravo", accounts: nil).count == 1)
        #expect(try b.count() == 2)
    }

    // MARK: Outbox order

    @Test func probeOutboxOrderSurvivesAcrossAccounts() throws {
        let url = tempURL(); defer { cleanup(url) }
        let d = try MailDatabase(url: url)
        var out: [PendingChange] = []
        for i in 0..<300 {
            let acct = i % 3 == 0 ? home.id : work.id
            out.append(PendingChange(account: acct, change: .setRead(["R\(i)"], i % 2 == 0), previous: []))
        }
        try d.write(StoreChanges(sync: [SyncState(account: work.id, mailbox: .inbox, token: "w", complete: true),
                                        SyncState(account: home.id, mailbox: .inbox, token: "h", complete: true)], outbox: out))
        let s = try launch([work, home], from: url)
        #expect(s.outbox == out)
    }

    // MARK: Search vs a reference model

    struct LCG: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1442695040888963407; return state }
    }

    /// Random writes and deletes; search must return exactly the reference model's matches, newest first, cut
    /// at the limit.
    @Test(arguments: [11, 12, 13, 14] as [UInt64])
    func probeSearchMatchesReferenceModel(seed: UInt64) throws {
        var rng = LCG(state: seed)
        let words = ["alpha", "alpine", "beta", "betamax", "gamma", "delta", "deltoid", "epsilon"]
        let url = tempURL(); defer { cleanup(url) }
        let d = try MailDatabase(url: url)
        var live: [Message.ID: Message] = [:]
        func text(_ m: Message) -> [String] {
            ([m.subject, m.from.name, m.from.email, m.serverPreview ?? "", m.body] + m.to.flatMap { [$0.name, $0.email] })
                .flatMap { $0.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init) }
        }
        for round in 0..<30 {
            var ups: [Message] = [], rem: [Message.ID] = []
            for _ in 0..<Int.random(in: 1...40, using: &rng) {
                if !live.isEmpty && Int.random(in: 0..<4, using: &rng) == 0 {
                    let id = live.keys.sorted(by: { $0.uuidString < $1.uuidString })[Int.random(in: 0..<live.count, using: &rng)]
                    live[id] = nil; rem.append(id); ups.removeAll { $0.id == id }
                } else {
                    let w = (0..<3).map { _ in words[Int.random(in: 0..<words.count, using: &rng)] }
                    var m = mail("\(w[0]) x\(round)", body: Bool.random(using: &rng) ? w[1] : "", preview: w[2],
                                 account: Bool.random(using: &rng) ? work : home, minutesAgo: Double(Int.random(in: 0..<100_000, using: &rng)))
                    if let id = live.keys.first, Int.random(in: 0..<3, using: &rng) == 0 { m.id = id }
                    live[m.id] = m; ups.removeAll { $0.id == m.id }; ups.append(m)
                }
            }
            try d.write(StoreChanges(upserts: ups, removed: rem))
            for q in ["alp", "beta", "delt", "gam eps", "alpha beta"] {
                let terms = q.split(separator: " ").map(String.init)
                for (scope, limit) in [(nil as Set<UUID>?, 5), ([work.id], 2000), (nil, 2000)] {
                    let expected = live.values.filter { m in
                        (scope?.contains(m.accountID) ?? true) && terms.allSatisfy { t in text(m).contains { $0.hasPrefix(t) } }
                    }.sorted { $0.date > $1.date }
                    let got = try d.search(q, accounts: scope, limit: limit)
                    let exp = Array(expected.prefix(limit))
                    // Ties in date may come in any order: compare dates in order and the sets.
                    #expect(got.compactMap { live[$0]?.date } == exp.map(\.date), "seed \(seed) round \(round) q \(q) dates")
                    if limit >= expected.count { #expect(Set(got) == Set(exp.map(\.id)), "seed \(seed) round \(round) q \(q)") }
                }
            }
        }
    }

    // MARK: Import


    // MARK: Store ↔ database differential, more operations

    /// Random operations over two server accounts (incl. drop, mark all read, invite answers, batched history
    /// pages, folder lists, failed sends); after each step the changes are written and a relaunch must show
    /// exactly what memory has: messages, outbox, folders, sync positions. The index must find every message
    /// by its subject word.
    @Test(arguments: [21, 22, 23, 24, 25, 26] as [UInt64])
    func probeRelaunchMatchesMemoryUnderMoreOperations(seed: UInt64) throws {
        var rng = LCG(state: seed)
        let url = tempURL(); defer { cleanup(url) }
        let d = try MailDatabase(url: url)
        let s = MailStore(accounts: [work, home], messages: [])
        let accts = [work, home]
        let boxes: [MailboxKind] = [.inbox, .archive, .trash, .drafts, .folder("F1"), .folder("F2")]
        var n = 0
        func newRemote(_ box: MailboxKind, _ a: Account) -> Message {
            n += 1
            var m = mail("subj\(n) word\(n % 7)", preview: "pv\(n)", account: a, box: box, minutesAgo: Double(n), rid: "R\(n)")
            if n % 3 == 0 {
                m.invite = Invite(start: Date(timeIntervalSinceReferenceDate: 812_400_000), end: Date(timeIntervalSinceReferenceDate: 812_403_600))
                m.isInvite = true
            }
            m.conversationID = "C\(n % 5)"
            return m
        }
        for a in accts {
            s.setRemoteFolders(MailboxKind.allCases.map { RemoteFolder(role: $0, id: $0.rawValue) }
                               + [RemoteFolder(role: .folder("F1"), id: "F1", name: "One"),
                                  RemoteFolder(role: .folder("F2"), id: "F2", name: "Two", parent: .folder("F1"))], account: a.id)
            s.apply(SyncResult(upserts: (0..<15).map { _ in newRemote(.inbox, a) }, deletedRemoteIDs: [], token: "t0", more: false),
                    account: a.id, mailbox: .inbox)
        }
        try d.write(s.takeChanges())
        var log: [String] = []
        for step in 0..<150 {
            let ids = s.messages.map(\.id)
            func some() -> Set<Message.ID> {
                guard !ids.isEmpty else { return [] }
                return Set((0..<Int.random(in: 1...3, using: &rng)).map { _ in ids[Int.random(in: 0..<ids.count, using: &rng)] })
            }
            let a = accts[Int.random(in: 0..<2, using: &rng)]
            let op = Int.random(in: 0..<14, using: &rng)
            log.append("\(step):\(op)")
            switch op {
            case 0:
                let box = boxes[Int.random(in: 0..<boxes.count, using: &rng)]
                let inBox = s.messages.filter { $0.mailbox == box && $0.accountID == a.id }.compactMap(\.remoteID).sorted()
                var pages: [SyncResult] = []
                for p in 0..<Int.random(in: 1...3, using: &rng) {
                    var ups = (0..<Int.random(in: 0...3, using: &rng)).map { _ in newRemote(box, a) }
                    if let r = inBox.randomElement(using: &rng) { var m = newRemote(box, a); m.remoteID = r; m.subject = "changed\(step) \(m.subject)"; ups.append(m) }
                    let del = inBox.isEmpty || Bool.random(using: &rng) ? [] : [inBox[Int.random(in: 0..<inBox.count, using: &rng)]]
                    let reads = inBox.randomElement(using: &rng).map { [$0: Bool.random(using: &rng)] } ?? [:]
                    pages.append(SyncResult(upserts: ups, deletedRemoteIDs: del, readChanges: reads, token: "t\(step).\(p)", more: Bool.random(using: &rng)))
                }
                s.apply(pages, account: a.id, mailbox: box)
            case 1: _ = s.drop(some(), on: [.smart(.flagged), .smart(.allInboxes), .account(a.id, boxes[Int.random(in: 0..<boxes.count, using: &rng)])][Int.random(in: 0..<3, using: &rng)])
            case 2: s.delete(some())
            case 3: s.markAllRead(in: [.smart(.allInboxes), .account(a.id, .archive), .smart(.flagged)][Int.random(in: 0..<3, using: &rng)])
            case 4: s.toggleRead(some())
            case 5: if let p = s.outbox.randomElement(using: &rng) { s.failed(p, "refused") }
            case 6:
                if let inv = s.messages.filter({ $0.invite != nil && $0.mailbox == .inbox }).randomElement(using: &rng) {
                    switch Int.random(in: 0..<3, using: &rng) {
                    case 0: s.respond(InviteReply(response: .tentative, comment: "c\(step)", send: Bool.random(using: &rng),
                                                  proposedStart: Date(timeIntervalSinceReferenceDate: 812_500_000),
                                                  proposedEnd: Date(timeIntervalSinceReferenceDate: 812_503_600)), to: inv.id)
                    case 1: s.removeFromCalendar(inv.id)
                    default: s.respond(.decline, to: inv.id)
                    }
                }
            case 7:
                if let id = ids.randomElement(using: &rng) {
                    s.setBody(MessageBody(text: "body \(step)", attachments: [MailModel.Attachment(name: "f\(step).pdf", size: step, contentType: "application/pdf")],
                                          to: [Contact(name: "T\(step)", email: "t\(step)@x.com")], html: "<p>\(step)</p>"), for: id)
                }
            case 8: s.setFlag(FlagColor.allCases.randomElement(using: &rng), for: some())
            case 9:
                var dr = Draft(accountID: a.id, to: "z@x.com", cc: "y@x.com", subject: "draft\(step)", body: "b")
                if Bool.random(using: &rng) { s.send(dr) } else { dr.subject = "save\(step)"; s.saveDraft(dr) }
                if let p = s.outbox.last, Bool.random(using: &rng) { s.failed(p, "nope") }
            case 10:
                let c = s.takeChanges()
                s.retry(c)
            case 11:
                let rids = s.messages.filter { $0.accountID == a.id }.compactMap(\.remoteID)
                if let r = rids.randomElement(using: &rng) { s.renameRemote([r: r + "-m\(step)"], account: a.id) }
            case 12:
                let extra = Int.random(in: 0..<2, using: &rng) == 0 ? [] : [RemoteFolder(role: .folder("F\(step)"), id: "F\(step)", name: "N\(step)")]
                s.setRemoteFolders(MailboxKind.allCases.map { RemoteFolder(role: $0, id: $0.rawValue) }
                                   + [RemoteFolder(role: .folder("F1"), id: "F1", name: "One")] + extra, account: a.id)
            default:
                s.merge([(.archive, [newRemote(.archive, a)]), (.folder("F1"), [newRemote(.folder("F1"), a)])], account: a.id)
            }
            try d.write(s.takeChanges())
            let s2 = try launch([work, home], from: url)
            let mem = Set(s.messages), disk = Set(s2.messages)
            var problems: [String] = []
            if mem != disk {
                problems.append("messages: memory only \(mem.subtracting(disk).map { "\($0.subject)|\($0.mailbox.rawValue)" }), disk only \(disk.subtracting(mem).map { "\($0.subject)|\($0.mailbox.rawValue)" })")
            }
            if s2.outbox != s.outbox { problems.append("outbox \(s.outbox.count) vs \(s2.outbox.count)") }
            if s2.folders != s.folders { problems.append("folders \(s.folders) vs \(s2.folders)") }
            for acct in accts {
                for box in boxes + [.sent, .junk] + (s.folders[acct.id] ?? []).map(\.box) {
                    if s.syncToken(acct.id, box) != s2.syncToken(acct.id, box) || s.isComplete(acct.id, box) != s2.isComplete(acct.id, box) {
                        problems.append("sync \(acct.name)/\(box.rawValue): \(String(describing: s.syncToken(acct.id, box)))/\(s.isComplete(acct.id, box)) vs \(String(describing: s2.syncToken(acct.id, box)))/\(s2.isComplete(acct.id, box))")
                    }
                }
            }
            for m in s.messages {
                guard let w = m.subject.split(separator: " ").first(where: { $0.hasPrefix("subj") || $0.hasPrefix("draft") || $0.hasPrefix("save") }) else { continue }
                let hits = try d.search(String(w), accounts: nil, limit: 100_000)
                let expected = s.messages.filter { $0.subject.split(separator: " ").contains(where: { $0 == w || ($0.hasPrefix(w) && $0 != w) }) }.map(\.id)
                if Set(hits) != Set(expected) { problems.append("search \(w): \(hits.count) vs \(expected.count)") }
            }
            if !problems.isEmpty {
                Issue.record("seed \(seed) after \(log.suffix(4)): \(problems.prefix(4))")
                return
            }
        }
    }

    // MARK: Staged launch and pending moves

    /// Deleted (moved to Trash) while offline; the move still waits in the outbox at relaunch. The Inbox is
    /// checked while the other mailboxes are still loading, and the server still has the message in its Inbox
    /// (here: read elsewhere, so the check returns it). Fully loaded, the pending move keeps it in Trash; while
    /// loading, the stored copy isn't in memory yet.
    @Test(arguments: [true, false])
    func probePendingMoveSurvivesInboxCheckDuringLaunch(staged: Bool) throws {
        let url = tempURL(); defer { cleanup(url) }
        let d = try MailDatabase(url: url)
        let s = MailStore(accounts: [work], messages: [])
        s.apply(SyncResult(upserts: [mail("keep", rid: "K"), mail("to delete", rid: "R")], deletedRemoteIDs: [], token: "t1", more: false),
                account: work.id, mailbox: .inbox)
        s.delete([s.messages.first { $0.remoteID == "R" }!.id])
        #expect(s.outbox.count == 1)
        try d.write(s.takeChanges())
        // Relaunch.
        let d2 = try MailDatabase(url: url)
        let s2 = MailStore(accounts: [work], messages: [])
        let first = [MailboxKey(account: work.id, mailbox: .inbox)]
        s2.restore(try d2.meta())
        s2.restore(try d2.messages(in: first), boxes: first)
        if !staged { s2.finishLoading(try d2.messages(notIn: first)) }
        #expect(s2.quickCheckRoles(work.id) == [.inbox])
        // The quick check of the Inbox: the server still has R there (the move hasn't gone out), now read.
        var server = mail("to delete", rid: "R"); server.isRead = true
        s2.apply(SyncResult(upserts: [server], deletedRemoteIDs: [], token: "t2", more: false), account: work.id, mailbox: .inbox)
        if staged { s2.finishLoading(try d2.messages(notIn: first)) }
        let copies = s2.messages.filter { $0.remoteID == "R" }.map(\.mailbox.rawValue)
        #expect(copies == ["trash"], "copies of the deleted message: \(copies)")
        #expect(s2.count(.account(work.id, .inbox)) == 1, "Inbox shows \(s2.count(.account(work.id, .inbox)))")
    }

    // MARK: Stale journal

    /// The user deletes Mail.sqlite to start fresh but leaves Mail.sqlite-wal (README asks for all three; the
    /// import path removes leftovers itself). A new database must not pick up the old journal.
    @Test func probeLeftoverJournalDoesNotCorruptAFreshDatabase() throws {
        let url = tempURL(); defer { cleanup(url) }
        let fm = FileManager.default
        let saved = url.deletingLastPathComponent().appendingPathComponent("saved")
        try fm.createDirectory(at: saved, withIntermediateDirectories: true)
        do {
            let d = try MailDatabase(url: url)
            try d.write(StoreChanges(upserts: (0..<300).map { mail("old \($0)", body: String(repeating: "x", count: 500)) }))
            for suffix in ["-wal", "-shm"] where fm.fileExists(atPath: url.path + suffix) {
                try fm.copyItem(atPath: url.path + suffix, toPath: saved.appendingPathComponent(suffix).path)
            }
        }
        // Closed. Now only Mail.sqlite goes; the journal files of the last session stay (as after a crash).
        try fm.removeItem(at: url)
        for suffix in ["-wal", "-shm"] {
            try? fm.removeItem(atPath: url.path + suffix)
            if fm.fileExists(atPath: saved.appendingPathComponent(suffix).path) {
                try fm.copyItem(atPath: saved.appendingPathComponent(suffix).path, toPath: url.path + suffix)
            }
        }
        #expect(fm.fileExists(atPath: url.path + "-wal"))
        var err: String?
        do {
            let d = try MailDatabase(url: url)
            try d.write(StoreChanges(upserts: [mail("new mail")]))
            let back = try MailDatabase(url: url).messages()
            #expect(back.map(\.subject) == ["new mail"], "fresh database holds \(back.count) messages")
            #expect(try d.search("new", accounts: nil).count == 1)
        } catch { err = "\(error)" }
        #expect(err == nil, "\(err ?? "")")
    }

    // MARK: Speed at the real size

    /// Spec acceptance: results within 250 ms of the last keystroke, 150 ms of it the debounce. A short prefix
    /// that many messages share ("re" for every reply) at 180,000 messages.
    @Test func probeShortPrefixSearchAtRealSize() throws {
        let url = tempURL(); defer { cleanup(url) }
        let d = try MailDatabase(url: url)
        let words = ["Rechnung", "Projekt", "Meeting", "Angebot", "Termin", "Bericht", "Status", "Update"]
        var batch: [Message] = []
        for i in 0..<180_000 {
            let w = words[i % words.count]
            batch.append(mail((i % 2 == 0 ? "Re: " : "AW: ") + "\(w) \(i)", preview: "Hallo zusammen, anbei \(w) und mehr Text \(i)",
                              to: [Contact(name: "Team", email: "team\(i % 40)@mgm-tp.com")], account: i % 3 == 0 ? home : work,
                              minutesAgo: Double(i)))
            if batch.count == 20_000 { try d.write(StoreChanges(upserts: batch)); batch = [] }
        }
        if !batch.isEmpty { try d.write(StoreChanges(upserts: batch)) }
        _ = try d.search("warmup", accounts: nil)
        var timings: [String] = []
        for q in ["re", "r", "a", "rechnung", "re rechnung"] {
            let t0 = Date()
            let r = try d.search(q, accounts: nil)
            let ms = Date().timeIntervalSince(t0) * 1000
            timings.append("\(q): \(Int(ms)) ms, \(r.count) hits")
        }
        print("PROBE timings \(timings)")
        for t in timings {
            let ms = Int(t.split(separator: ":")[1].split(separator: " ")[0])!
            #expect(ms < 100, "\(t)")
        }
    }

    // MARK: Store search through the index, scopes

    /// Spec: while the hits for the current query haven't arrived, keep showing the previous results; never
    /// flash an empty list. Switching from one account's mailbox to another's with the same search text.
    @Test func probeSwitchingAccountScopeDoesNotFlashEmptyResults() async throws {
        let w = mail("Report work", rid: "W"), h = mail("Report home", account: home, rid: "H")
        let (d, url) = try db([w, h]); defer { cleanup(url) }
        let s = MailStore(accounts: [work, home], messages: [w, h])
        s.searchDebounce = .zero
        s.searcher = { q, a in try d.search(q, accounts: a) }
        s.selectedMailbox = .account(work.id, .inbox)
        s.searchText = "report"
        await s.searchTask?.value
        #expect(s.visibleMessages.map(\.subject) == ["Report work"])
        s.searchDebounce = .milliseconds(150)
        s.selectedMailbox = .account(home.id, .inbox)
        // During the pause and the query: what does the list show?
        let meanwhile = s.visibleMessages.map(\.subject)
        await s.searchTask?.value
        #expect(s.visibleMessages.map(\.subject) == ["Report home"])
        #expect(!meanwhile.isEmpty, "the list is empty (No Results) until the new answer arrives")
    }

    /// Smart mailboxes search every account; an account mailbox only its own. Same query, all scopes, against
    /// the in-memory reference (word prefix, not Trash/Junk).
    @Test func probeEveryScopeAgreesWithMemory() async throws {
        var msgs: [Message] = []
        for (i, a) in [work, home, work, home, work].enumerated() {
            for box in [MailboxKind.inbox, .archive, .trash, .junk, .sent, .drafts, .folder("F")] {
                var m = mail("Budget \(box.rawValue) \(i)", account: a, box: box, minutesAgo: Double(i * 10 + box.rawValue.count), rid: "R\(i)\(box.rawValue)")
                if i % 2 == 0 { m.flag = .red }
                if i == 1 { m.isVIP = true }
                msgs.append(m)
            }
        }
        let (d, url) = try db(msgs); defer { cleanup(url) }
        let s = MailStore(accounts: [work, home], messages: msgs)
        s.searchDebounce = .zero
        s.searcher = { q, a in try d.search(q, accounts: a) }
        let refs: [MailboxRef] = SmartMailbox.allCases.map { .smart($0) } + [work, home].flatMap { a in
            [MailboxKind.inbox, .archive, .trash, .junk, .folder("F")].map { MailboxRef.account(a.id, $0) } }
        for ref in refs {
            s.selectedMailbox = ref
            s.searchText = "budg"
            await s.searchTask?.value
            let scope: UUID? = { if case let .account(id, _) = ref { return id }; return nil }()
            let expected = msgs.filter { (scope == nil || $0.accountID == scope) && $0.mailbox != .trash && $0.mailbox != .junk }
                .sorted { $0.date > $1.date }.map(\.id)
            #expect(s.visibleMessages.map(\.id) == expected, "\(ref)")
            s.searchText = ""
        }
    }

    // MARK: Tokens

    /// README: the start of words matches. Chinese and Japanese write without spaces, so the tokenizer sees a
    /// whole sentence as one "word": a word inside it is never found (the old search found it).
    @Test func probeWordInsideChineseOrJapaneseSentence() throws {
        let (d, url) = try db([mail("明天的会议取消了"), mail("会議の議事録を送ります")]); defer { cleanup(url) }
        #expect(try d.search("明天", accounts: nil).count == 1)   // control: start of the run
        #expect(try d.search("会议", accounts: nil).count == 1, "会议 (meeting) inside a sentence")
        #expect(try d.search("議事録", accounts: nil).count == 1, "議事録 (minutes) inside a sentence")
    }

    /// Hyphens, apostrophes, dots, @ and digits in what the user types, as Mail matches them.
    @Test(arguments: [
        ("e-mail", "Your e-mail address"), ("mgm-tp", "From x@mgm-tp.com"), ("o'neil", "Bob O'Neil writes"),
        ("o’neil", "Bob O'Neil writes"), ("v2.5", "Release v2.5.1 notes"), ("@mgm", "x@mgm-tp.com"),
        ("till.gartner@mgm-tp.com", "to till.gartner@mgm-tp.com"), ("2026-11", "Invoice 2026-11-12"), ("#4711", "Ticket #4711"),
        ("1.000,50", "Betrag 1.000,50 EUR"), ("re:", "Re: lunch"), ("c#", "C# developer"), ("don't", "I don’t know"),
    ])
    func probeTokensWithPunctuation(query: String, subject: String) throws {
        let (d, url) = try db([mail(subject)]); defer { cleanup(url) }
        #expect(try d.search(query, accounts: nil).count == 1, "\(query) in \(subject)")
    }

    // MARK: Upgrades

    /// Every Cache.json comes from before conversations (it predates the database). README: "A database from
    /// before conversations syncs every folder once more from the start so existing mail learns its
    /// conversation." The import keeps the cache's sync positions, so imported mail never learns it.
    @Test func probeImportedCacheSyncsAgainToLearnConversations() async throws {
        let dir = tempURL().deletingLastPathComponent(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cacheURL = dir.appendingPathComponent("Cache.json"), dbURL = dir.appendingPathComponent("Mail.sqlite")
        let old = MailStore(accounts: [work], messages: [])
        old.apply(SyncResult(upserts: [mail("A", rid: "A"), mail("B", rid: "B")], deletedRemoteIDs: [], token: "T-old", more: false),
                  account: work.id, mailbox: .inbox)
        #expect(old.messages.allSatisfy { $0.conversationID == nil })
        try old.cache().save(to: cacheURL)
        let s = MailStore(accounts: [work], messages: [])
        let d = try #require(try await MailDatabase.importCache(from: cacheURL, into: dbURL, store: s))
        // Control: a database from before conversations starts over.
        #expect(s.messages.count == 2)
        #expect(s.syncToken(work.id, .inbox) == nil && !s.isComplete(work.id, .inbox),
                "imported store: token \(s.syncToken(work.id, .inbox) ?? "nil"), complete \(s.isComplete(work.id, .inbox))")
        let stored = try d.meta().sync
        #expect(stored.allSatisfy { $0.token == nil && !$0.complete }, "stored sync: \(stored)")
    }

    /// The body brings the full sender and recipients ("list summaries may lack email addresses"). A later
    /// update of the same message from the server (here the from-scratch re-sync after the upgrade; also any
    /// change made elsewhere) keeps body, attachments and invite, but puts back the summary's recipients.
    @Test func probeResyncKeepsAddressesLoadedWithTheBody() throws {
        let s = MailStore(accounts: [work], messages: [])
        var summary = mail("Plan", rid: "R1")
        summary.from = Contact(name: "Bob Builder", email: "")
        summary.to = [Contact(name: "Me", email: ""), Contact(name: "Carol", email: "")]
        summary.cc = [Contact(name: "Dan", email: "")]
        s.apply(SyncResult(upserts: [summary], deletedRemoteIDs: [], token: "T1", more: false), account: work.id, mailbox: .inbox)
        let id = s.messages[0].id
        s.setBody(MessageBody(text: "Hi all", attachments: [], from: Contact(name: "Bob Builder", email: "bob@x.com"),
                              to: [Contact(name: "Me", email: "me@work.com"), Contact(name: "Carol", email: "carol@x.com")],
                              cc: [Contact(name: "Dan", email: "dan@x.com")]), for: id)
        #expect(s.message(id)?.to.map(\.email) == ["me@work.com", "carol@x.com"])
        // The server sends the summary again (read on the phone, or a sync from the start).
        var again = summary; again.isRead = true; again.conversationID = "C1"
        s.apply(SyncResult(upserts: [again], deletedRemoteIDs: [], token: "T2", more: false), account: work.id, mailbox: .inbox)
        let m = try #require(s.message(id))
        #expect(m.body == "Hi all")  // control: the body is kept
        #expect(m.from.email == "bob@x.com", "from: \(m.from)")
        #expect(m.to.map(\.email) == ["me@work.com", "carol@x.com"], "to: \(m.to.map(\.email))")
        #expect(m.cc.map(\.email) == ["dan@x.com"], "cc: \(m.cc.map(\.email))")
        // What Reply All would address.
        let reply = s.draft(.replyAll, to: id)
        #expect(reply.to.contains("carol@x.com") && reply.to.contains("bob@x.com"), "reply all to: \(reply.to.debugDescription)")
    }

    /// README: "Case and accents don't matter (`muller` finds "Müller")". Accented letters of other scripts.
    @Test(arguments: [("καλημερα", "Καλημέρα σας"), ("αθηνα", "Ταξίδι στην Αθήνα"), ("ελληνικα", "ΕΛΛΗΝΙΚΆ"),
                      ("cafe", "Café"), ("zurich", "Zürich"), ("sao", "São Paulo")])
    func probeAccentsOfOtherScripts(query: String, subject: String) throws {
        let (d, url) = try db([mail(subject)]); defer { cleanup(url) }
        #expect(try d.search(query, accounts: nil).count == 1, "\(query) → \(subject)")
    }

    // MARK: Folder state

    /// A folder of the user's own is deleted on the server (Outlook: Shift-Delete, or emptied from Deleted
    /// Items). The next folder list drops it from the sidebar, but its mail stays in memory and on disk for good:
    /// it shows in search results and in Flagged, under a mailbox that no longer exists.
    @Test func probeMailOfFolderDeletedOnServerGoesAway() async throws {
        let url = tempURL(); defer { cleanup(url) }
        let d = try MailDatabase(url: url)
        let s = MailStore(accounts: [work], messages: [])
        let all = MailboxKind.allCases.map { RemoteFolder(role: $0, id: $0.rawValue) }
        s.setRemoteFolders(all + [RemoteFolder(role: .folder("P"), id: "P", name: "Projekt")], account: work.id)
        var m = mail("Projekt Budget", box: .folder("P"), rid: "P1"); m.flag = .red
        s.apply(SyncResult(upserts: [m], deletedRemoteIDs: [], token: "tp", more: false), account: work.id, mailbox: .folder("P"))
        try d.write(s.takeChanges())
        // The folder is gone on the server.
        s.setRemoteFolders(all, account: work.id)
        try d.write(s.takeChanges())
        #expect(s.children(of: nil, account: work.id).isEmpty)  // control: gone from the sidebar
        s.searchDebounce = .zero
        s.searcher = { q, a in try d.search(q, accounts: a) }
        s.searchText = "budget"
        await s.searchTask?.value
        #expect(s.visibleMessages.isEmpty, "search shows mail of the deleted folder: \(s.visibleMessages.map(\.subject))")
        s.searchText = ""
        s.selectedMailbox = .smart(.flagged)
        #expect(s.visibleMessages.isEmpty, "Flagged shows \(s.visibleMessages.map { "\($0.subject) in \($0.mailbox.rawValue)" })")
        #expect(try MailDatabase(url: url).count() == 0, "rows of the deleted folder kept on disk")
    }

    /// README "To go back": delete Mail.sqlite* and rename Cache.json.imported to Cache.json. A user who copies
    /// it back instead (keeping the .imported file) upgrades again: the database is built and put in place, then
    /// renaming the cache fails, the import reports an error and the session runs without saving.
    @Test func probeImportWhenAnImportedCacheIsAlreadyThere() async throws {
        let dir = tempURL().deletingLastPathComponent(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cacheURL = dir.appendingPathComponent("Cache.json"), dbURL = dir.appendingPathComponent("Mail.sqlite")
        let old = MailStore(accounts: [work], messages: [])
        old.apply(SyncResult(upserts: [mail("A", rid: "A")], deletedRemoteIDs: [], token: "t", more: false), account: work.id, mailbox: .inbox)
        try old.cache().save(to: cacheURL)
        try FileManager.default.copyItem(at: cacheURL, to: cacheURL.appendingPathExtension("imported"))
        let s = MailStore(accounts: [work], messages: [])
        var err: String?
        do { _ = try await MailDatabase.importCache(from: cacheURL, into: dbURL, store: s) } catch { err = error.localizedDescription }
        #expect(err == nil, "import: \(err ?? "")")
        #expect(FileManager.default.fileExists(atPath: dbURL.path) == (err == nil), "database in place although the import failed")
    }
}
