import Foundation
import Testing
@testable import MailModel

/// 180,000 messages over 2 accounts and 300 folders, as the README describes the real database.
/// Debug build. Budget: 0.25 s per user action (MailStorePerformanceTests.limit).
enum Perf4Fixture {
    static let work = Account(name: "Work", address: "me@work.com")
    static let home = Account(name: "Home", address: "me@home.com")
    static let limit = 0.25

    /// Exchange-like long IDs.
    static func exid(_ prefix: String, _ n: Int) -> String {
        "AAMkADk2YjNhZjM0LTQ5ZjEtNDYxMC05ZmQ1LWVlYjE1ZTcwNzhhOQBGAAAAAAB" + prefix + String(n) + String(repeating: "A", count: 60) + "="
    }

    /// 150 folders per account: 30 top-level, each with 4 subfolders.
    static func folders(_ acct: Int) -> [Folder] {
        var out: [Folder] = []
        for t in 0..<30 {
            let top = MailboxKind.folder(exid("F\(acct)T", t))
            out.append(Folder(box: top, name: "Project \(t)"))
            for c in 0..<4 { out.append(Folder(box: .folder(exid("F\(acct)T\(t)C", c)), name: "Sub \(c)", parent: top)) }
        }
        return out
    }

    struct Plan { let acct: Account; let boxes: [(MailboxKind, Int)] }

    static let plans: [Plan] = {
        let fw = folders(0).map(\.box), fh = folders(1).map(\.box)
        // Work: 140,000; Home: 40,000.
        let w: [(MailboxKind, Int)] = [(.inbox, 2_900), (.drafts, 300), (.sent, 54_000), (.trash, 11_800), (.archive, 30_000), (.junk, 400)]
            + fw.map { ($0, 270) }   // 150 * 270 = 40,500  -> 99,400 + 40,500 = 139,900
        let h: [(MailboxKind, Int)] = [(.inbox, 3_000), (.drafts, 100), (.sent, 10_000), (.trash, 5_000), (.archive, 0), (.junk, 900)]
            + fh.map { ($0, 140) }   // 150 * 140 = 21,000 -> 19,000 + 21,000 = 40,000
        return [Plan(acct: work, boxes: w), Plan(acct: home, boxes: h)]
    }()

    /// Inboxes first (launch step 2), then everything else mailbox by mailbox (launch step 3).
    static let base: [Message] = {
        var inbox: [Message] = [], rest: [Message] = []
        inbox.reserveCapacity(6_000); rest.reserveCapacity(175_000)
        var n = 0
        for (ai, p) in plans.enumerated() {
            for (box, count) in p.boxes {
                for _ in 0..<count {
                    n += 1
                    let loaded = n % 10 == 0
                    var m = Message(accountID: p.acct.id, mailbox: box,
                                    from: Contact(name: "Sender \(n % 700)", email: "sender\(n % 700)@example.com"),
                                    to: [Contact(name: "Me", email: p.acct.address)],
                                    subject: "Subject line number \(n)", body: loaded ? String(repeating: "Body text \(n). ", count: 60) : "",
                                    date: Date(timeIntervalSince1970: 1_600_000_000 + Double(n) * 600),  // ascending in array order: the best case for the list sort (real order unverified; `newest` returns descending)
                                    isRead: n % 25 != 0, flag: n % 150 == 0 ? .red : nil, isVIP: n % 90 == 0,
                                    remoteID: exid("M\(ai)", n), serverPreview: "Preview of message \(n)", bodyLoaded: loaded)
                    m.conversationID = "AAQkADk2YjNhZjM0LTQ5ZjEtNDYxMC05ZmQ1LWVlYjE1ZTcwNzhhOQAQ" + String(n / 3)
                    if box == .inbox { inbox.append(m) } else { rest.append(m) }
                }
            }
        }
        return inbox + rest
    }()

    /// A store as the app has it after launch: server accounts with their folder trees.
    @MainActor static func store() -> MailStore {
        let s = MailStore(accounts: [work, home], messages: base.map { $0 })  // own buffer, not shared with `base`
        s.setFolders(folders(0), account: work.id)
        s.setFolders(folders(1), account: home.id)
        for a in [work, home] {
            s.apply(SyncResult(upserts: [], deletedRemoteIDs: [], token: "t", more: false), account: a.id, mailbox: .inbox)
        }
        _ = s.takeChanges()
        return s
    }

    /// Best of three runs, each on a fresh store prepared by `setup`.
    @MainActor static func time(_ label: String, setup: (MailStore) -> Void = { _ in }, _ f: (MailStore) -> Void) -> Double {
        let t = (0..<3).map { _ in
            let s = store()
            setup(s)
            let start = ContinuousClock.now
            f(s)
            let d = start.duration(to: .now)
            return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
        }
        print(String(format: "PERF4 %@: %.3fs (runs %@)", label, t.min()!, t.map { String(format: "%.3f", $0) }.joined(separator: " ")))
        return t.min()!
    }

    /// One redraw of the main window: list, sidebar badges, subtitle, title, detail.
    @MainActor static func redraw(_ s: MailStore) {
        _ = s.visibleMessages
        let refs: [MailboxRef] = [.smart(.allInboxes), .smart(.vip), .smart(.flagged), .smart(.unread)]
        for r in refs { _ = s.unreadCount(r) }
        for a in s.accounts {
            for b in MailboxKind.allCases + (s.folders[a.id] ?? []).map(\.box) { _ = s.unreadCount(.account(a.id, b)) }
        }
        _ = s.title
        _ = s.count(s.selectedMailbox); _ = s.unreadCount(s.selectedMailbox)
        if let m = s.selectedMessage { _ = s.conversation(of: m.id) }
    }
}

@MainActor
@Suite(.serialized)
struct Probe_Perf4Tests {
    typealias F = Perf4Fixture

    @Test func survey() {
        let w = F.work.id
        _ = F.base.count
        // Pick ids up front from the base array (stable ids across fresh stores).
        let inboxIDs = F.base.filter { $0.accountID == w && $0.mailbox == .inbox }.map(\.id)
        let newestInbox = F.base.filter { $0.accountID == w && $0.mailbox == .inbox }.max { $0.date < $1.date }!.id
        let lastMsg = F.base.last!.id
        let k1000 = Set(inboxIDs.prefix(1000))
        _ = F.time("build store") { _ in }
        _ = F.time("redraw cold (all inboxes)") { s in F.redraw(s) }
        _ = F.time("select mailbox work inbox + redraw", setup: { F.redraw($0) }) { s in s.selectedMailbox = .account(w, .inbox); F.redraw(s) }
        _ = F.time("select mailbox work sent + redraw", setup: { F.redraw($0) }) { s in s.selectedMailbox = .account(w, .sent); F.redraw(s) }
        _ = F.time("select mailbox work archive + redraw", setup: { F.redraw($0) }) { s in s.selectedMailbox = .account(w, .archive); F.redraw(s) }
        _ = F.time("toggle filter on inbox + redraw", setup: { $0.selectedMailbox = .account(w, .inbox); F.redraw($0) }) { s in s.filterUnread = true; F.redraw(s) }
        _ = F.time("selectedMessage x1 (last in array)", setup: { $0.selection = [lastMsg] }) { s in _ = s.selectedMessage }
        _ = F.time("conversation(of:)", setup: { $0.selection = [lastMsg] }) { s in _ = s.conversation(of: lastMsg) }
        _ = F.time("select msg + markSelectionRead + redraw", setup: { $0.selectedMailbox = .account(w, .inbox); F.redraw($0) }) { s in
            s.selection = [newestInbox]; s.markSelectionRead(); F.redraw(s)
        }
        _ = F.time("flag 1 + redraw", setup: { $0.selectedMailbox = .account(w, .inbox); F.redraw($0) }) { s in s.setFlag(.red, for: [newestInbox]); F.redraw(s) }
        _ = F.time("flag 1000 + redraw", setup: { $0.selectedMailbox = .account(w, .inbox); F.redraw($0) }) { s in s.setFlag(.red, for: k1000); F.redraw(s) }
        _ = F.time("delete 1 selected + redraw", setup: { $0.selectedMailbox = .account(w, .inbox); $0.selection = [newestInbox]; F.redraw($0) }) { s in s.deleteSelection(); F.redraw(s) }
        _ = F.time("delete 1000 selected + redraw", setup: { $0.selectedMailbox = .account(w, .inbox); $0.selection = k1000; F.redraw($0) }) { s in s.deleteSelection(); F.redraw(s) }
        _ = F.time("move 1000 to archive + redraw", setup: { $0.selectedMailbox = .account(w, .inbox); F.redraw($0) }) { s in s.move(k1000, to: .archive); F.redraw(s) }
        _ = F.time("drop 1000 on archive + redraw", setup: { $0.selectedMailbox = .account(w, .inbox); F.redraw($0) }) { s in s.drop(k1000, on: .account(w, .archive)); F.redraw(s) }
        let page = (0..<512).map { i in
            Message(accountID: w, from: Contact(name: "N", email: "n@x.com"), to: [], subject: "New \(i)", body: "",
                    date: .now, remoteID: "NEW\(i)", bodyLoaded: false)
        }
        _ = F.time("apply sync page 512 + redraw", setup: { F.redraw($0) }) { s in
            s.apply(SyncResult(upserts: page, deletedRemoteIDs: [], token: "t2", more: true), account: w, mailbox: .inbox); F.redraw(s)
        }
        _ = F.time("setBody + redraw", setup: { $0.selectedMailbox = .account(w, .inbox); $0.selection = [newestInbox]; F.redraw($0) }) { s in
            s.setBody(MessageBody(text: "Hello", attachments: [], html: "<p>Hello</p>"), for: newestInbox); F.redraw(s)
        }
        let renames = Dictionary(uniqueKeysWithValues: F.base.filter { k1000.contains($0.id) }.map { ($0.remoteID!, $0.remoteID! + "X") })
        _ = F.time("renameRemote 1000") { s in s.renameRemote(renames, account: w) }
        _ = F.time("takeChanges after flag 1000", setup: { $0.setFlag(.red, for: k1000) }) { s in _ = s.takeChanges() }
        _ = F.time("takeChanges+resolved after flag 1000", setup: { $0.setFlag(.red, for: k1000) }) { s in _ = s.takeChanges().resolved() }
        _ = F.time("children(of:) whole tree") { s in
            for a in s.accounts { for f in [nil] + (s.folders[a.id] ?? []).map(\.box) { _ = s.children(of: f, account: a.id) } }
        }
        let one = [Message(accountID: w, from: Contact(name: "N", email: "n@x.com"), to: [], subject: "New", body: "",
                           date: .now, remoteID: "NEW1", bodyLoaded: false)]
        _ = F.time("apply 1 new msg + redraw", setup: { F.redraw($0) }) { s in
            s.apply(SyncResult(upserts: one, deletedRemoteIDs: [], token: "t2", more: false), account: w, mailbox: .inbox); F.redraw(s)
        }
        _ = F.time("markAllRead all inboxes + redraw", setup: { F.redraw($0) }) { s in s.markAllRead(in: .smart(.allInboxes)); F.redraw(s) }
        _ = F.time("failed() of a refused 1-message flag + redraw", setup: { $0.setFlag(.red, for: [newestInbox]); F.redraw($0) }) { s in
            s.failed(s.outbox.last!, "refused"); F.redraw(s)
        }
        _ = F.time("open already-read msg (no-op markRead) + redraw", setup: { $0.selectedMailbox = .account(w, .inbox); $0.selection = [inboxIDs[1]]; F.redraw($0) }) { s in
            s.markSelectionRead(); F.redraw(s)
        }
        let firstBoxes = [MailboxKey(account: w, mailbox: .inbox), MailboxKey(account: F.home.id, mailbox: .inbox)]
        let inboxes = F.base.filter { $0.mailbox == .inbox }, rest = F.base.filter { $0.mailbox != .inbox }
        var meta = StoredMeta()
        meta.folders = [w: F.folders(0), F.home.id: F.folders(1)]
        _ = F.time("launch steps 1+2 (Inboxes) + redraw") { _ in
            let s = MailStore(accounts: [F.work, F.home], messages: [])
            s.restore(meta); s.restore(inboxes, boxes: firstBoxes); F.redraw(s)
        }
        _ = F.time("launch steps 1-3 + redraws (step 3 printed alone)") { _ in
            let s = MailStore(accounts: [F.work, F.home], messages: [])
            s.restore(meta); s.restore(inboxes, boxes: firstBoxes); F.redraw(s)
            let start = ContinuousClock.now
            s.finishLoading(rest); F.redraw(s)
            print("PERF4   launch step 3 finishLoading + redraw alone:", start.duration(to: .now))
        }
        for smart in [SmartMailbox.allInboxes, .vip, .flagged, .unread] {
            _ = F.time("select smart \(smart) + redraw", setup: { $0.selectedMailbox = .account(w, .sent); F.redraw($0) }) { s in
                s.selectedMailbox = .smart(smart); F.redraw(s)
            }
        }
    }
}

/// One test per finding. Each prints its timings; the assertion is the repo's budget (0.25 s per user action).
@MainActor
@Suite(.serialized)
struct Probe_Perf4Findings {
    typealias F = Perf4Fixture
    var w: UUID { F.work.id }
    var inbox: [Message] { F.base.filter { $0.accountID == F.work.id && $0.mailbox == .inbox } }

    /// R4-Perf4-01: one message deleted on the server (e.g. in Outlook) arrives with a quick check.
    @Test func serverDeletionOfOneMessageStaysInBudget() {
        let ib = inbox, gone = ib[5].remoteID!, readOne = ib[0].remoteID!, same = ib[3]
        let noop = F.time("merge of 1 unchanged message (alone)") { s in s.merge([same], account: w, mailbox: .inbox) }
        let read = F.time("server read change of 1 (alone)") { s in
            s.apply(SyncResult(upserts: [], deletedRemoteIDs: [], readChanges: [readOne: false], token: "t2", more: false), account: w, mailbox: .inbox)
        }
        let del = F.time("server deletion of 1 (alone)") { s in
            s.apply(SyncResult(upserts: [], deletedRemoteIDs: [gone], token: "t2", more: false), account: w, mailbox: .inbox)
        }
        let action = F.time("server deletion of 1 + redraw (Inbox shown)", setup: { $0.selectedMailbox = .account(w, .inbox); F.redraw($0) }) { s in
            s.apply(SyncResult(upserts: [], deletedRemoteIDs: [gone], token: "t2", more: false), account: w, mailbox: .inbox)
            F.redraw(s)
        }
        print(String(format: "PERF4 R4-Perf4-01 no-op merge %.3fs, read change %.3fs, deletion %.3fs, deletion+redraw %.3fs", noop, read, del, action))
        #expect(action < F.limit)
    }

    /// R4-Perf4-02: Delete key on one selected message in the Inbox (and on 1,000).
    @Test func deleteKeyOnTheSelectionStaysInBudget() {
        let one = inbox.last!.id, k1000 = Set(inbox.prefix(1000).map(\.id))
        let flagOnly = F.time("setFlag 1 (alone)") { s in s.setFlag(.red, for: [one]) }
        let deleteOnly = F.time("delete 1 (alone)") { s in s.delete([one]) }
        let d1 = F.time("Delete key, 1 selected + redraw", setup: { $0.selectedMailbox = .account(w, .inbox); $0.selection = [one]; F.redraw($0) }) { s in
            s.deleteSelection(); F.redraw(s)
        }
        let d1000 = F.time("Delete key, 1,000 selected + redraw", setup: { $0.selectedMailbox = .account(w, .inbox); $0.selection = k1000; F.redraw($0) }) { s in
            s.deleteSelection(); F.redraw(s)
        }
        let f1 = F.time("Flag, 1 selected + redraw", setup: { $0.selectedMailbox = .account(w, .inbox); $0.selection = [one]; F.redraw($0) }) { s in
            s.setFlag(.red, for: s.selection); F.redraw(s)
        }
        print(String(format: "PERF4 R4-Perf4-02 flag alone %.3fs, delete alone %.3fs, flag+redraw %.3fs, delete 1+redraw %.3fs, delete 1000+redraw %.3fs",
                     flagOnly, deleteOnly, f1, d1, d1000))
        #expect(d1 < F.limit)
        #expect(d1000 < F.limit)
    }

    /// R4-Perf4-03: clicking a message that arrived during this session (appended at the end of `messages`).
    /// A redraw reads `selectedMessage` 7 times: MailCommands.swift:27, :31, :60, :62, :64, MessageViewer.swift:77,
    /// MessageDetailView.swift:10.
    @Test func selectingANewlyArrivedMessageStaysInBudget() {
        let arrived = Message(accountID: w, from: Contact(name: "New", email: "new@x.com"), to: [], subject: "Just arrived",
                              body: "", date: Date(timeIntervalSince1970: 2_000_000_000), isRead: false, remoteID: "NEW-1",
                              serverPreview: "p", bodyLoaded: false)
        let front = inbox.first { !$0.isRead }!.id
        func arrive(_ s: MailStore) {
            s.apply(SyncResult(upserts: [arrived], deletedRemoteIDs: [], token: "t2", more: false), account: w, mailbox: .inbox)
            s.selectedMailbox = .account(w, .inbox)
            F.redraw(s)
        }
        func click(_ s: MailStore, _ id: Message.ID) {
            s.selection = [id]
            s.markSelectionRead()
            F.redraw(s)                                  // 1 read of selectedMessage
            for _ in 0..<6 { _ = s.selectedMessage }     // the other 6 reads of the same redraw
        }
        let oneRead = F.time("1 read of selectedMessage (new message)", setup: { arrive($0); $0.selection = [arrived.id] }) { s in _ = s.selectedMessage }
        let atFront = F.time("click unread Inbox message loaded at launch", setup: arrive) { s in click(s, front) }
        let newest = F.time("click unread message that arrived this session", setup: arrive) { s in
            let id = s.visibleMessages.first!.id          // top row of the Inbox
            click(s, id)
        }
        print(String(format: "PERF4 R4-Perf4-03 one read %.3fs, click front %.3fs, click newest %.3fs", oneRead, atFront, newest))
        #expect(newest < F.limit)
    }

    /// R4-Perf4-04: typing in the search field before the index is ready (each launch until it is), or after
    /// "Search failed": memory is scanned on every keystroke.
    @Test func memorySearchKeystrokeStaysInBudget() {
        var times: [Double] = []
        for q in ["i", "in", "inv", "invo", "invoice"] {
            times.append(F.time("memory search keystroke '\(q)'", setup: { $0.selectedMailbox = .smart(.allInboxes); F.redraw($0) }) { s in
                s.searchText = q; _ = s.visibleMessages
            })
        }
        print("PERF4 R4-Perf4-04 per keystroke", times.map { String(format: "%.3f", $0) })
        #expect(times.last! < F.limit)
    }

    /// Scope check, no finding expected: drag the selection onto Archive (ids == selection path).
    @Test func dragSelectionOntoArchive() {
        let k1000 = Set(inbox.prefix(1000).map(\.id))
        let t = F.time("drop selection of 1,000 on Archive + redraw", setup: { $0.selectedMailbox = .account(w, .inbox); $0.selection = k1000; F.redraw($0) }) { s in
            s.drop(s.selection, on: .account(w, .archive)); F.redraw(s)
        }
        print(String(format: "PERF4 drag selection %.3fs", t))
    }
}
