import Foundation
import Testing
@testable import MailModel

/// Round 3 probes: search as the user experiences it, through MailStore with a real MailDatabase searcher.
@MainActor
struct Probe_Search3Tests {
    let work = Account(name: "Work", address: "me@work.com")
    let home = Account(name: "iCloud", address: "me@icloud.com")

    func msg(_ acct: Account, _ box: MailboxKind = .inbox, subject: String = "Hi", from: String = "Ann",
             body: String? = nil, read: Bool = false, minutesAgo: Double = 0, remote: String? = nil,
             preview: String? = nil, bodyLoaded: Bool = true) -> Message {
        Message(accountID: acct.id, mailbox: box, from: Contact(name: from, email: "\(from.lowercased())@x.com"),
                to: [Contact(name: "Me", email: acct.address)], subject: subject,
                body: body ?? "Body of \(subject)",
                date: Date(timeIntervalSince1970: 1_000_000 - minutesAgo * 60), isRead: read,
                remoteID: remote, serverPreview: preview, bodyLoaded: bodyLoaded)
    }

    func store(_ msgs: [Message]) -> MailStore { MailStore(accounts: [work, home], messages: msgs) }

    func tempDB() throws -> (MailDatabase, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ProbeSearch3-\(UUID())/Mail.sqlite")
        return (try MailDatabase(url: url), url)
    }

    /// The store's mail written to a real database (as the first save would), and the store searching it.
    func indexed(_ s: MailStore, accounts: [Account]) throws -> (MailDatabase, URL) {
        for a in accounts { s.merge([], account: a.id) }  // marks them as server accounts (stored)
        let (db, url) = try tempDB()
        try db.write(s.storedState())
        _ = s.takeChanges()
        s.searchDebounce = .zero
        s.searcher = { q, a in try db.search(q, accounts: a) }
        return (db, url)
    }

    func save(_ s: MailStore, _ db: MailDatabase) async throws {
        try db.write(s.takeChanges())
        s.searchAgain()
        await s.searchTask?.value
    }

    func search(_ s: MailStore, _ text: String) async {
        s.searchText = text
        await s.searchTask?.value
    }

    /// Holds searches for some queries until released.
    final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var held: [String: CheckedContinuation<Void, Never>] = [:]
        private let slow: Set<String>
        let entered: AsyncStream<String>
        private let enter: AsyncStream<String>.Continuation
        init(slow: Set<String>) { self.slow = slow; (entered, enter) = AsyncStream.makeStream() }
        func pass(_ q: String) async {
            guard slow.contains(q) else { return }
            await withCheckedContinuation { c in lock.withLock { held[q] = c }; enter.yield(q) }
        }
        func release(_ q: String) { lock.withLock { held.removeValue(forKey: q) }?.resume() }
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [String] = []
        var calls: [String] { lock.withLock { _calls } }
        func add(_ q: String) { lock.withLock { _calls.append(q) } }
    }

    // MARK: Reference model

    static func tokens(_ s: String) -> [String] {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split { !($0.isLetter || $0.isNumber) }.map(String.init)
    }

    static func matches(_ m: Message, _ query: String) -> Bool {
        let fields = [m.subject, m.from.name, m.from.email, m.body, m.serverPreview ?? ""]
            + m.to.flatMap { [$0.name, $0.email] } + m.cc.flatMap { [$0.name, $0.email] }
        let toks = fields.flatMap(tokens)
        return tokens(query).allSatisfy { w in toks.contains { $0.hasPrefix(w) } }
    }

    func reference(_ s: MailStore, _ query: String) -> [Message.ID] {
        let scope: UUID? = { if case let .account(id, _) = s.selectedMailbox { return id }; return nil }()
        return s.messages.filter { m in
            (scope == nil || m.accountID == scope) && m.mailbox != .trash && m.mailbox != .junk && Self.matches(m, query)
        }.sorted { $0.date > $1.date }.map(\.id)
    }

    struct RNG: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    static let words = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel", "india", "juliet"]

    /// After a save (and the re-search it triggers), the index answers exactly what memory holds, whatever
    /// mutations happened during the search.
    @Test(arguments: [UInt64(1), 2, 3, 4, 5, 6, 7, 8])
    func probe_savedIndexMatchesMemoryAfterRandomOps(seed: UInt64) async throws {
        var rng = RNG(state: seed)
        func phrase(_ n: Int) -> String { (0..<n).map { _ in Self.words.randomElement(using: &rng)! }.joined(separator: " ") }
        var minute = 0.0
        func next() -> Double { minute += 1; return minute }
        var remoteN = 0
        func newRemote(_ acct: Account, _ box: MailboxKind) -> Message {
            remoteN += 1
            return msg(acct, box, subject: phrase(2), from: Self.words.randomElement(using: &rng)!.capitalized,
                       body: phrase(3), minutesAgo: next(), remote: "r\(seed)-\(remoteN)", preview: phrase(2))
        }
        let boxes: [MailboxKind] = [.inbox, .archive, .sent, .drafts, .trash, .junk, .folder("f1")]
        var initial: [Message] = []
        for _ in 0..<40 {
            let a = Bool.random(using: &rng) ? work : home
            initial.append(newRemote(a, boxes.randomElement(using: &rng)!))
        }
        let s = store(initial)
        let (db, url) = try indexed(s, accounts: [work, home])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        for round in 0..<6 {
            await search(s, String(Self.words.randomElement(using: &rng)!.prefix(3)))
            for _ in 0..<12 {
                let ids = s.messages.map(\.id)
                guard let pick = ids.randomElement(using: &rng) else { break }
                let m = s.message(pick)!
                switch Int.random(in: 0..<10, using: &rng) {
                case 0: s.setFlag(.red, for: [pick])
                case 1: s.toggleRead([pick])
                case 2: s.move([pick], to: boxes.randomElement(using: &rng)!)
                case 3: s.delete([pick])
                case 4: s.toggleJunk([pick])
                case 5:
                    let a = Bool.random(using: &rng) ? work : home
                    let box = boxes.filter { $0 != .junk && $0 != .trash }.randomElement(using: &rng)!
                    s.merge([newRemote(a, box)], account: a.id, mailbox: box)
                case 6:
                    if let r = m.remoteID { s.merge([], deleted: [r], account: m.accountID, mailbox: m.mailbox) }
                case 7:
                    // The server changed the subject (summary sync of the same item).
                    if m.remoteID != nil {
                        var u = m
                        u.subject = phrase(2)
                        s.merge([u], account: m.accountID, mailbox: m.mailbox)
                    }
                case 8: s.setBody(MessageBody(text: phrase(4), attachments: []), for: pick)
                default:
                    if let r = m.remoteID { s.renameRemote([r: r + "-moved"], account: m.accountID) }
                }
            }
            try await save(s, db)
            for w in Self.words {
                let q = String(w.prefix(2 + round % 3))
                await search(s, q)
                let got = s.visibleMessages.map(\.id), want = reference(s, q)
                #expect(got == want, "seed \(seed) round \(round) query \(q): got \(got.count) want \(want.count)")
            }
        }
    }

    // MARK: Status texts

    /// A warning that was on screen (e.g. no password) is gone for good after a big search is cleared.
    @Test func probe_limitNoticeWipesEarlierWarningForGood() async throws {
        let msgs = (0..<MailDatabase.searchLimit + 5).map {
            msg(work, subject: "Note \($0)", minutesAgo: Double($0), remote: "n\($0)")
        }
        let s = store(msgs)
        let (_, url) = try indexed(s, accounts: [work])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        s.status = "No password in the Keychain for work\\me"
        await search(s, "note")
        #expect(s.status == MailStore.limitNotice)
        s.searchText = ""
        #expect(s.status == "No password in the Keychain for work\\me", "status: \(String(describing: s.status))")
    }

    // MARK: Pending answers

    /// Typed before the index was ready (memory answered), then the index arrives and the user types on: until the
    /// index answers, the list should keep the previous results, not jump back to the mailbox.
    @Test func probe_typingOnAfterIndexBecomesReadyShowsMailboxNotResults() async throws {
        let hit = msg(work, subject: "Report Q3", minutesAgo: 5, remote: "a"),
            other = msg(work, subject: "Lunch", minutesAgo: 1, remote: "b")
        let s = store([hit, other])
        s.selectedMailbox = .account(work.id, .inbox)
        s.searchText = "report"
        #expect(s.visibleMessages.map(\.subject) == ["Report Q3"])  // memory
        for a in [work] { s.merge([], account: a.id) }
        let (db, url) = try tempDB()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try db.write(s.storedState())
        let gate = Gate(slow: ["report", "report q"])
        s.searchDebounce = .zero
        s.searcher = { q, a in await gate.pass(q); return try db.search(q, accounts: a) }
        var started = gate.entered.makeAsyncIterator()
        _ = await started.next()
        #expect(s.visibleMessages.map(\.subject) == ["Report Q3"])  // memory still answers
        s.searchText = "report q"
        _ = await started.next()
        // Pending: previous results expected, not the plain Inbox (which includes "Lunch").
        #expect(s.visibleMessages.map(\.subject) == ["Report Q3"], "\(s.visibleMessages.map(\.subject))")
        gate.release("report"); gate.release("report q")
        await s.searchTask?.value
    }

    /// The index failed for one query (memory answered); while the next query is on its way the list falls
    /// back to the mailbox instead of the previous results.
    @Test func probe_afterFailedQueryNextPendingShowsMailbox() async throws {
        let hit = msg(work, subject: "Report Q3", minutesAgo: 5), other = msg(work, subject: "Lunch", minutesAgo: 1)
        let s = store([hit, other])
        s.selectedMailbox = .account(work.id, .inbox)
        let gate = Gate(slow: ["report q"])
        final class Flag: @unchecked Sendable { var fail = true }
        let flag = Flag()
        s.searchDebounce = .zero
        s.searcher = { q, _ in
            if flag.fail { throw DatabaseError(errorDescription: "busy") }
            await gate.pass(q)
            return [hit.id]
        }
        await search(s, "report")
        #expect(s.visibleMessages.map(\.subject) == ["Report Q3"])  // memory fallback
        flag.fail = false
        var started = gate.entered.makeAsyncIterator()
        s.searchText = "report q"
        _ = await started.next()
        #expect(s.visibleMessages.map(\.subject) == ["Report Q3"], "\(s.visibleMessages.map(\.subject))")
        gate.release("report q")
        await s.searchTask?.value
    }

    // MARK: Debounce

    /// A burst of keystrokes asks the index once, for the final text.
    @Test func probe_burstOfKeystrokesAsksOnce() async throws {
        let s = store([msg(work, subject: "Report", remote: "a")])
        let (db, url) = try indexed(s, accounts: [work])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let counter = Counter()
        s.searchDebounce = .milliseconds(150)
        s.searcher = { q, a in counter.add(q); return try db.search(q, accounts: a) }
        for t in ["r", "re", "rep", "repo", "repor", "report"] { s.searchText = t }
        await s.searchTask?.value
        #expect(counter.calls == ["report"])
        #expect(s.visibleMessages.map(\.subject) == ["Report"])
    }

    /// Switching between mailboxes of the same scope must not re-ask the index, and the results stay.
    @Test func probe_sameScopeSwitchKeepsResults() async throws {
        let a = msg(work, subject: "Report A", minutesAgo: 2, remote: "a"),
            b = msg(home, subject: "Report B", minutesAgo: 1, remote: "b")
        let s = store([a, b])
        let (db, url) = try indexed(s, accounts: [work, home])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let counter = Counter()
        s.searcher = { q, acc in counter.add(q); return try db.search(q, accounts: acc) }
        await search(s, "report")
        s.selectedMailbox = .smart(.flagged)
        await s.searchTask?.value
        s.selectedMailbox = .smart(.vip)
        await s.searchTask?.value
        #expect(counter.calls == ["report"])
        #expect(s.visibleMessages.map(\.subject) == ["Report B", "Report A"])
        s.selectedMailbox = .account(work.id, .sent)
        await s.searchTask?.value
        #expect(s.visibleMessages.map(\.subject) == ["Report A"])
        s.selectedMailbox = .account(work.id, .folder("x"))
        await s.searchTask?.value
        #expect(counter.calls.count == 2)
    }

    // MARK: Scope

    /// Sent, Drafts and own folders are searched; Trash and Junk aren't; a smart mailbox searches every account.
    @Test func probe_scopeAcrossMailboxes() async throws {
        let ms = [msg(work, .sent, subject: "Plan sent", minutesAgo: 1, remote: "1"),
                  msg(work, .drafts, subject: "Plan draft", minutesAgo: 2, remote: "2"),
                  msg(work, .folder("p"), subject: "Plan folder", minutesAgo: 3, remote: "3"),
                  msg(work, .trash, subject: "Plan trash", minutesAgo: 4, remote: "4"),
                  msg(work, .junk, subject: "Plan junk", minutesAgo: 5, remote: "5"),
                  msg(home, .archive, subject: "Plan home", minutesAgo: 6, remote: "6")]
        let s = store(ms)
        let (_, url) = try indexed(s, accounts: [work, home])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        await search(s, "plan")
        #expect(s.visibleMessages.map(\.subject) == ["Plan sent", "Plan draft", "Plan folder", "Plan home"])
        s.selectedMailbox = .account(home.id, .inbox)
        await s.searchTask?.value
        #expect(s.visibleMessages.map(\.subject) == ["Plan home"])
    }

    // MARK: Selection

    /// Delete in the index's results selects the next result.
    @Test func probe_deleteInResultsSelectsNext() async throws {
        let a = msg(work, subject: "Report a", minutesAgo: 1, remote: "a"),
            b = msg(work, subject: "Report b", minutesAgo: 2, remote: "b"),
            c = msg(work, subject: "Report c", minutesAgo: 3, remote: "c"),
            x = msg(work, subject: "Lunch", minutesAgo: 0, remote: "x")
        let s = store([a, b, c, x])
        let (_, url) = try indexed(s, accounts: [work])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        await search(s, "report")
        s.selection = [b.id]
        s.deleteSelection()
        #expect(s.selection == [c.id])
        #expect(s.visibleMessages.map(\.subject) == ["Report a", "Report c"])
        s.deleteSelection()
        #expect(s.selection == [a.id])
    }

    // MARK: Index lag

    /// New mail that arrived during a search is found after the next save.
    @Test func probe_newMailFoundAfterSave() async throws {
        let s = store([msg(work, subject: "Report old", minutesAgo: 10, remote: "o")])
        let (db, url) = try indexed(s, accounts: [work])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        await search(s, "report")
        s.merge([msg(work, subject: "Report new", minutesAgo: 0, remote: "n")], account: work.id, mailbox: .inbox)
        try await save(s, db)
        #expect(s.visibleMessages.map(\.subject) == ["Report new", "Report old"])
    }

    /// A message taken out of Junk is found after the save.
    @Test func probe_outOfJunkFoundAfterSave() async throws {
        let j = msg(work, .junk, subject: "Report junk", remote: "j")
        let s = store([j])
        let (db, url) = try indexed(s, accounts: [work])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        await search(s, "report")
        #expect(s.visibleMessages.isEmpty)
        s.toggleJunk([j.id])
        try await save(s, db)
        #expect(s.visibleMessages.map(\.subject) == ["Report junk"])
    }

    /// A body loaded during the search is found by its words after the save.
    @Test func probe_loadedBodyFoundAfterSave() async throws {
        let m = msg(work, subject: "Hello", body: "", remote: "h", preview: "short", bodyLoaded: false)
        let s = store([m])
        let (db, url) = try indexed(s, accounts: [work])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        await search(s, "quarterly")
        #expect(s.visibleMessages.isEmpty)
        s.setBody(MessageBody(text: "The quarterly numbers", attachments: []), for: m.id)
        try await save(s, db)
        #expect(s.visibleMessages.map(\.subject) == ["Hello"])
    }

    // MARK: Relaunch

    /// Mail saved in one session is found the same way after a relaunch (new database handle, new store,
    /// loaded in the launch order).
    @Test func probe_searchAcrossRelaunch() async throws {
        let ms = [msg(work, subject: "Report inbox", minutesAgo: 1, remote: "1"),
                  msg(work, .archive, subject: "Report archive", minutesAgo: 2, remote: "2"),
                  msg(home, subject: "Report home", minutesAgo: 3, remote: "3")]
        let s1 = store(ms)
        let (db1, url) = try indexed(s1, accounts: [work, home])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        s1.setBody(MessageBody(text: "budget figures", attachments: []), for: ms[1].id)
        try db1.write(s1.takeChanges())
        await search(s1, "report")
        let before = s1.visibleMessages.map(\.id)

        let db2 = try MailDatabase(url: url)
        let s2 = MailStore(accounts: [work, home], messages: [])
        s2.restore(try db2.meta())
        let first = [work, home].map { MailboxKey(account: $0.id, mailbox: .inbox) }
        s2.restore(try db2.messages(in: first), boxes: first)
        s2.searchText = "report"
        s2.finishLoading(try db2.messages(notIn: first))
        try db2.prepareSearch()
        s2.searchDebounce = .zero
        s2.searcher = { q, a in try db2.search(q, accounts: a) }
        await s2.searchTask?.value
        #expect(s2.visibleMessages.map(\.id) == before)
        await search(s2, "budget")
        #expect(s2.visibleMessages.map(\.subject) == ["Report archive"])
    }

    // MARK: Matching as the user types it

    /// Text stored in decomposed form (NFD, as some mailers send it) is found by the composed word the user types.
    @Test func probe_decomposedStoredTextFoundByComposedQuery() async throws {
        let m = msg(work, subject: "Gru\u{308}ße aus Mu\u{308}nchen", remote: "d")
        let s = store([m])
        let (_, url) = try indexed(s, accounts: [work])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        await search(s, "münchen")
        #expect(s.visibleMessages.count == 1)
        await search(s, "munchen")
        #expect(s.visibleMessages.count == 1)
    }

    /// A query typed in decomposed form finds composed text.
    @Test func probe_decomposedQueryFindsComposedText() async throws {
        let m = msg(work, subject: "Grüße aus München", remote: "d")
        let s = store([m])
        let (_, url) = try indexed(s, accounts: [work])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        await search(s, "Mu\u{308}nchen")
        #expect(s.visibleMessages.count == 1)
    }

    /// A pasted line break around the word: treated like spaces.
    @Test func probe_newlineAroundQueryIsIgnored() async throws {
        let m = msg(work, subject: "Report", remote: "r")
        let s = store([m])
        let (_, url) = try indexed(s, accounts: [work])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        await search(s, "report\n")
        #expect(s.visibleMessages.count == 1)
        // Memory path the same.
        let s2 = store([m])
        s2.searchText = "report\n"
        #expect(s2.visibleMessages.count == 1)
    }

    // MARK: Cache invalidation between saves

    /// Right after every mutation during an index search, the list is the last answer's hits as memory holds them
    /// now (scope, not Trash/Junk, newest first): the list cache must never serve an outdated list.
    @Test(arguments: [UInt64(11), 12, 13, 14, 15, 16])
    func probe_listFollowsEveryMutationBetweenSaves(seed: UInt64) async throws {
        var rng = RNG(state: seed)
        func phrase(_ n: Int) -> String { (0..<n).map { _ in Self.words.randomElement(using: &rng)! }.joined(separator: " ") }
        var minute = 0.0
        func next() -> Double { minute += 1; return minute }
        var remoteN = 0
        func newRemote(_ acct: Account, _ box: MailboxKind) -> Message {
            remoteN += 1
            return msg(acct, box, subject: phrase(2), from: "Ann", body: phrase(3), minutesAgo: next(),
                       remote: "r\(seed)-\(remoteN)", preview: phrase(2))
        }
        let boxes: [MailboxKind] = [.inbox, .archive, .sent, .drafts, .trash, .junk, .folder("f1")]
        var initial: [Message] = []
        for _ in 0..<50 { initial.append(newRemote(Bool.random(using: &rng) ? work : home, boxes.randomElement(using: &rng)!)) }
        let s = store(initial)
        let (db, url) = try indexed(s, accounts: [work, home])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let refs: [MailboxRef] = [.smart(.allInboxes), .smart(.flagged), .smart(.unread), .account(work.id, .inbox),
                                  .account(home.id, .archive), .account(work.id, .folder("f1"))]
        await search(s, String(Self.words.randomElement(using: &rng)!.prefix(2)))
        for step in 0..<150 {
            let ids = s.messages.map(\.id)
            guard let pick = ids.randomElement(using: &rng) else { break }
            let m = s.message(pick)!
            var op = ""
            switch Int.random(in: 0..<16, using: &rng) {
            case 0: op = "flag"; s.setFlag(.red, for: [pick])
            case 1: op = "read"; s.toggleRead([pick])
            case 2: op = "move"; s.move([pick], to: boxes.randomElement(using: &rng)!)
            case 3: op = "delete"; s.delete([pick])
            case 4: op = "junk"; s.toggleJunk([pick])
            case 5:
                op = "merge new"
                let a = Bool.random(using: &rng) ? work : home
                s.merge([newRemote(a, .inbox)], account: a.id, mailbox: .inbox)
            case 6: op = "server delete"; if let r = m.remoteID { s.merge([], deleted: [r], account: m.accountID, mailbox: m.mailbox) }
            case 7: op = "body"; s.setBody(MessageBody(text: phrase(4), attachments: []), for: pick)
            case 8: op = "select+read"; s.selection = [pick]; s.markSelectionRead()
            case 9: op = "filter"; s.filterUnread.toggle()
            case 10:
                op = "mailbox"
                s.selectedMailbox = refs.randomElement(using: &rng)!
                await s.searchTask?.value
            case 11:
                op = "refused"
                if let p = s.outbox.last { s.failed(p, "refused") }
            case 12:
                op = "deleteSelection"; s.selection = [pick]; s.deleteSelection()
            case 13:
                op = "save"
                try await save(s, db)
            case 14:
                op = "drop"
                _ = s.drop([pick], on: refs.randomElement(using: &rng)!)
            default:
                op = "query"
                await search(s, String(Self.words.randomElement(using: &rng)!.prefix(2 + step % 3)))
            }
            guard let hits = s.searchHits else { continue }
            let scope: UUID? = { if case let .account(id, _) = s.selectedMailbox { return id }; return nil }()
            let want = s.messages.filter { hits.ids.contains($0.id) && (scope == nil || $0.accountID == scope)
                && $0.mailbox != .trash && $0.mailbox != .junk }.sorted { $0.date > $1.date }.map(\.id)
            let got = s.visibleMessages.map(\.id)
            #expect(got == want, "seed \(seed) step \(step) after \(op): got \(got.count) want \(want.count)")
            if got != want { return }
        }
    }

    /// Mail imported from the old cache is searched through the index right away, by the IDs the store holds.
    @Test func probe_importedCacheIsSearchable() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ProbeSearch3Import-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = store([msg(work, subject: "Report imported", remote: "i1"),
                         msg(work, .archive, subject: "Report archived", minutesAgo: 1, remote: "i2")])
        src.merge([], account: work.id)
        let cacheURL = dir.appendingPathComponent("Cache.json")
        try JSONEncoder().encode(src.cache()).write(to: cacheURL)
        let s = MailStore(accounts: [work, home], messages: [])
        let db = try #require(try await MailDatabase.importCache(from: cacheURL, into: dir.appendingPathComponent("Mail.sqlite"), store: s))
        s.searchDebounce = .zero
        s.searcher = { q, a in try db.search(q, accounts: a) }
        await search(s, "report")
        #expect(s.status == nil, "\(String(describing: s.status))")
        #expect(s.visibleMessages.map(\.subject) == ["Report imported", "Report archived"])
    }

    // MARK: Pending first answer

    /// The first index answer is pending in an empty mailbox: the list is empty, so "No Results" shows though
    /// the search will find mail.
    @Test func probe_firstPendingAnswerInEmptyMailboxShowsNoResults() async throws {
        let archived = msg(work, .archive, subject: "Report archived", remote: "a")
        let s = store([archived])
        let (db, url) = try indexed(s, accounts: [work])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let gate = Gate(slow: ["report"])
        s.searcher = { q, a in await gate.pass(q); return try db.search(q, accounts: a) }
        s.selectedMailbox = .account(work.id, .inbox)  // empty
        var started = gate.entered.makeAsyncIterator()
        s.searchText = "report"
        _ = await started.next()
        #expect(!s.visibleMessages.isEmpty, "list while the answer is pending: \(s.visibleMessages.map(\.subject))")
        gate.release("report")
        await s.searchTask?.value
        #expect(s.visibleMessages.map(\.subject) == ["Report archived"])
    }

    /// Clearing the field while an answer is pending: the late answer changes nothing.
    @Test func probe_lateAnswerAfterClearIsDropped() async throws {
        let msgs = (0..<MailDatabase.searchLimit + 1).map { msg(work, subject: "Note \($0)", minutesAgo: Double($0), remote: "n\($0)") }
        let s = store(msgs)
        let (db, url) = try indexed(s, accounts: [work])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let gate = Gate(slow: ["note"])
        s.searcher = { q, a in await gate.pass(q); return try db.search(q, accounts: a) }
        var started = gate.entered.makeAsyncIterator()
        s.searchText = "note"
        _ = await started.next()
        let task = s.searchTask
        s.searchText = ""
        gate.release("note")
        await task?.value
        #expect(s.searchHits == nil)
        #expect(s.status == nil)
        #expect(s.visibleMessages.count == msgs.count)
    }

    /// The unread filter on, a search typed: until the answer comes the list is the filtered mailbox; afterwards
    /// the results. Turning the filter off and on again during the search doesn't change the results.
    @Test func probe_unreadFilterDuringSearch() async throws {
        let r = msg(work, subject: "Report read", read: true, minutesAgo: 1, remote: "r"),
            u = msg(work, subject: "Report unread", minutesAgo: 2, remote: "u")
        let s = store([r, u])
        let (_, url) = try indexed(s, accounts: [work])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        s.filterUnread = true
        await search(s, "report")
        let first = s.visibleMessages.map(\.subject)
        s.filterUnread = false
        let second = s.visibleMessages.map(\.subject)
        #expect(first == second)
        // Memory path the same as the index path.
        let m = store([r, u])
        m.filterUnread = true
        m.searchText = "report"
        #expect(m.visibleMessages.map(\.subject) == first)
    }
}
