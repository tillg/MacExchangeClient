import Foundation
import SQLite3
import Testing
@testable import MailModel

/// Probes for MailDatabase / MailCache / MailStore save-load. Real temp files, no mocks.
@MainActor
@Suite(.serialized)
struct Probe_DatabaseTests {
    let work = Account(name: "Work", address: "me@work.com")
    let home = Account(name: "Home", address: "me@home.com")

    func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ProbeDB-\(UUID())/Mail.sqlite")
    }

    func mail(_ subject: String, body: String = "", preview: String? = nil, from: Contact = Contact(name: "Ann", email: "ann@x.com"),
              to: [Contact] = [], account: Account? = nil, minutesAgo: Double = 0, rid: String? = nil) -> Message {
        Message(accountID: (account ?? work).id, from: from, to: to, subject: subject, body: body,
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

    // MARK: Round trips

    @Test func probeNulCharacterInSubjectAndBodySurvives() throws {
        let m = mail("before\u{0}after", body: "line one\u{0}line two")
        let (d, url) = try db([m]); defer { cleanup(url) }
        _ = d
        let back = try MailDatabase(url: url).messages()
        #expect(back.first?.subject.debugDescription == m.subject.debugDescription)
        #expect(back.first?.body.debugDescription == m.body.debugDescription)
    }

    @Test func probeNulCharacterInSearchNeverThrows() throws {
        let (d, url) = try db([mail("hello")]); defer { cleanup(url) }
        #expect(throws: Never.self) { _ = try d.search("hel\u{0}\"lo", accounts: nil) }
    }

    @Test func probeSeparatorCharactersInContactNamesSurvive() throws {
        var m = mail("sep", to: [Contact(name: "A\u{1E}B", email: "a@x.com"), Contact(name: "C", email: "c\u{1F}d@x.com")])
        m.cc = [Contact(name: "Unit\u{1F}Sep", email: "u@x.com")]
        let (_, url) = try db([m]); defer { cleanup(url) }
        let back = try MailDatabase(url: url).messages()
        #expect(back.first?.to == m.to)
        #expect(back.first?.cc == m.cc)
    }

    @Test func probeSeparatorCharactersInAttachmentNamesSurvive() throws {
        var m = mail("att")
        m.attachments = [MailModel.Attachment(name: "report\u{1E}2026.pdf", size: 10, contentType: "application/pdf"),
                         MailModel.Attachment(name: "a\u{1F}b.txt", size: 3, contentType: "text/plain")]
        m.hasAttachments = true
        let (_, url) = try db([m]); defer { cleanup(url) }
        let back = try MailDatabase(url: url).messages()
        #expect(back.first?.attachments == m.attachments)
    }

    @Test func probeEveryOddFieldShapeSurvives() throws {
        var a = mail("", body: "", preview: "")
        a.to = [Contact(name: "", email: "")]; a.cc = [Contact(name: "", email: "")]
        a.attachments = [MailModel.Attachment(name: "")]; a.html = ""; a.htmlChecked = false; a.isInvite = false
        a.conversationID = ""; a.remoteID = ""; a.flag = .gray; a.category = .promotions
        a.date = Date(timeIntervalSinceReferenceDate: -3_000_000_000.123456789)
        var b = mail("🎉 עברית العربية 日本語 \u{202E}rtl", body: String(repeating: "x😀ä", count: 2_000_000))
        b.date = Date.distantFuture; b.mailbox = .folder("weird 'id' \"q\" ; DROP TABLE messages;--")
        b.invite = Invite(start: Date(timeIntervalSinceReferenceDate: 1.0000001), end: Date(timeIntervalSinceReferenceDate: 2),
                          location: "Ünï \u{0}", isAllDay: true, organizer: nil, required: [], optional: [Contact(name: "o", email: "")],
                          response: .tentative, isCancellation: false)
        b.invite?.reply = InviteReply(response: .decline, comment: "", send: false,
                                      proposedStart: Date(timeIntervalSinceReferenceDate: 5), proposedEnd: nil)
        let (_, url) = try db([a, b]); defer { cleanup(url) }
        let back = try MailDatabase(url: url).messages()
        #expect(back.first { $0.id == a.id } == a)
        #expect(back.first { $0.id == b.id } == b)
    }

    @Test func probeHostileQueriesNeverThrow() throws {
        let (d, url) = try db([mail("Rechnung Müller c++ e-mail don't")]); defer { cleanup(url) }
        let inputs = ["\"", "\"\"\"", "-x", "AND (", "*", "NEAR(a b)", "a:b", "subject:rech", "^a", "a OR", "OR", "NOT",
                      "{subject}: x", "a\"", "\\", "'", "a'b", "c++", "(a", "a)", "+a", "a*b", "**a", "a\"*", "\u{FEFF}a",
                      "a\u{200B}b", "\u{0301}", "e\u{0301}", "😀a", "a😀", "%", "_a", "a.b.c", "NEAR", "a NEAR b",
                      "\t\n a \r", "١٢٣", "Ⅻ", "ﬁ", "ǅ", String(repeating: "a", count: 5000)]
        for q in inputs {
            #expect(throws: Never.self, "query \(q.debugDescription)") { _ = try d.search(q, accounts: nil) }
        }
    }

    @Test func probeLongPastedQueryNeverThrows() throws {
        let (d, url) = try db([mail("hello world")]); defer { cleanup(url) }
        let words = (0..<400).map { "word\($0)" }.joined(separator: " ")
        #expect(throws: Never.self) { _ = try d.search(words, accounts: nil) }
        let words2 = (0..<2000).map { "w\($0)" }.joined(separator: " ")
        #expect(throws: Never.self) { _ = try d.search(words2, accounts: nil) }
    }

    @Test func probeDecomposedQueryFindsComposedText() throws {
        let (d, url) = try db([mail("Herr M\u{00FC}ller schreibt")]); defer { cleanup(url) }
        #expect(try d.search("m\u{0075}\u{0308}ller", accounts: nil).count == 1)   // NFD typed / pasted
        #expect(try d.search("m\u{00FC}ller", accounts: nil).count == 1)
    }

    @Test func probeComposedQueryFindsDecomposedText() throws {
        let (d, url) = try db([mail("Herr Mu\u{0308}ller schreibt")]); defer { cleanup(url) }
        #expect(try d.search("m\u{00FC}ller", accounts: nil).count == 1)
        #expect(try d.search("muller", accounts: nil).count == 1)
    }

    @Test func probeGreekFinalSigma() throws {
        let (d, url) = try db([mail("ΟΔΥΣΣΕΑΣ ΝΕΑ")]); defer { cleanup(url) }
        // What MailStore sends after lowercasing the user's input.
        #expect(try d.search("ΟΔΥΣΣΕΑΣ".lowercased(), accounts: nil).count == 1)
        #expect(try d.search("οδυσσεας", accounts: nil).count == 1)
    }

    @Test func probeTurkishDottedCapitalI() throws {
        let (d, url) = try db([mail("İstanbul toplantısı"), mail("ISTANBUL meeting")]); defer { cleanup(url) }
        #expect(try d.search("İstanbul".lowercased(), accounts: nil).count == 2)
        #expect(try d.search("istanbul", accounts: nil).count == 2)
    }

    @Test func probeEmailAddressPartsAndFullAddress() throws {
        let (d, url) = try db([mail("x", from: Contact(name: "Till", email: "till.gartner@mgm-tp.com"),
                                    to: [Contact(name: "Bob O'Neil", email: "bob@x.com")])]); defer { cleanup(url) }
        for q in ["gartner", "mgm", "mgm-tp", "till.gartner@mgm-tp.com", "till.gartner@mgm-tp.co", "o'neil", "oneil", "neil"] {
            if q == "oneil" { continue }
            #expect(try d.search(q, accounts: nil).count == 1, "query \(q)")
        }
    }

    @Test func probeIndexStaysExactUnderRandomChurn() throws {
        var rng = SystemRandomNumberGenerator()
        var live: [Message.ID: Message] = [:]
        let url = tempURL(); defer { cleanup(url) }
        let d = try MailDatabase(url: url)
        var initial: [Message] = []
        for i in 0..<5000 { initial.append(mail("tok\(i)a subj", body: i % 3 == 0 ? "body\(i)b" : "", preview: "pv\(i)c", minutesAgo: Double(i))) }
        try d.write(StoreChanges(upserts: initial))
        for m in initial { live[m.id] = m }
        for round in 0..<20 {
            var ups: [Message] = [], rem: [Message.ID] = []
            for _ in 0..<200 {
                let id = live.keys.randomElement(using: &rng)!
                var m = live[id]!
                switch Int.random(in: 0..<5, using: &rng) {
                case 0: m.subject = "new\(round)x \(m.subject)"
                case 1: m.mailbox = .archive
                case 2: m.isRead.toggle()
                case 3: m.body = "loaded\(round)y"; m.bodyLoaded = true
                default: rem.append(id); live[id] = nil; continue
                }
                live[id] = m; ups.append(m)
            }
            // A removed message may also have been changed earlier in the round.
            ups.removeAll { u in rem.contains(u.id) }
            var seen = Set<Message.ID>(); ups = ups.reversed().filter { seen.insert($0.id).inserted }
            try d.write(StoreChanges(upserts: ups, removed: rem))
        }
        var raw: OpaquePointer?
        #expect(sqlite3_open(url.path, &raw) == SQLITE_OK)
        #expect(sqlite3_exec(raw, "INSERT INTO messages_fts(messages_fts, rank) VALUES('integrity-check', 1)", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(raw)
        #expect(try d.count() == live.count)
        let all = Set(try d.search("subj", accounts: nil, limit: 100_000))
        #expect(all == Set(live.keys))
    }

    @Test func probeLargeDatabaseWriteAndSearch() throws {
        let msgs = (0..<30_000).map { i in
            mail("Rechnung \(i) Projekt", preview: "Vorschau Müller \(i)",
                 to: [Contact(name: "Bob", email: "bob\(i % 50)@x.com")], account: i % 2 == 0 ? work : home, minutesAgo: Double(i))
        }
        let url = tempURL(); defer { cleanup(url) }
        let d = try MailDatabase(url: url)
        let t0 = Date()
        try d.write(StoreChanges(upserts: msgs))
        let writeTime = Date().timeIntervalSince(t0)
        let t1 = Date()
        let r = try d.search("rech mul", accounts: [work.id])
        let searchTime = Date().timeIntervalSince(t1)
        print("PROBE large: write \(writeTime)s search \(searchTime)s hits \(r.count)")
        #expect(r.count == MailDatabase.searchLimit)
        #expect(r.first == msgs[0].id)
        #expect(searchTime < 0.5)
        let t2 = Date()
        let back = try d.messages()
        print("PROBE large: load \(Date().timeIntervalSince(t2))s")
        #expect(back.count == 30_000)
    }

    // MARK: Concurrency

    @Test func probeSearchWhileBackgroundWritesRun() async throws {
        let url = tempURL(); defer { cleanup(url) }
        let d = try MailDatabase(url: url)
        try d.write(StoreChanges(upserts: (0..<2000).map { mail("seed \($0)", minutesAgo: Double($0)) }))
        let errors = ErrorBox()
        for i in 0..<50 {
            let batch = (0..<500).map { mail("bulk\(i) item\($0)", minutesAgo: Double($0)) }
            d.writeInBackground(StoreChanges(upserts: batch), failed: { errors.add("write: \($0)") })
        }
        await withTaskGroup(of: Void.self) { g in
            for k in 0..<8 {
                g.addTask {
                    for j in 0..<100 {
                        do { _ = try d.search("bulk\(j % 50) seed item\(k)", accounts: nil) } catch { errors.add("search: \(error)") }
                    }
                }
            }
        }
        _ = try d.count()  // waits for the writes
        #expect(errors.list.isEmpty, "\(errors.list.prefix(3))")
        #expect(try d.count() == 2000 + 50 * 500)
    }

    @Test func probeOriginalSchemaMigratesAndIsSearchable() throws {
        let url = tempURL(); defer { cleanup(url) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var raw: OpaquePointer?
        #expect(sqlite3_open(url.path, &raw) == SQLITE_OK)
        let acct = work.id.uuidString, id = UUID().uuidString
        #expect(sqlite3_exec(raw, """
            PRAGMA journal_mode=WAL;
            CREATE TABLE messages(
              id TEXT PRIMARY KEY, account TEXT NOT NULL, mailbox TEXT NOT NULL, remote TEXT, date REAL NOT NULL,
              read INTEGER NOT NULL, flag TEXT, from_name TEXT NOT NULL, from_email TEXT NOT NULL, to_list TEXT NOT NULL,
              cc_list TEXT NOT NULL, subject TEXT NOT NULL, body TEXT NOT NULL, category TEXT NOT NULL, bits INTEGER NOT NULL,
              attachments TEXT NOT NULL, preview TEXT, invite BLOB, html TEXT, is_invite INTEGER, html_checked INTEGER);
            CREATE INDEX messages_mailbox ON messages(account, mailbox);
            CREATE TABLE sync(account TEXT NOT NULL, mailbox TEXT NOT NULL, token TEXT, complete INTEGER NOT NULL, PRIMARY KEY(account, mailbox));
            CREATE TABLE folders(account TEXT NOT NULL, box TEXT NOT NULL, name TEXT NOT NULL, parent TEXT, position INTEGER NOT NULL);
            CREATE TABLE outbox(position INTEGER PRIMARY KEY, change BLOB NOT NULL);
            INSERT INTO messages VALUES('\(id)', '\(acct)', 'inbox', 'R1', 800000000, 0, NULL, 'Ann', 'ann@x.com', '', '',
              'Quartalsbericht Müller', '', 'primary', 0, 'a.pdf', 'Vorschau', NULL, NULL, NULL, NULL);
            INSERT INTO sync VALUES('\(acct)', 'inbox', 'tok', 1);
            """, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(raw)
        let d = try MailDatabase(url: url)
        // Written before the index exists, as the app does between opening and prepareSearch().
        let later = mail("Nachtrag Rechnung")
        try d.write(StoreChanges(upserts: [later]))
        #expect(try d.prepareSearch())
        #expect(try d.search("quartal", accounts: nil).map(\.uuidString) == [id])
        #expect(try d.search("nachtrag", accounts: nil) == [later.id])
        let back = try d.messages().first { $0.id.uuidString == id }
        #expect(back?.attachments == ["a.pdf"])
        #expect(try d.meta().sync.first?.token == nil)
        #expect(try MailDatabase(url: url).prepareSearch() == false)
    }

    // MARK: Corrupt / missing files

    @Test func probeCorruptCacheJSONDoesNotBlockTheDatabaseForever() async throws {
        let dir = tempURL().deletingLastPathComponent(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cacheURL = dir.appendingPathComponent("Cache.json"), dbURL = dir.appendingPathComponent("Mail.sqlite")
        try Data("{\"accounts\": [ truncated".utf8).write(to: cacheURL)
        // Launch after launch, as AppSetup.loadMail does: import while there is no database.
        var errors: [String] = []
        for _ in 0..<3 where !FileManager.default.fileExists(atPath: dbURL.path) {
            let s = MailStore(accounts: [work], messages: [])
            do { _ = try await MailDatabase.importCache(from: cacheURL, into: dbURL, store: s) } catch { errors.append(error.localizedDescription) }
        }
        #expect(FileManager.default.fileExists(atPath: dbURL.path), "after 3 launches: \(errors)")
    }

    @Test func probeCacheJSONRoundTripsEveryField() throws {
        let url = tempURL().deletingLastPathComponent().appendingPathComponent("Cache.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var m = mail("Ünï 🎉", body: "b\u{0}c", preview: "p")
        m.html = "<p>x</p>"; m.htmlChecked = true; m.conversationID = "C"; m.flag = .red
        m.invite = Invite(start: Date(timeIntervalSinceReferenceDate: 812_400_000.123456), end: Date(timeIntervalSinceReferenceDate: 812_403_600),
                          location: "R", isCancellation: true)
        let cache = MailCache(accounts: [work.id: .init(messages: [m], syncTokens: [.inbox: "t", .folder("x:y"): "u"],
                                                        outbox: [], complete: [.inbox], folders: [Folder(box: .folder("x:y"), name: "XY")])])
        try cache.save(to: url)
        let back = try #require(MailCache.load(from: url))
        #expect(back.accounts[work.id]?.messages == [m])
        #expect(back.accounts[work.id]?.syncTokens == [.inbox: "t", .folder("x:y"): "u"])
    }

    // MARK: MailStore save → load through the database

    @Test func probeStoreSaveAndLoadRoundTrip() throws {
        let url = tempURL(); defer { cleanup(url) }
        let d = try MailDatabase(url: url)
        let s = MailStore(accounts: [work], messages: [])
        let msgs = (0..<50).map { i in mail("m\(i)", minutesAgo: Double(i), rid: "R\(i)") }
        s.apply(SyncResult(upserts: msgs, deletedRemoteIDs: [], token: "t1", more: false), account: work.id, mailbox: .inbox)
        s.setFolders([Folder(box: .folder("f"), name: "F")], account: work.id)
        try d.write(s.takeChanges())
        let ids = s.messages.prefix(5).map(\.id)
        s.setFlag(.blue, for: Set(ids))
        s.move(Set(ids.prefix(2)), to: .archive)
        try d.write(s.takeChanges())
        // Relaunch.
        let d2 = try MailDatabase(url: url)
        let s2 = MailStore(accounts: [work], messages: [])
        s2.restore(try d2.meta())
        let first = [MailboxKey(account: work.id, mailbox: .inbox)]
        s2.restore(try d2.messages(in: first), boxes: first)
        s2.finishLoading(try d2.messages(notIn: first))
        #expect(Set(s2.messages) == Set(s.messages))
        #expect(s2.outbox == s.outbox)
        #expect(s2.folders == s.folders)
        #expect(s2.syncToken(work.id, .inbox) == "t1")
    }

    // MARK: More search probes

    @Test func probeCcAndToFieldsAreSearchable() throws {
        var m = mail("x", to: [Contact(name: "Zelda Toname", email: "zt@to.example")])
        m.cc = [Contact(name: "Quentin Ccname", email: "qc@ccdomain.example")]
        let (d, url) = try db([m]); defer { cleanup(url) }
        for q in ["toname", "zelda", "ccname", "quentin", "ccdomain", "qc"] {
            #expect(try d.search(q, accounts: nil).count == 1, "query \(q)")
        }
    }

    @Test func probeStackedDiacritics() throws {
        let (d, url) = try db([mail("Nguyễn Văn Ðức"), mail("Ångström Œuvre")]); defer { cleanup(url) }
        #expect(try d.search("nguyen van", accounts: nil).count == 1)
        #expect(try d.search("angstrom", accounts: nil).count == 1)
    }

    @Test func probeSearchWorksAfterAFailedSearchBeforeTheIndex() throws {
        let url = tempURL(); defer { cleanup(url) }
        _ = try MailDatabase(url: url)
        var raw: OpaquePointer?
        #expect(sqlite3_open(url.path, &raw) == SQLITE_OK)
        #expect(sqlite3_exec(raw, """
            DROP TRIGGER messages_fts_insert; DROP TRIGGER messages_fts_delete; DROP TRIGGER messages_fts_update;
            DROP TABLE messages_fts; DROP INDEX IF EXISTS messages_date; PRAGMA user_version = 0;
            """, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(raw)
        let d = try MailDatabase(url: url)
        try d.write(StoreChanges(upserts: [mail("Kalender Einladung")]))
        _ = try? d.search("kalender", accounts: nil)   // reader opened before the index exists
        #expect(try d.prepareSearch())
        #expect(try d.search("kalender", accounts: nil).count == 1)
    }

    // MARK: Store ↔ database differential

    struct LCG: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1442695040888963407; return state }
    }

    /// Random public mutations; after each, the changes are written and a relaunch from the database must
    /// show exactly what the store has in memory.
    @Test(arguments: [1, 2, 3, 4, 5, 6, 7, 8] as [UInt64])
    func probeStoreAndDatabaseAgreeAfterRandomMutations(seed: UInt64) throws {
        var rng = LCG(state: seed)
        let url = tempURL(); defer { cleanup(url) }
        let d = try MailDatabase(url: url)
        let s = MailStore(accounts: [work], messages: [])
        let boxes: [MailboxKind] = [.inbox, .archive, .trash, .folder("F")]
        s.setFolders([Folder(box: .folder("F"), name: "F")], account: work.id)
        var nextRid = 0
        func newRemote(_ box: MailboxKind) -> Message {
            nextRid += 1
            var m = mail("subj\(nextRid)", preview: "pv", minutesAgo: Double(nextRid), rid: "R\(nextRid)")
            m.mailbox = box
            if nextRid % 4 == 0 {
                m.invite = Invite(start: Date(timeIntervalSinceReferenceDate: 812_400_000), end: Date(timeIntervalSinceReferenceDate: 812_403_600))
                m.isInvite = true
            }
            return m
        }
        s.apply(SyncResult(upserts: (0..<30).map { _ in newRemote(.inbox) }, deletedRemoteIDs: [], token: "t0", more: false),
                account: work.id, mailbox: .inbox)
        try d.write(s.takeChanges())
        var log: [String] = []
        for step in 0..<120 {
            let ids = s.messages.map(\.id)
            func some() -> Set<Message.ID> {
                guard !ids.isEmpty else { return [] }
                return Set((0..<Int.random(in: 1...3, using: &rng)).map { _ in ids[Int.random(in: 0..<ids.count, using: &rng)] })
            }
            let op = Int.random(in: 0..<12, using: &rng)
            log.append("\(step):\(op)")
            switch op {
            case 0:
                let box = boxes[Int.random(in: 0..<boxes.count, using: &rng)]
                let inBox = s.messages.filter { $0.mailbox == box }.compactMap(\.remoteID)
                var ups = (0..<Int.random(in: 0...3, using: &rng)).map { _ in newRemote(box) }
                if let r = inBox.randomElement(using: &rng) { var m = newRemote(box); m.remoteID = r; m.subject = "changed\(step)"; ups.append(m) }
                let del = inBox.isEmpty ? [] : [inBox[Int.random(in: 0..<inBox.count, using: &rng)]]
                let reads = inBox.randomElement(using: &rng).map { [$0: Bool.random(using: &rng)] } ?? [:]
                s.apply(SyncResult(upserts: ups, deletedRemoteIDs: del, readChanges: reads, token: "t\(step)", more: Bool.random(using: &rng)),
                        account: work.id, mailbox: box)
            case 1: s.move(some(), to: boxes[Int.random(in: 0..<boxes.count, using: &rng)])
            case 2: s.delete(some())
            case 3: s.setFlag(FlagColor.allCases.randomElement(using: &rng), for: some())
            case 4: s.toggleRead(some())
            case 5: if let p = s.outbox.randomElement(using: &rng) { s.failed(p, "refused") }
            case 6:
                let rids = s.messages.compactMap(\.remoteID)
                if let r = rids.randomElement(using: &rng) { s.renameRemote([r: r + "-moved\(step)"], account: work.id) }
            case 7:
                if let id = ids.randomElement(using: &rng) {
                    s.setBody(MessageBody(text: "body \(step)", attachments: [MailModel.Attachment(name: "f\(step).pdf", size: step, contentType: "application/pdf")],
                                          html: "<p>\(step)</p>"), for: id)
                }
            case 8:
                if let inv = s.messages.first(where: { $0.invite != nil && $0.mailbox != .trash }) { s.respond(.accept, to: inv.id) }
            case 9: s.toggleJunk(some())
            case 10:
                // A failed background write: the changes go out again with the next ones.
                let c = s.takeChanges()
                s.retry(c)
            default:
                s.merge([newRemote(.archive)], account: work.id, mailbox: .archive)
            }
            try d.write(s.takeChanges())
            let d2 = try MailDatabase(url: url)
            let s2 = MailStore(accounts: [work], messages: [])
            s2.restore(try d2.meta())
            let first = [MailboxKey(account: work.id, mailbox: .inbox)]
            s2.restore(try d2.messages(in: first), boxes: first)
            s2.finishLoading(try d2.messages(notIn: first))
            let mem = Set(s.messages), disk = Set(s2.messages)
            if mem != disk || s2.outbox != s.outbox {
                let onlyMem = mem.subtracting(disk).map { "\($0.remoteID ?? "-") \($0.mailbox.rawValue) read=\($0.isRead) flag=\(String(describing: $0.flag))" }
                let onlyDisk = disk.subtracting(mem).map { "\($0.remoteID ?? "-") \($0.mailbox.rawValue) read=\($0.isRead) flag=\(String(describing: $0.flag))" }
                Issue.record("seed \(seed) diverged after \(log.suffix(4)); memory only: \(onlyMem); disk only: \(onlyDisk); outbox \(s.outbox.count) vs \(s2.outbox.count)")
                return
            }
        }
    }
}

final class ErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
    var list: [String] { lock.lock(); defer { lock.unlock() }; return items }
}
