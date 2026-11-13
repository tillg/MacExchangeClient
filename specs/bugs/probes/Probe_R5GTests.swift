import Foundation
import Testing
@testable import EWS
@testable import MailModel

/// 180,000 messages over 2 accounts and 300 folders, as the README describes the real database.
/// Debug build. Budget: 0.25 s per user action (MailStorePerformanceTests.limit).
enum R5GFixture {
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
        print(String(format: "R5G %@: %.3fs (runs %@)", label, t.min()!, t.map { String(format: "%.3f", $0) }.joined(separator: " ")))
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

/// One test per finding. Each prints its timings and a control; the assertion is the repo's budget (0.25 s per user action).
@MainActor
@Suite(.serialized)
struct Probe_R5GFindings {
    typealias F = R5GFixture
    var w: UUID { F.work.id }

    /// R5G: Message ▸ Toggle Flag (⇧⌘L) and the toolbar's Flag button (`MailCommands`, `FlagMenu.primaryAction`) look up
    /// every selected message with `store.message(_:)`, a scan of all messages each.
    @Test func toggleFlagOnASelectionStaysInBudget() {
        let h = F.home.id, box = F.base.last!.mailbox
        // A folder of 140, Select All; only unflagged ones, so `contains` can't stop early (the fixture flags every 150th).
        let folder = Set(F.base.filter { $0.accountID == h && $0.mailbox == box && $0.flag == nil }.map(\.id))
        let setup: (MailStore) -> Void = { s in s.selectedMailbox = .account(h, box); s.selection = folder; F.redraw(s) }
        let control = F.time("Flag menu ▸ Red on the same \(folder.count) + redraw (control)", setup: setup) { s in
            s.setFlag(.red, for: s.withConversations(s.selection)); F.redraw(s)
        }
        let toggle = F.time("Toggle Flag on \(folder.count) selected + redraw", setup: setup) { s in
            let flagged = s.withConversations(s.selection).contains { s.message($0)?.flag != nil }  // MailCommands.swift:69
            s.setFlag(flagged ? nil : .red, for: s.withConversations(s.selection)); F.redraw(s)
        }
        print(String(format: "R5G toggle flag %.3fs vs flag menu %.3fs (%d selected)", toggle, control, folder.count))
        #expect(toggle < F.limit)
    }

    /// R5G: conversation view (Settings ▸ Viewing): clicking the next unread message after an opened unread one in
    /// Archive (30,000). Without conversations the same click costs about half.
    @Test func openingUnreadInConversationViewStaysInBudget() {
        let unread = F.base.filter { $0.accountID == F.work.id && $0.mailbox == .archive && !$0.isRead }
        let a = unread[0].id, b = unread[1].id
        func click(_ grouped: Bool) -> Double {
            F.time("grouped=\(grouped): open unread, then the next unread + redraw", setup: { s in
                s.groupsConversations = grouped; s.selectedMailbox = .account(F.work.id, .archive)
                s.selection = [a]; s.markSelectionRead(); F.redraw(s)
            }) { s in s.selection = [b]; s.markSelectionRead(); F.redraw(s) }
        }
        func alone(_ grouped: Bool) -> Double {
            F.time("grouped=\(grouped): selection + markSelectionRead alone (no redraw)", setup: { s in
                s.groupsConversations = grouped; s.selectedMailbox = .account(F.work.id, .archive)
                s.selection = [a]; s.markSelectionRead(); F.redraw(s)
            }) { s in s.selection = [b]; s.markSelectionRead() }
        }
        let rebuild = F.time("one list rebuild of Archive, grouped (control)", setup: { s in
            s.groupsConversations = true; s.selectedMailbox = .account(F.work.id, .archive); F.redraw(s)
        }) { s in s.filterUnread = true; _ = s.visibleMessages }
        let flat = click(false), grouped = click(true), flatAlone = alone(false), groupedAlone = alone(true)
        print(String(format: "R5G open next unread: conversations %.3fs, flat %.3fs; before the redraw: conversations %.3fs, flat %.3fs; one grouped rebuild %.3fs",
                     grouped, flat, groupedAlone, flatAlone, rebuild))
        #expect(grouped < F.limit)
    }

}

/// R5G: File ▸ New Viewer Window (⌥⌘N). Every viewer window runs `pollForMail`, whose first step is `AppSetup.loadMail`:
/// the stored state is read into the running store again. What changed since the last save (every 15 s) comes back.

/// R5G: Help ▸ What's New.
struct Probe_R5GWhatsNew {
    /// `WhatsNewView.title` parses "yyyy-MM-dd" with `.iso8601` (midnight UTC) and shows it in the local time zone.
    @Test func dayTitleIsTheSameDayInEveryTimeZone() throws {
        let date = try #require(WhatsNew.days.first?.date)
        let d = try Date(date, strategy: .iso8601.year().month().day())  // WhatsNewView.swift:27
        var style = Date.FormatStyle.dateTime.weekday(.wide).day().month(.wide).year()
        style.timeZone = TimeZone(identifier: "America/New_York")!
        style.locale = Locale(identifier: "en_US")
        let shown = d.formatted(style)
        #expect(shown.contains(String(Int(date.suffix(2))!)), "\(date) shown as \(shown)")
    }

}

// MARK: - Races and launch (loopback server, real EWSClient/EWSBackend/MailStore)

extension EWSFlowTests {
@MainActor
@Suite(.serialized)
struct Probe_R5GRaces {
    let acct = Account(name: "Exchange", address: "me@work.com", isServer: true)

    func backend(_ server: RaceServer) -> EWSBackend { EWSBackend(client: EWSClient(url: server.url, username: "u", password: "p")) }

    func store(_ server: RaceServer) -> MailStore {
        let s = MailStore(accounts: [], messages: [])
        s.add(acct, backend: backend(server))
        s.setRemoteFolders([RemoteFolder(role: .inbox, id: "INBOX"), RemoteFolder(role: .drafts, id: "DRAFTS"),
                            RemoteFolder(role: .sent, id: "SENT"), RemoteFolder(role: .trash, id: "DEL"),
                            RemoteFolder(role: .archive, id: "ARCH")], account: acct.id)
        s.downloadsFolder = FileManager.default.temporaryDirectory.appendingPathComponent("r5g-dl-\(UUID().uuidString)")
        return s
    }

    func summary(_ rid: String, box: MailboxKind = .inbox, subject: String? = nil) -> Message {
        Message(accountID: acct.id, mailbox: box, from: Contact(name: "Ann", email: ""), to: [Contact(name: "Me", email: "")],
                subject: subject ?? "S \(rid)", body: "", date: Date(timeIntervalSince1970: 1_700_000_000), isRead: false,
                remoteID: rid, serverPreview: "Preview of \(rid)", bodyLoaded: false)
    }

    func waitFor(_ timeout: Duration = .seconds(5), _ cond: () -> Bool) async throws {
        var left = timeout
        while !cond() && left > .zero {
            let start = ContinuousClock.now
            try await Task.sleep(for: .milliseconds(10))
            left -= min(start.duration(to: .now), .milliseconds(100))
        }
    }

    func serve(_ server: RaceServer, _ responses: [String]) async throws {
        for xml in responses {
            let before = server.served
            server.push(xml)
            try await waitFor(.seconds(10)) { server.served > before }
        }
    }

    static let emptyFind = RX.resp("FindItem", RX.ok("FindItem", "<m:RootFolder IndexedPagingOffset=\"0\" TotalItemsInView=\"0\" "
        + "IncludesLastItemInRange=\"true\"><t:Items/></m:RootFolder>"))

    /// R5G: Settings ▸ Accounts ▸ Sign In again after a wrong password lifts the pause (`add`, d-bug-056), and the
    /// next check works; the status line still says sign-in failed and nothing is sent until relaunch.
    @Test func signingInAgainClearsTheSignInFailedNotice() async throws {
        let server = RaceServer([RX.sync("", token: "T1")])
        defer { server.stop() }
        let s = store(server)
        s.apply(SyncResult(upserts: [], deletedRemoteIDs: [], token: "T0", more: false), account: acct.id, mailbox: .inbox)
        _ = s.pauseIfSignInFailed(AuthenticationError(), account: acct.id)  // what a 401 at a check does
        let notice = try #require(s.status)
        s.add(acct, backend: backend(server))  // AccountsSettings.signIn → AppSetup.connect
        await s.refresh(history: false)  // AccountsSettings.signIn then checks
        try #require(!s.isPaused(acct.id) && server.served == 1, "check didn't run: \(server.served)")
        #expect(s.status != notice, "after signing in again and a successful check the status still says: \(s.status ?? "nil")")
    }

    static func found(_ items: String) -> String {
        RX.resp("FindItem", RX.ok("FindItem", "<m:RootFolder IndexedPagingOffset=\"0\" TotalItemsInView=\"1\" "
            + "IncludesLastItemInRange=\"true\"><t:Items>\(items)</t:Items></m:RootFolder>"))
    }

    /// R5G: launch. `loadMail` is still reading the database (stored state not restored yet) when the user clicks a
    /// mailbox: the sidebar's check runs and starts the history sync, which treats every folder as new. R2 was deleted
    /// on the server while the app was closed; the history's complete pass from the start doesn't list it, yet it stays.
    @Test func aCheckBeforeTheStoredStateIsReadLeavesDeletedMail() async throws {
        let server = RaceServer([], hold: true)
        defer { server.stop() }
        let s = MailStore(accounts: [], messages: [])
        s.add(acct, backend: backend(server))
        s.setRemoteFolders([RemoteFolder(role: .inbox, id: "INBOX")], account: acct.id)  // the check's folder list
        s.progress = SyncProgress(text: "Loading Mail…", fraction: nil)  // AppSetup.loadMail: database being read
        s.selectedMailbox = .account(acct.id, .inbox)
        let check = Task { await s.refresh() }  // SidebarView .onChange(of: selectedMailbox)
        try await serve(server, [Self.found(RX.summary("R1")),   // quick check: Inbox not known complete, newest 50
                                 Self.found(RX.summary("R1")),   // history phase 1: newest 200
                                 RX.sync(RX.create(RX.summary("R1")), token: "P1", last: false)])  // phase 2, from the start
        await check.value
        // The database read finishes: the stored Inbox is complete at token STORED and holds R1 and R2.
        var meta = StoredMeta()
        meta.sync = [SyncState(account: acct.id, mailbox: .inbox, token: "STORED", complete: true)]
        let first = [MailboxKey(account: acct.id, mailbox: .inbox)]
        s.restore(meta)
        s.restore([summary("R1"), summary("R2")], boxes: first)
        s.finishLoading([])
        try await serve(server, [RX.sync("", token: "P2", last: true)])  // the pass from the start ends: it listed R1 only
        try await waitFor { s.progress == nil }
        let stuck = s.messages.contains { $0.remoteID == "R2" }
        for _ in 0..<6 { server.push(RX.fault("ErrorScriptExhausted", "end")) }
        #expect(!stuck, "R2 stays; inbox token \(s.syncToken(acct.id, .inbox) ?? "nil"), complete \(s.isComplete(acct.id, .inbox))")
    }

    /// R5G: two accounts; A's server doesn't answer (an on-prem server off the VPN drops the connection: each request
    /// waits for the 60 s timeout). A has a flag change queued. B's new mail waits for A: the check first waits for
    /// the outbox, which sends A's change and waits on it; B's own changes wait behind it too.
    @Test func aServerThatDoesntAnswerHoldsUpTheOtherAccount() async throws {
        let a = RaceServer([], hold: true)
        let b = RaceServer([RX.sync(RX.create(RX.summary("B1")), token: "TB1")])
        defer { a.stop(); b.stop() }
        let other = Account(name: "Home", address: "me@home.com", isServer: true)
        let s = store(a)
        s.add(other, backend: EWSBackend(client: EWSClient(url: b.url, username: "u", password: "p")))
        s.setRemoteFolders([RemoteFolder(role: .inbox, id: "BINBOX")], account: other.id)
        for x in [acct.id, other.id] {
            s.apply(SyncResult(upserts: [], deletedRemoteIDs: [], token: "T0", more: false), account: x, mailbox: .inbox)
        }
        s.merge([summary("A1")], account: acct.id, mailbox: .inbox)
        s.setFlag(.red, for: [s.messages[0].id])  // queued for A, goes out at once and waits on A's server
        let check = Task { await s.refresh(history: false) }
        try await waitFor(.seconds(5)) { s.messages.contains { $0.remoteID == "B1" } }
        let arrived = s.messages.contains { $0.remoteID == "B1" }
        a.push(RX.updated(["A1"])); a.push(RX.sync("", token: "T1"))  // let A answer, so the check ends
        await check.value
        #expect(arrived, "B's new mail didn't arrive within 5 s while A's server was silent (B served \(b.served))")
    }

    /// R5G: Reply on a message whose body is still loading; the message is deleted on the server meanwhile. The
    /// compose window opens empty, from the first account.
    @Test func replyToAMessageDeletedWhileItsBodyLoads() async throws {
        let server = RaceServer([], hold: true)
        defer { server.stop() }
        let other = Account(name: "Other", address: "me@other.com")
        let s = store(server)
        s.accounts.insert(other, at: 0)
        s.merge([summary("R1", subject: "Budget")], account: acct.id, mailbox: .inbox)
        let id = s.messages[0].id
        let t = Task { await s.loadedDraft(.reply, to: id) }
        try await Task.sleep(for: .milliseconds(300))  // GetItem is out
        s.apply(SyncResult(upserts: [], deletedRemoteIDs: ["R1"], token: "T1", more: false), account: acct.id, mailbox: .inbox)
        server.push(RX.fault("ErrorItemNotFound", "The specified object was not found in the store."))
        let d = await t.value
        #expect(d.accountID == acct.id && d.subject == "Re: Budget", "draft from \(d.accountID == other.id ? "the other account" : "?"), subject '\(d.subject)'")
    }
}
}
