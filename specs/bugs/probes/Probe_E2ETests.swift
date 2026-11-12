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

    /// Two Exchange accounts: one server unreachable (e.g. only over VPN) must not hold up the other account's
    /// changes. drain() stops at the first URLError, and the outbox is one queue for all accounts.
    @Test func unreachableAccountDoesNotBlockTheOtherAccountsChanges() async throws {
        let ok = try responseFile(success)  // file:// fixture
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("ews-e2e-missing-\(UUID().uuidString).xml")
        let s = MailStore(accounts: [], messages: [])
        s.add(a, backend: backend(missing))
        s.add(b, backend: backend(ok))
        s.apply(page([server("A1")]), account: a.id, mailbox: .inbox)
        s.apply(page([server("B1")]), account: b.id, mailbox: .inbox)
        let a1 = s.messages.first { $0.accountID == a.id }!.id, b1 = s.messages.first { $0.accountID == b.id }!.id
        s.toggleRead([a1])
        s.toggleRead([b1])
        s.send(Draft(accountID: b.id, to: "x@y.com", subject: "From B", body: "b"))
        await s.refresh(history: false)
        let left = s.outbox.filter { $0.account == b.id }.map(\.change)
        #expect(left.isEmpty, "account B's changes still waiting because account A is unreachable: \(left)")
    }

    /// The same for the background history: the first account's folder fails with a network error and
    /// syncHistory returns, so the other account's history (and its background checks) never run while the
    /// first one is unreachable.
    @Test func unreachableAccountDoesNotStopTheOtherAccountsHistory() async throws {
        let ok = try responseFile(success)  // file:// fixture
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("ews-e2e-missing-\(UUID().uuidString).xml")
        let s = MailStore(accounts: [], messages: [])
        s.add(a, backend: backend(missing))
        s.add(b, backend: backend(ok))
        // Both folder lists were read while A was still reachable (e.g. before the VPN dropped).
        s.setRemoteFolders([RemoteFolder(role: .inbox, id: "FA"), RemoteFolder(role: .sent, id: "FA2")], account: a.id)
        s.setRemoteFolders([RemoteFolder(role: .inbox, id: "FB"), RemoteFolder(role: .sent, id: "FB2")], account: b.id)
        await s.syncHistory()
        await s.syncHistory()  // the next round, 15 s later
        #expect(s.isComplete(b.id, .inbox) && s.isComplete(b.id, .sent),
                "account B's history: inbox \(s.isComplete(b.id, .inbox)), sent \(s.isComplete(b.id, .sent))")
    }

    /// A message answered while it is part of a multi-selection (the comment window's Send, pressed after
    /// selecting more messages in the main window) goes to Trash but stays selected; Delete then erases it
    /// from Trash, unseen.
    @Test func inviteAnsweredWhileInAMultiSelectionIsNotErasedByDelete() {
        let s = MailStore(accounts: [a], messages: [])
        var inv = server("INV", minutes: 2)
        inv.invite = Invite(start: Date(timeIntervalSince1970: 1_800_000_000), end: Date(timeIntervalSince1970: 1_800_003_600))
        s.apply(page([inv, server("X", minutes: 1), server("Y", minutes: 0)]), account: a.id, mailbox: .inbox)
        let invID = s.messages.first { $0.remoteID == "INV" }!.id, x = s.messages.first { $0.remoteID == "X" }!.id
        s.selectedMailbox = .account(a.id, .inbox)
        s.selection = [invID, x]
        s.respond(InviteReply(response: .accept, comment: "ok"), to: invID)
        #expect(s.message(invID)?.mailbox == .trash)
        #expect(!s.selection.contains(invID), "the answered invite (now in Trash) is still selected")
        s.deleteSelection()
        #expect(s.message(invID) != nil, "Delete erased the answered invite from Trash")
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

    /// A send queued while the request is on its way is written by the 15-second save (or the save on quit).
    /// If the app quits before the next save, the next launch restores the send and sends the mail again.
    @Test func sendInFlightWhenTheAppQuitsIsNotSentAgainAfterRelaunch() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let ok = try responseFile(success)  // file:// fixture
        let s = MailStore(accounts: [], messages: [])
        s.add(a, backend: backend(ok))
        let db = try MailDatabase(url: url)
        s.apply(page([server("A1")]), account: a.id, mailbox: .inbox)
        s.send(Draft(accountID: a.id, to: "boss@x.com", subject: "Resignation", body: "Once only"))
        await Task.yield()  // the drain has started: the request is on its way
        try #require(s.outbox.contains(where: isSend))
        try db.write(s.takeChanges())  // the save on quit (saveChanges(now: true)) while the request is on its way
        await s.refresh(history: false)  // the server accepted it
        try #require(!s.outbox.contains(where: isSend))
        // The app quit (or crashed) before the next save. Next launch:
        let s2 = MailStore(accounts: [], messages: [])
        s2.add(a, backend: backend(ok))
        let db2 = try MailDatabase(url: url)
        s2.restore(try db2.meta())
        s2.finishLoading(try db2.messages())
        await s2.refresh(history: false)
        #expect(s2.messages.contains { $0.mailbox == .drafts && $0.subject == "Resignation" },
                "sent a second time without asking (outbox now \(s2.outbox.count)); not kept in Drafts")
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

    /// Two Exchange accounts look the same everywhere: every one is called "Exchange" (sidebar sections,
    /// All Inboxes rows, window title, "Found in Sent – …", sync progress, sign-in errors).
    @Test func twoExchangeAccountsCanBeToldApart() {
        let one = ExchangeAccount(email: "till@work.com", username: "W\\till", server: "mail.work.com")
        let two = ExchangeAccount(email: "till@club.org", username: "C\\till", server: "mail.club.org")
        let s = MailStore(accounts: [one.account, two.account], messages: [])
        s.selectedMailbox = .account(one.id, .inbox)
        let t1 = s.title
        s.selectedMailbox = .account(two.id, .inbox)
        #expect(t1 != s.title, "both Inboxes are titled \(t1)")
        #expect(one.account.name != two.account.name)
    }

    /// An Exchange account whose Keychain password is missing has no backend. Before it has any stored sync
    /// position (fresh database), Send files the message under Sent as if sent, and nothing is queued.
    @Test func sendFromAnExchangeAccountWithoutPasswordIsNotShownAsSent() {
        let ex = ExchangeAccount(email: "till@work.com", username: "W\\till", server: "mail.work.com")
        let s = MailStore(accounts: [], messages: [])
        s.accounts.append(ex.account)  // AppSetup.connect without a Keychain password
        s.send(Draft(accountID: ex.id, to: "x@y.com", subject: "Important", body: "b"))
        let sent = s.messages.filter { $0.mailbox == .sent && $0.subject == "Important" }
        #expect(sent.isEmpty && s.outbox.contains(where: isSend), "shown in Sent \(sent.count), queued \(s.outbox.count)")
    }

    /// The same account after a relaunch (its sync positions are stored): Send queues the message, which can never
    /// go out (no backend) and nothing says so; it stays queued across relaunches and goes out whenever a
    /// password is added, maybe days later.
    @Test func sendFromARestoredExchangeAccountWithoutPasswordSaysItCannotSend() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let ex = ExchangeAccount(email: "till@work.com", username: "W\\till", server: "mail.work.com")
        let s = MailStore(accounts: [ex.account], messages: [])
        s.apply(page([server("A1")]), account: ex.id, mailbox: .inbox)
        try MailDatabase(url: url).write(s.takeChanges())
        let db = try MailDatabase(url: url)
        let s2 = MailStore(accounts: [], messages: [])
        s2.accounts.append(ex.account)  // AppSetup.connect without a Keychain password
        s2.status = "No password in the Keychain for W\\till"
        s2.restore(try db.meta())
        s2.finishLoading(try db.messages())
        let before = s2.status
        s2.send(Draft(accountID: ex.id, to: "x@y.com", subject: "Important", body: "b"))
        #expect(s2.status != before || s2.messages.contains { $0.subject == "Important" && $0.mailbox == .drafts },
                "queued: \(s2.outbox.count), status: \(s2.status ?? "nil")")
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

    /// A send Exchange refuses is kept in Drafts with "Couldn't send …" under the window title. The next
    /// quick check (at most 15 s later, also one already running) replaces the notice with nil.
    @Test func couldntSendNoticeSurvivesTheNextCheck() async throws {
        let file = try responseFile(error("ErrorInvalidRecipients"))  // file:// fixture
        let s = MailStore(accounts: [], messages: [])
        s.add(a, backend: backend(file))
        s.send(Draft(accountID: a.id, to: "nobody", subject: "Quarterly report", body: "b"))
        try await waitUntil { s.outbox.isEmpty }
        #expect(s.status?.contains("Couldn't send") == true)
        try Data(success.utf8).write(to: file)  // the server answers normally again
        await s.refresh(history: false)  // the next 15-second check
        #expect(s.status?.contains("Couldn't send") == true, "status after the next check: \(s.status ?? "nil")")
    }

    /// Two accounts: the first one's check fails, the second one's succeeds and clears the error, so nothing
    /// says the first account wasn't checked. Run over several account pairs: the order follows the dictionary.
    @Test func oneAccountsErrorIsNotClearedByTheOthersSuccess() async throws {
        let ok = try responseFile(success)  // file:// fixture
        let bad = try responseFile(error("ErrorMailboxMoveInProgress"))
        var cleared = 0
        for _ in 0..<32 {
            let x = Account(name: "Work", address: "me@work.com"), y = Account(name: "Club", address: "me@club.org")
            let s = MailStore(accounts: [], messages: [])
            s.add(x, backend: backend(bad))
            s.add(y, backend: backend(ok))
            await s.refresh(history: false)
            if s.status == nil { cleared += 1 }
        }
        #expect(cleared == 0, "the failing account's error was gone after \(cleared) of 32 checks")
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

    /// A draft saved from here (or Outlook) and opened once, then edited elsewhere: the Drafts sync brings the new
    /// summary, but the merge keeps the old loaded body and never fetches it again; subject and text disagree.
    @Test func draftEditedOnTheServerShowsItsNewText() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let s = MailStore(accounts: [a], messages: [])
        var v1 = server("D1"); v1.subject = "Offer v1"; v1.serverPreview = "Price 100"
        s.apply(page([v1], token: "d1"), account: a.id, mailbox: .drafts)
        let id = s.messages[0].id
        s.setBody(MessageBody(text: "Price 100", attachments: [Attachment(name: "v1.pdf", size: 1000, contentType: "application/pdf")]), for: id)
        var v2 = server("D1"); v2.subject = "Offer v2"; v2.serverPreview = "Price 250"; v2.hasAttachments = true
        s.apply(page([v2], token: "d2"), account: a.id, mailbox: .drafts)
        let db = try MailDatabase(url: url)
        let (s2, _) = try relaunch(s, db, url)
        let m = try #require(s2.message(id))
        #expect(m.subject == "Offer v2")
        #expect(m.body == "Price 250" || m.needsBody, "subject 'Offer v2' with body '\(m.body)', needsBody \(m.needsBody)")
    }

    /// Messages received in the same second (a mailing-list burst) keep their order in Flagged across a relaunch.
    @Test func sameTimeMessagesKeepTheirOrderAfterRelaunch() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let s = MailStore(accounts: [a], messages: [])
        let db = try MailDatabase(url: url)
        s.apply(page([server("ARCH", flagged: true, minutes: 5)]), account: a.id, mailbox: .archive)
        s.apply(page([server("INB", flagged: true, minutes: 5)]), account: a.id, mailbox: .inbox)
        s.selectedMailbox = .smart(.flagged)
        let before = s.visibleMessages.map(\.remoteID)
        let (s2, _) = try relaunch(s, db, url)
        s2.selectedMailbox = .smart(.flagged)
        #expect(s2.visibleMessages.map(\.remoteID) == before)
    }

    /// Respond with Comments while the server can't be reached: the answer is undone ("Exchange refused a
    /// change") and the comment the user typed is gone, while a failed send is kept in Drafts.
    @Test func inviteAnswerWithCommentIsNotLostWhenOffline() async throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("ews-e2e-missing-\(UUID().uuidString).xml")
        let s = MailStore(accounts: [], messages: [])
        s.add(a, backend: backend(missing))  // file:// fixture (absent: offline)
        var inv = server("INV")
        inv.invite = Invite(start: Date(timeIntervalSince1970: 1_800_000_000), end: Date(timeIntervalSince1970: 1_800_003_600))
        s.apply(page([inv]), account: a.id, mailbox: .inbox)
        let id = s.messages[0].id
        s.selectedMailbox = .account(a.id, .inbox)
        s.selection = [id]
        let comment = "I can join for the first half hour only, then I have to leave for the airport."
        s.send(Draft(accountID: a.id, to: "org@x.com", subject: "Accepted: Q4", body: comment,
                     inviteAnswer: InviteAnswer(messageID: id, response: .accept)))
        try await waitUntil { s.outbox.isEmpty }
        let kept = s.messages.contains { $0.body.contains(comment) } || s.outbox.contains {
            if case let .reply(_, r) = $0.change { r.comment == comment } else { false }
        }
        #expect(kept, "status: \(s.status ?? "nil"); invite back in \(s.message(id)?.mailbox.rawValue ?? "-")")
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
