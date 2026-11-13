import Foundation
import Testing
@testable import EWS
@testable import MailModel

/// Round 3, area E2E: long user scenarios through MailStore and MailDatabase across relaunches.
@MainActor
struct Probe_E2ETests {
    // Three Exchange accounts; B and C share name and address (the same mailbox set up twice, or a shared one).
    let a = Account(name: "Exchange", address: "me@work.com")
    let b = Account(name: "Exchange", address: "team@work.com")
    let c = Account(name: "Exchange", address: "team@work.com")
    var all: [Account] { [a, b, c] }
    static let proj = MailboxKind.folder("PROJ")
    static let boxes: [MailboxKind] = [.inbox, .drafts, .sent, .junk, .trash, .archive, proj]

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

    func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("probe-e2e-\(UUID().uuidString)")
            .appendingPathComponent("Mail.sqlite")
    }

    func server(_ rid: String, read: Bool = false, flagged: Bool = false, minutes: Int = 0, from: String = "Ann",
                conv: String? = nil) -> Message {
        var m = Message(accountID: UUID(), from: Contact(name: from, email: "\(from.lowercased())@x.com"),
                        to: [Contact(name: "Me", email: "me@work.com")], subject: "S \(rid)", body: "",
                        date: Date(timeIntervalSince1970: 1_700_000_000 + Double(minutes) * 60), isRead: read,
                        flag: flagged ? .red : nil, remoteID: rid, serverPreview: "p \(rid)", bodyLoaded: false)
        m.conversationID = conv
        return m
    }

    func page(_ ups: [Message], del: [String] = [], token: String = "t", more: Bool = false) -> SyncResult {
        SyncResult(upserts: ups, deletedRemoteIDs: del, token: token, more: more)
    }

    /// Saves everything, then launches again as the app does: meta, the Inboxes, then the rest.
    func relaunch(_ s: MailStore, _ db: MailDatabase, _ url: URL, accounts: [Account]? = nil) throws -> (MailStore, MailDatabase) {
        try db.write(s.takeChanges())
        let db2 = try MailDatabase(url: url)
        let s2 = MailStore(accounts: accounts ?? s.accounts, messages: [])
        let first = s2.accounts.map { MailboxKey(account: $0.id, mailbox: .inbox) }
        s2.restore(try db2.meta())
        s2.restore(try db2.messages(in: first), boxes: first)
        s2.finishLoading(try db2.messages(notIn: first))
        return (s2, db2)
    }

    func refs(_ s: MailStore) -> [MailboxRef] {
        SmartMailbox.allCases.map { .smart($0) } + s.accounts.flatMap { acct in Self.boxes.map { .account(acct.id, $0) } }
    }

    /// The README's rules for what each mailbox shows.
    func shows(_ ref: MailboxRef, _ m: Message) -> Bool {
        switch ref {
        case .smart(.allInboxes): m.mailbox == .inbox
        case .smart(.vip): m.isVIP && m.mailbox == .inbox
        case .smart(.flagged): m.flag != nil && m.mailbox != .trash
        case .smart(.unread): !m.isRead && m.mailbox == .inbox
        case let .account(id, box): m.accountID == id && m.mailbox == box
        }
    }

    // MARK: file:// fixture backend (real EWSClient/EWSBackend, no network, no fake classes)

    /// A file standing in for every server response. // file:// fixture
    func responseFile(_ xml: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ews-e2e-\(UUID().uuidString).xml")
        try Data(xml.utf8).write(to: url)
        return url
    }
    /// Every operation "succeeds" and returns nothing. // file:// fixture
    var success: String {
        """
        <?xml version="1.0" encoding="utf-8"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" \
        xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages" \
        xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types"><s:Body><m:X><m:ResponseMessages>\
        <m:R ResponseClass="Success"><m:ResponseCode>NoError</m:ResponseCode></m:R></m:ResponseMessages></m:X></s:Body></s:Envelope>
        """
    }
    func backend(_ url: URL) -> EWSBackend { EWSBackend(client: EWSClient(url: url, username: "u", password: "p")) }  // file:// fixture

    func isSend(_ p: PendingChange) -> Bool { if case .send = p.change { true } else { false } }

    // MARK: Targeted probes

    /// README: "Saving: ... only what changed: one flag change is one row". Mark All as Read on a mailbox where
    /// only one message is unread should write one row, not every message of the mailbox.
    @Test func markAllReadWritesOnlyTheMessagesItChanged() {
        let s = MailStore(accounts: [a], messages: [])
        s.apply(page((0..<1000).map { server("R\($0)", read: $0 != 7) }), account: a.id, mailbox: .inbox)
        _ = s.takeChanges()
        s.markAllRead(in: .account(a.id, .inbox))
        let written = s.takeChanges().resolved().upserts
        #expect(s.outbox.count == 1)
        #expect(written.count == 1, "Mark All as Read on 1 unread of 1,000 rewrites \(written.count) rows")
    }

    /// Same: setting the flag colour a message already has, or selecting an already read message, changes nothing.
    @Test func noOpActionsWriteNothing() {
        let s = MailStore(accounts: [a], messages: [])
        s.apply(page([server("R1", read: true, flagged: true)]), account: a.id, mailbox: .inbox)
        _ = s.takeChanges()
        let id = s.messages[0].id
        s.setFlag(.red, for: [id])
        s.selection = [id]
        s.markSelectionRead()
        s.move([id], to: .inbox)
        #expect(s.takeChanges().resolved().upserts.isEmpty)
    }

    /// With the unread filter on (Trash), two selected unread messages are marked read: they leave the list
    /// but stay selected. Delete then erases them from Trash without them being on screen.
    @Test func markingAHiddenSelectionReadDoesNotLeaveItSelectedForErase() {
        let s = MailStore(accounts: [a], messages: [])
        s.apply(page([server("T1", minutes: 2), server("T2", minutes: 1), server("T3", minutes: 0)]), account: a.id, mailbox: .trash)
        let t1 = s.messages.first { $0.remoteID == "T1" }!.id, t2 = s.messages.first { $0.remoteID == "T2" }!.id
        s.selectedMailbox = .account(a.id, .trash)
        s.filterUnread = true
        s.selection = [t1, t2]
        s.toggleRead(s.selection)  // Message ▸ Mark as Read (⇧⌘U)
        let visible = Set(s.visibleMessages.map(\.id))
        #expect(s.selection.isSubset(of: visible), "selection \(s.selection.count) not in the list of \(visible.count)")
        s.deleteSelection()
        #expect(s.message(t1) != nil && s.message(t2) != nil, "Delete erased the two hidden messages from Trash")
    }

    /// Same with the flag: in Flagged, unflagging the selected message takes it out of the list, it stays selected.
    @Test func unflaggingInFlaggedDoesNotKeepAHiddenSelection() {
        let s = MailStore(accounts: [a], messages: [])
        s.apply(page([server("F1", flagged: true, minutes: 1), server("F2", flagged: true)]), account: a.id, mailbox: .inbox)
        let f1 = s.messages.first { $0.remoteID == "F1" }!.id
        s.selectedMailbox = .smart(.flagged)
        s.selection = [f1]
        s.setFlag(nil, for: [f1])
        #expect(s.selection.isSubset(of: Set(s.visibleMessages.map(\.id))))
    }

    /// Mark All as Read while launch is still loading (Flagged spans every mailbox) leaves the mail that
    /// loads afterwards unread.
    @Test func markAllReadWhileLoadingCoversMailLoadedAfterwards() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let s = MailStore(accounts: [a], messages: [])
        let db = try MailDatabase(url: url)
        s.apply(page([server("I1", flagged: true)]), account: a.id, mailbox: .inbox)
        s.apply(page([server("R1", flagged: true), server("R2", flagged: true)]), account: a.id, mailbox: .archive)
        try db.write(s.takeChanges())
        let s2 = MailStore(accounts: [a], messages: [])
        let first = [MailboxKey(account: a.id, mailbox: .inbox)]
        s2.restore(try db.meta())
        s2.restore(try db.messages(in: first), boxes: first)
        #expect(s2.unreadCount(.smart(.flagged)) == 1)
        s2.markAllRead(in: .smart(.flagged))
        s2.finishLoading(try db.messages(notIn: first))
        #expect(s2.unreadCount(.smart(.flagged)) == 0, "\(s2.unreadCount(.smart(.flagged))) flagged still unread")
    }

    /// A failed database write is retried with the next one. If a message erased in the failed batch was
    /// brought back meanwhile (a refused delete) and saved, the retry deletes it from disk although it is in memory.
    @Test func retryOfAFailedWriteDoesNotDeleteAMessageBroughtBackMeanwhile() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let s = MailStore(accounts: [a], messages: [])
        let db = try MailDatabase(url: url)
        s.apply(page([server("T1")]), account: a.id, mailbox: .trash)
        try db.write(s.takeChanges())
        let t1 = s.messages[0].id
        s.delete([t1])  // erase from Trash, queued
        let failedBatch = s.takeChanges()  // this background write fails (disk full …)
        s.failed(s.outbox[0], "refused")  // Exchange refused the delete: the message is back
        try db.write(s.takeChanges())  // the next save goes through first
        s.retry(failedBatch)  // the failure arrives on the main actor
        try db.write(s.takeChanges())
        #expect(s.message(t1) != nil)
        let stored = try MailDatabase(url: url).messages()
        #expect(stored.contains { $0.id == t1 }, "in memory, but deleted from disk: gone after relaunch")
    }

    func error(_ code: String) -> String {  // file:// fixture
        success.replacingOccurrences(of: "<m:R ResponseClass=\"Success\"><m:ResponseCode>NoError</m:ResponseCode></m:R>",
                                     with: "<m:R ResponseClass=\"Error\"><m:MessageText>\(code) text</m:MessageText><m:ResponseCode>\(code)</m:ResponseCode></m:R>")
    }

    func waitUntil(_ cond: () -> Bool) async throws {
        for _ in 0..<500 where !cond() { try await Task.sleep(for: .milliseconds(10)) }
    }

    /// Select All ▸ Archive on an Inbox of 2,870 messages (README's size), half of them opened: the queued move
    /// holds a full copy of every message, bodies and HTML included, and every later change to the outbox
    /// (one more flag, one batch sent) rewrites all of it on the next save.
    @Test func archivingAWholeInboxKeepsTheOutboxSmall() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let s = MailStore(accounts: [a], messages: [])
        let db = try MailDatabase(url: url)
        let html = "<html><body>" + String(repeating: "<p>Quarterly numbers and some text</p>", count: 500) + "</body></html>"
        s.apply(page((0..<2870).map { i in
            var m = server("R\(i)", read: true, minutes: i)
            if i % 2 == 0 {
                m.body = String(repeating: "Plain text line of the body. ", count: 150)
                m.html = html; m.htmlChecked = true; m.bodyLoaded = true
            }
            return m
        }), account: a.id, mailbox: .inbox)
        try db.write(s.takeChanges())
        s.selectedMailbox = .account(a.id, .inbox)
        s.selection = Set(s.visibleMessages.map(\.id))
        s.archiveSelection()
        try db.write(s.takeChanges())
        s.setFlag(.red, for: [s.messages[0].id])  // one more change while offline
        let changes = s.takeChanges()
        let bytes = try (changes.outbox ?? []).reduce(0) { $0 + (try JSONEncoder().encode($1)).count }
        let start = ContinuousClock.now
        try db.write(changes)
        let t = start.duration(to: .now)
        print("PROBE outbox \(changes.outbox?.count ?? 0) changes, \(bytes / 1_000_000) MB JSON, write \(t)")
        #expect(bytes < 2_000_000, "flagging one message rewrites \(bytes / 1_000_000) MB of outbox; the save took \(t)")
    }

    /// Control: the same with summaries only (nothing opened) stays small.
    @Test func archivingAWholeInboxOfSummariesIsSmall() throws {
        let s = MailStore(accounts: [a], messages: [])
        s.apply(page((0..<2870).map { server("R\($0)", read: true, minutes: $0) }), account: a.id, mailbox: .inbox)
        s.archive(Set(s.messages.map(\.id)))
        let bytes = try s.outbox.reduce(0) { $0 + (try JSONEncoder().encode($1)).count }
        print("PROBE summaries-only outbox \(bytes / 1000) kB")
        #expect(bytes < 5_000_000)
    }

    /// With the unread filter on, a search still lists read messages.
    @Test func unreadFilterAppliesToSearchResults() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let s = MailStore(accounts: [a], messages: [])
        var r = server("R1", read: true); r.subject = "Lunch on Friday"
        var u = server("R2", read: false); u.subject = "Lunch on Monday"
        s.apply(page([r, u]), account: a.id, mailbox: .inbox)
        s.filterUnread = true
        s.searchText = "lunch"
        #expect(s.visibleMessages.map(\.remoteID) == ["R2"], "memory search: \(s.visibleMessages.map(\.remoteID))")
        // The same with the index.
        let db = try MailDatabase(url: url)
        try db.write(s.takeChanges())
        s.searcher = { q, acc in try db.search(q, accounts: acc) }
        try await waitUntil { s.searchHits != nil }
        #expect(s.visibleMessages.map(\.remoteID) == ["R2"], "index search: \(s.visibleMessages.map(\.remoteID))")
    }

    // MARK: Model-based: random sessions with saves and relaunches

    @Test(arguments: 0..<4) func randomSessionsKeepInvariantsAcrossRelaunches(chunk: Int) throws {
        var failures: [String] = []
        for seed in (chunk * 50)..<(chunk * 50 + 50) {
            if let f = try runSession(seed: seed) { failures.append(f) }
        }
        let shortest = failures.min { $0.count < $1.count } ?? ""
        #expect(failures.isEmpty, "\(failures.count) seeds failed; shortest: \(shortest)")
    }

    func runSession(seed: Int) throws -> String? {
        var g = RNG(state: UInt64(seed) &* 7919 &+ 3)
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var s = MailStore(accounts: all, messages: [])
        var db = try MailDatabase(url: url)
        var next = 0, log: [String] = []
        // Every account starts with a synced Inbox, so it counts as stored after a relaunch too.
        for acct in all {
            // B and C share remote IDs (same mailbox set up twice).
            s.apply(page((0..<3).map { server("R\($0)", read: Bool.random(using: &g), flagged: Bool.random(using: &g), minutes: $0) }),
                    account: acct.id, mailbox: .inbox)
        }
        next = 3
        func pick() -> Message? { s.messages.randomElement(using: &g) }
        func fail(_ what: String) -> String { "seed \(seed): \(what) :: \(log.suffix(25).joined(separator: "; "))" }
        for step in 0..<120 {
            let pending = Set(s.outbox.flatMap { p -> [String] in
                switch p.change {
                case let .setRead(ids, _), let .setFlagged(ids, _), let .move(ids, _), let .delete(ids): ids.map { "\(p.account)/\($0)" }
                default: []
                }
            })
            var selectionAware = false
            let hiddenBefore = s.selection.subtracting(s.visibleMessages.map(\.id))
            switch Int.random(in: 0..<18, using: &g) {
            case 0:
                let acct = all.randomElement(using: &g)!, box = Self.boxes.randomElement(using: &g)!
                var ups: [Message] = [], del: [String] = []
                for m in s.messages where m.accountID == acct.id && m.mailbox == box && !pending.contains("\(acct.id)/\(m.remoteID ?? "")") {
                    guard let rid = m.remoteID else { continue }
                    switch Int.random(in: 0..<4, using: &g) {
                    case 0: ups.append(server(rid, read: Bool.random(using: &g), flagged: m.flag != nil, minutes: Int(m.date.timeIntervalSince1970 - 1_700_000_000) / 60))
                    case 1: del.append(rid)
                    default: break
                    }
                }
                if Bool.random(using: &g) {
                    ups.append(server("R\(next)", read: Bool.random(using: &g), flagged: Bool.random(using: &g), minutes: Int.random(in: 0..<20, using: &g))); next += 1
                }
                s.apply(page(ups, del: del, token: "t\(step)"), account: acct.id, mailbox: box)
                log.append("sync \(all.firstIndex(of: acct)!)/\(box.rawValue) +\(ups.map { $0.remoteID! }) -\(del)")
            case 1: if let m = pick() { s.toggleRead([m.id]); log.append("toggleRead \(m.remoteID ?? "-")") }
            case 2: if let m = pick() { let f = FlagColor.allCases.randomElement(using: &g); let c = Bool.random(using: &g) ? f : nil; s.setFlag(c, for: [m.id]); log.append("flag \(m.remoteID ?? "-") \(c?.rawValue ?? "nil")") }
            case 3: if let m = pick() { let box = Self.boxes.randomElement(using: &g)!; s.move([m.id], to: box); log.append("move \(m.remoteID ?? "-") → \(box.rawValue)"); selectionAware = s.selection.contains(m.id) }
            case 4: if let m = pick() { s.delete([m.id]); log.append("delete \(m.remoteID ?? "-")"); selectionAware = s.selection.contains(m.id) }
            case 5:
                let r = refs(s).randomElement(using: &g)!
                s.selectedMailbox = r; s.selection = []  // as MessageViewer does
                log.append("show \(r)")
            case 6:
                if let m = s.visibleMessages.randomElement(using: &g) { s.selection = [m.id]; s.markSelectionRead(); log.append("open \(m.remoteID ?? "-")") }
            case 7:
                switch Int.random(in: 0..<3, using: &g) {
                case 0: s.deleteSelection(); log.append("deleteSelection")
                case 1: s.archiveSelection(); log.append("archiveSelection")
                default: s.junkSelection(); log.append("junkSelection")
                }
                selectionAware = true
            case 8: let r = refs(s).randomElement(using: &g)!; s.markAllRead(in: r); log.append("markAllRead \(r)")
            case 9:
                let ids = Set(s.visibleMessages.shuffled(using: &g).prefix(Int.random(in: 1...3, using: &g)).map(\.id))
                let r = refs(s).randomElement(using: &g)!
                if Bool.random(using: &g), !s.selection.isEmpty { s.drop(s.selection, on: r) } else { s.drop(ids, on: r) }
                log.append("drop on \(r)"); selectionAware = true
            case 10: try db.write(s.takeChanges()); log.append("save")
            case 11:
                let before = s
                let (s2, db2) = try relaunch(s, db, url)
                log.append("relaunch")
                if Set(before.messages) != Set(s2.messages) {
                    let lost = Set(before.messages).subtracting(s2.messages).map { "\($0.remoteID ?? "-")@\($0.mailbox.rawValue)" }
                    let extra = Set(s2.messages).subtracting(before.messages).map { "\($0.remoteID ?? "-")@\($0.mailbox.rawValue)" }
                    return fail("relaunch changed messages: lost \(lost) extra \(extra)")
                }
                if before.outbox != s2.outbox { return fail("relaunch changed the outbox \(before.outbox.count) → \(s2.outbox.count)") }
                for acct in all {
                    for box in Self.boxes where before.syncToken(acct.id, box) != s2.syncToken(acct.id, box)
                        || before.isComplete(acct.id, box) != s2.isComplete(acct.id, box) {
                        return fail("relaunch changed sync of \(box.rawValue)")
                    }
                }
                s = s2; db = db2
            case 12: s.filterUnread.toggle(); log.append("filterUnread \(s.filterUnread)")
            case 13: if let p = s.outbox.randomElement(using: &g) { s.failed(p, "refused"); log.append("failed \(p.change)") }
            case 14:
                if let m = s.messages.filter({ $0.remoteID != nil }).randomElement(using: &g) {
                    s.renameRemote([m.remoteID!: "R\(next)"], account: m.accountID); log.append("rename \(m.remoteID!) → R\(next)"); next += 1
                }
            case 15:
                let acct = all.randomElement(using: &g)!
                s.failed(PendingChange(account: acct.id, change: .send(Draft(accountID: acct.id, to: "x@y.com", subject: "D\(step)", body: "b")), previous: []), "offline")
                log.append("failed send → local draft")
            case 16: if let m = pick() { s.setBody(MessageBody(text: "body \(step)", attachments: ["f.pdf"], html: "<p>x</p>"), for: m.id); log.append("body \(m.remoteID ?? "-")") }
            default:
                if let m = pick() { s.archive([m.id]); log.append("archive \(m.remoteID ?? "-")"); selectionAware = s.selection.contains(m.id) }
            }
            // Invariants.
            if Set(s.messages.map(\.id)).count != s.messages.count { return fail("duplicate local IDs") }
            let keys = s.messages.compactMap { m in m.remoteID.map { "\(m.accountID)/\($0)" } }
            if Set(keys).count != keys.count { return fail("one server message twice") }
            for r in refs(s) {
                let want = s.messages.filter { shows(r, $0) }
                if s.count(r) != want.count || s.unreadCount(r) != want.filter({ !$0.isRead }).count {
                    return fail("count of \(r): \(s.count(r))/\(s.unreadCount(r)) vs \(want.count)/\(want.filter { !$0.isRead }.count)")
                }
            }
            let visible = Set(s.visibleMessages.map(\.id))
            let want = Set(s.messages.filter { shows(s.selectedMailbox, $0) && (!s.filterUnread || !$0.isRead) }.map(\.id))
            if !want.isSubset(of: visible) || !visible.subtracting(want).isSubset(of: s.selection) {
                return fail("list of \(s.selectedMailbox) differs from its rule")
            }
            if selectionAware && !s.selection.subtracting(visible).isSubset(of: hiddenBefore) {
                return fail("after an action the selection holds \(s.selection.subtracting(visible).count) message(s) not in the list")
            }
        }
        return nil
    }

    // MARK: Model-based: acting while launch is still loading

    /// The same actions on the Inbox, taken while launch has only loaded the Inboxes, must end where they end
    /// when everything was loaded first.
    @Test func actionsWhileLoadingEndAsAfterLoading() throws {
        var failures: [String] = []
        for seed in 0..<150 {
            var g = RNG(state: UInt64(seed) &* 31 &+ 17)
            let url = tempURL()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let s = MailStore(accounts: all, messages: [])
            let db = try MailDatabase(url: url)
            for acct in all {
                for (i, box) in Self.boxes.enumerated() {
                    s.apply(page((0..<3).map { server("R\(i)-\($0)", read: Bool.random(using: &g), flagged: Bool.random(using: &g),
                                                    minutes: Int.random(in: 0..<50, using: &g), conv: "C\($0)") }),
                            account: acct.id, mailbox: box)
                }
            }
            try db.write(s.takeChanges())
            let first = all.map { MailboxKey(account: $0.id, mailbox: .inbox) }
            let loading = MailStore(accounts: all, messages: []), loaded = MailStore(accounts: all, messages: [])
            loading.restore(try db.meta()); loaded.restore(try db.meta())
            loading.restore(try db.messages(in: first), boxes: first)
            loaded.restore(try db.messages(in: first), boxes: first)
            loaded.finishLoading(try db.messages(notIn: first))
            var log: [String] = []
            for _ in 0..<12 {
                let inbox = loading.messages.map(\.id)
                guard let id = inbox.randomElement(using: &g) else { break }
                let r = refs(loaded).randomElement(using: &g)!
                let op = Int.random(in: 0..<7, using: &g)
                for st in [loading, loaded] {
                    switch op {
                    case 0: st.toggleRead([id])
                    case 1: st.setFlag(.blue, for: [id])
                    case 2: st.move([id], to: .archive)
                    case 3: st.delete([id])
                    case 4: st.toggleJunk([id])
                    case 5: _ = st.drop([id], on: r)
                    default: st.setFlag(nil, for: [id])
                    }
                }
                log.append("op\(op)")
            }
            loading.finishLoading(try db.messages(notIn: first))
            if Set(loading.messages) != Set(loaded.messages) {
                let diff = Set(loading.messages).symmetricDifference(loaded.messages).map { "\($0.remoteID ?? "-")@\($0.mailbox.rawValue)" }
                failures.append("seed \(seed): messages differ \(diff) :: \(log)")
            } else if loading.outbox.map(\.change) != loaded.outbox.map(\.change) {
                failures.append("seed \(seed): outbox differs \(loading.outbox.map(\.change)) vs \(loaded.outbox.map(\.change)) :: \(log)")
            }
            for acct in all {
                let c1 = loading.conversation(of: loading.messages.first { $0.accountID == acct.id }!.id).count
                let c2 = loaded.conversation(of: loading.messages.first { $0.accountID == acct.id }!.id).count
                if c1 != c2 { failures.append("seed \(seed): conversation \(c1) vs \(c2)") }
            }
        }
        #expect(failures.isEmpty, "\(failures.count) seeds; first: \(failures.first ?? "")")
    }

    // MARK: Smoke

    @Test func harnessRelaunchKeepsEverything() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let s = MailStore(accounts: all, messages: [])
        let db = try MailDatabase(url: url)
        for acct in all {
            s.apply(page([server("R1"), server("R2", read: true)]), account: acct.id, mailbox: .inbox)
        }
        let (s2, _) = try relaunch(s, db, url)
        #expect(Set(s2.messages) == Set(s.messages))
    }
}
