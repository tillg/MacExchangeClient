import Foundation
import Testing
@testable import EWS
@testable import MailModel

// MARK: - Harness

/// file:// fixture (FIFO): a named pipe at a `file://` URL stands in for the EWS endpoint. The real EWSClient opens
/// the pipe for every request and reads the next scripted response. With `hold`, a request waits until a response is
/// pushed, so the test decides when the server's answer arrives. No network, no fake classes.
final class RaceServer: @unchecked Sendable {
    let url: URL
    private let path: String
    private let lock = NSLock()
    private var script: [String]
    private var stopped = false
    private let hold: Bool
    private var _served = 0
    var served: Int { lock.withLock { _served } }

    init(_ script: [String], hold: Bool = false) {
        self.hold = hold
        path = FileManager.default.temporaryDirectory.appendingPathComponent("race-fifo-\(UUID().uuidString).xml").path
        mkfifo(path, 0o600)
        url = URL(fileURLWithPath: path)
        self.script = script
        Thread { [self] in loop() }.start()
    }

    func push(_ xml: String) { lock.withLock { script.append(xml) } }
    func stop() { lock.withLock { stopped = true } }

    private func loop() {
        signal(SIGPIPE, SIG_IGN)
        while true {
            if lock.withLock({ stopped }) { unlink(path); return }
            if lock.withLock({ hold && script.isEmpty }) { usleep(500); continue }
            let fd = open(path, O_WRONLY | O_NONBLOCK)
            if fd < 0 { usleep(500); continue }
            _ = fcntl(fd, F_SETFL, 0)
            let xml = lock.withLock { script.isEmpty ? RX.fault("ErrorScriptExhausted", "No scripted response left") : script.removeFirst() }
            let bytes = Array(xml.utf8)
            var off = 0
            while off < bytes.count {
                let n = bytes[off...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
                if n <= 0 { break }
                off += n
            }
            lock.withLock { _served += 1 }
            close(fd)
            usleep(300_000)
        }
    }
}

/// Hand-written Exchange responses. // file:// fixture
enum RX {
    static func env(_ body: String) -> String {
        """
        <?xml version="1.0" encoding="utf-8"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">\
        <s:Body xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema">\(body)</s:Body></s:Envelope>
        """
    }
    static let ns = "xmlns:m=\"http://schemas.microsoft.com/exchange/services/2006/messages\" xmlns:t=\"http://schemas.microsoft.com/exchange/services/2006/types\""
    static func ok(_ op: String, _ inner: String = "") -> String {
        "<m:\(op)ResponseMessage ResponseClass=\"Success\"><m:ResponseCode>NoError</m:ResponseCode>\(inner)</m:\(op)ResponseMessage>"
    }
    static func resp(_ op: String, _ messages: String) -> String {
        env("<m:\(op)Response \(ns)><m:ResponseMessages>\(messages)</m:ResponseMessages></m:\(op)Response>")
    }
    static func fault(_ code: String, _ text: String) -> String {
        env("<s:Fault><faultcode>a:\(code)</faultcode><faultstring>\(text)</faultstring></s:Fault>")
    }
    static func getItem(_ item: String) -> String { resp("GetItem", ok("GetItem", "<m:Items>\(item)</m:Items>")) }
    static func moved(_ new: [String]) -> String {
        resp("MoveItem", new.map { ok("MoveItem", "<m:Items><t:Message><t:ItemId Id=\"\($0)\" ChangeKey=\"CK\"/></t:Message></m:Items>") }.joined())
    }
    static func updated(_ ids: [String]) -> String {
        resp("UpdateItem", ids.map { ok("UpdateItem", "<m:Items><t:Message><t:ItemId Id=\"\($0)\" ChangeKey=\"CK\"/></t:Message></m:Items>") }.joined())
    }
    /// Throttling, as Exchange sends it: ErrorServerBusy with a back-off.
    static let busy = """
        <?xml version="1.0" encoding="utf-8"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>\
        <s:Fault><faultcode xmlns:a="http://schemas.microsoft.com/exchange/services/2006/types">a:ErrorServerBusy</faultcode>\
        <faultstring xml:lang="en-US">The server cannot service this request right now. Try again later.</faultstring>\
        <detail><e:ResponseCode xmlns:e="http://schemas.microsoft.com/exchange/services/2006/errors">ErrorServerBusy</e:ResponseCode>\
        <t:MessageXml xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types"><t:Value Name="BackOffMilliseconds">60000</t:Value></t:MessageXml>\
        </detail></s:Fault></s:Body></s:Envelope>
        """
    /// The answer to AcceptItem/DeclineItem (CreateItem) or RemoveItem.
    static let answered = resp("CreateItem", ok("CreateItem", "<m:Items/>"))
    static func movedInvite(_ new: String) -> String {
        resp("MoveItem", ok("MoveItem", "<m:Items><t:MeetingRequest><t:ItemId Id=\"\(new)\" ChangeKey=\"CK\"/></t:MeetingRequest></m:Items>"))
    }
    static let standardFolders = resp("GetFolder", [("INBOX", "Inbox"), ("DRAFTS", "Drafts"), ("SENT", "Sent Items"),
                                                    ("JUNK", "Junk Email"), ("DEL", "Deleted Items"), ("OUTBOX", "Outbox")].map { id, name in
        ok("GetFolder", "<m:Folders><t:Folder><t:FolderId Id=\"\(id)\" ChangeKey=\"AQ\"/><t:DisplayName>\(name)</t:DisplayName>"
            + "<t:TotalCount>0</t:TotalCount></t:Folder></m:Folders>")
    }.joined())
    static let noFolders = resp("FindFolder", ok("FindFolder", "<m:RootFolder IndexedPagingOffset=\"0\" TotalItemsInView=\"0\" "
        + "IncludesLastItemInRange=\"true\"><t:Folders/></m:RootFolder>"))
    static func textMessage(_ id: String, subject: String, body: String) -> String {
        "<t:Message><t:ItemId Id=\"\(id)\" ChangeKey=\"CK\"/><t:Subject>\(subject)</t:Subject>"
            + "<t:Body BodyType=\"Text\">\(body)</t:Body><t:Attachments/>"
            + "<t:From><t:Mailbox><t:Name>Ann</t:Name><t:EmailAddress>ann@x.com</t:EmailAddress></t:Mailbox></t:From>"
            + "<t:ToRecipients><t:Mailbox><t:Name>Me</t:Name><t:EmailAddress>me@work.com</t:EmailAddress></t:Mailbox></t:ToRecipients>"
            + "<t:TextBody BodyType=\"Text\">\(body)</t:TextBody></t:Message>"
    }
}

// Nested in EWSFlowTests, whose `.serialized` then covers both suites: their pipes are read by URLSession's file
// loader, and a request waiting on one suite's pipe held up the other's when they ran side by side.
extension EWSFlowTests {
/// Server answers and local changes racing each other, in a fixed order.
@MainActor
@Suite(.serialized)
struct MailStoreRaceTests {
    let acct = Account(name: "Exchange", address: "me@work.com")

    func store(_ server: RaceServer) -> MailStore { store(server.url) }

    /// A file standing in for every server response, where the order of requests doesn't matter. // file:// fixture
    func answering(_ xml: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("race-\(UUID().uuidString).xml")
        try Data(xml.utf8).write(to: url)
        return url
    }

    func store(_ url: URL) -> MailStore {
        let s = MailStore(accounts: [], messages: [])
        s.add(acct, backend: EWSBackend(client: EWSClient(url: url, username: "u", password: "p")))
        s.setRemoteFolders([RemoteFolder(role: .inbox, id: "INBOX"), RemoteFolder(role: .drafts, id: "DRAFTS"),
                            RemoteFolder(role: .sent, id: "SENT"), RemoteFolder(role: .trash, id: "DEL"),
                            RemoteFolder(role: .archive, id: "ARCH")], account: acct.id)
        s.downloadsFolder = FileManager.default.temporaryDirectory.appendingPathComponent("race-dl-\(UUID().uuidString)")
        return s
    }

    /// A message as a list summary from the server (body not loaded).
    func summary(_ rid: String, box: MailboxKind = .inbox, subject: String? = nil, preview: String = "Preview",
                 read: Bool = false, flagged: Bool = false) -> Message {
        Message(accountID: acct.id, mailbox: box, from: Contact(name: "Ann", email: ""),
                to: [Contact(name: "Me", email: "")], subject: subject ?? "S \(rid)", body: "",
                date: Date(timeIntervalSince1970: 1_700_000_000), isRead: read, flag: flagged ? .red : nil,
                remoteID: rid, serverPreview: preview, bodyLoaded: false)
    }

    func waitFor(_ timeout: Duration = .seconds(5), _ cond: () -> Bool) async throws {
        let end = ContinuousClock.now + timeout
        while !cond() && ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(10)) }
    }

    /// Serves `responses` of a `hold` server one at a time, each once the previous one has been read and its reader
    /// has let go of the pipe (URLSession reads on for a while after a response; on a busy machine longer than the
    /// server's own pause, and the next response would then end up in the previous request).
    func serve(_ server: RaceServer, _ responses: [String]) async throws {
        for xml in responses {
            let before = server.served
            server.push(xml)
            try await waitFor(.seconds(10)) { server.served > before }
            try await Task.sleep(for: .seconds(1))
        }
    }

    // MARK: A server answer requested before a local change, applied after that change was written (BUG-139)

    /// Inbox not fully synced: every check merges its newest messages. A check's answer taken before the flag arrives
    /// after the flag was written: the flag stays, and the next check (red on the server) keeps its colour.
    @Test func flagWrittenWhileACheckIsOnItsWayKeepsItsColour() async throws {
        let s = store(try answering(RX.updated(["R1"])))
        s.merge([summary("R1")], account: acct.id, mailbox: .inbox)
        let id = s.messages[0].id
        let stale = [summary("R1")]  // the newest-50 answer, taken by Exchange before the flag
        let asked = s.requestStamp  // refresh() notes when it asks
        s.setFlag(.purple, for: [id])
        try await waitFor { s.outbox.isEmpty }
        try #require(s.outbox.isEmpty, "the change never reached the server: \(s.status ?? "")")
        s.merge(stale, account: acct.id, mailbox: .inbox, asked: asked)  // refresh() applies its late answer
        #expect(s.message(id)?.flag == .purple, "after the late answer")
        s.merge([summary("R1", flagged: true)], account: acct.id, mailbox: .inbox, asked: s.requestStamp)  // next check
        #expect(s.message(id)?.flag == .purple, "after the next check")
        // Control: an answer requested after the write is the server's word (unflagged on the phone).
        s.merge([summary("R1")], account: acct.id, mailbox: .inbox, asked: s.requestStamp)
        #expect(s.message(id)?.flag == nil)
    }

    /// Mark as Read: a history page taken before it doesn't turn the message unread again.
    @Test func readWrittenWhileAHistoryBatchIsCollectedStaysRead() async throws {
        let s = store(try answering(RX.updated(["R1"])))
        s.merge([summary("R1")], account: acct.id, mailbox: .inbox)
        let id = s.messages[0].id
        let page = SyncResult(upserts: [summary("R1")], deletedRemoteIDs: [], token: "T1", more: true)
        let asked = s.requestStamp
        s.toggleRead([id])
        try await waitFor { s.outbox.isEmpty }
        try #require(s.outbox.isEmpty, "the change never reached the server: \(s.status ?? "")")
        s.apply([page], account: acct.id, mailbox: .inbox, asked: asked)
        #expect(s.message(id)?.isRead == true)
        // The same for a read change that comes without the rest of the message.
        s.apply(SyncResult(upserts: [], deletedRemoteIDs: [], readChanges: ["R1": false], token: "T2", more: true),
                account: acct.id, mailbox: .inbox, asked: asked)
        #expect(s.message(id)?.isRead == true)
    }

    /// The archive reaches Exchange (new ItemId) before the Inbox check's answer, taken before the move, arrives: the
    /// old ID doesn't come back as a ghost in the Inbox.
    @Test func moveWrittenWhileACheckIsOnItsWayLeavesNoGhost() async throws {
        let s = store(try answering(RX.moved(["N1"])))
        s.merge([summary("R1"), summary("R2")], account: acct.id, mailbox: .inbox)
        let id = try #require(s.messages.first { $0.remoteID == "R1" }).id
        let stale = [summary("R1"), summary("R2")]  // newest answer taken before the move
        let asked = s.requestStamp
        s.archive([id])
        try await waitFor { s.outbox.isEmpty }
        try #require(s.outbox.isEmpty, "the change never reached the server: \(s.status ?? "")")
        #expect(s.message(id)?.remoteID == "N1")
        s.merge(stale, account: acct.id, mailbox: .inbox, asked: asked)
        s.merge([summary("R2")], account: acct.id, mailbox: .inbox, asked: s.requestStamp)  // the next checks: R1 is gone on the server
        #expect(s.count(.account(acct.id, .inbox)) == 1, "inbox \(s.messages.filter { $0.mailbox == .inbox }.map { $0.remoteID ?? "" })")
        #expect(s.messages.filter { $0.subject == "S R1" }.count == 1)
        s.apply(SyncResult(upserts: [summary("R2")], deletedRemoteIDs: [], token: "T9", more: false), account: acct.id, mailbox: .inbox)
        #expect(s.isComplete(acct.id, .inbox))
        #expect(s.count(.account(acct.id, .inbox)) == 1, "after the full sync: \(s.messages.filter { $0.mailbox == .inbox }.map { $0.remoteID ?? "" })")
    }

    // MARK: A body requested before the server changed the message (BUG-140)

    /// The draft is edited elsewhere while its body is on its way: the old body isn't stored under the new subject;
    /// the body is asked for again and the new text is shown.
    @Test func bodyRequestedBeforeAServerChangeIsFetchedAgain() async throws {
        let server = RaceServer([], hold: true)
        defer { server.stop() }
        let s = store(server)
        s.merge([summary("R1", box: .drafts, subject: "Plan v1", preview: "old text")], account: acct.id, mailbox: .drafts)
        let id = s.messages[0].id
        let t = Task { await s.loadBody(id) }
        try await Task.sleep(for: .milliseconds(300))  // GetItem is out; Exchange has the old version
        // Meanwhile the quick check brings the edited draft (same ItemId, as Exchange keeps it on an edit).
        s.apply(SyncResult(upserts: [summary("R1", box: .drafts, subject: "Plan v2", preview: "new text")], deletedRemoteIDs: [],
                           token: "T1", more: false), account: acct.id, mailbox: .drafts)
        #expect(s.message(id)?.subject == "Plan v2")
        try await serve(server, [RX.getItem(RX.textMessage("R1", subject: "Plan v1", body: "old text")),
                                 RX.getItem(RX.textMessage("R1", subject: "Plan v2", body: "new text"))])
        await t.value
        try #require(s.status == nil, "the body request failed: \(s.status ?? "")")
        let m = try #require(s.message(id))
        #expect(m.body == "new text" && !m.needsBody, "subject \(m.subject), body \(m.body), needsBody \(m.needsBody)")
    }

    // MARK: The move to Trash after an unsent answer or a removal (BUG-136)

    func invite(cancel: Bool = false) -> Invite {
        Invite(start: Date(timeIntervalSince1970: 1_795_428_000), end: Date(timeIntervalSince1970: 1_795_431_600),
               location: "Room 1", organizer: Contact(name: "Org", email: "org@work.com"), isCancellation: cancel)
    }

    func inviteMessage(_ rid: String, cancel: Bool = false) -> Message {
        var m = Message(accountID: acct.id, mailbox: .inbox, from: Contact(name: "Org", email: "org@work.com"),
                        to: [Contact(name: "Me", email: "me@work.com")], subject: cancel ? "Canceled: Sync" : "Sync",
                        body: "Let's meet", date: Date(timeIntervalSince1970: 1_000_000), remoteID: rid, bodyLoaded: true,
                        invite: invite(cancel: cancel))
        m.htmlChecked = true
        return m
    }

    /// A store whose folder list hasn't been read yet, as right after launch.
    func storeWithoutFolders(_ server: RaceServer) -> MailStore {
        let s = MailStore(accounts: [], messages: [])
        s.add(acct, backend: EWSBackend(client: EWSClient(url: server.url, username: "u", password: "p")))
        return s
    }

    /// Do Not Send a Response before the folder list is read: it is read, and the invite moves to Deleted Items.
    @Test func doNotSendBeforeTheFolderListStillMovesTheInvite() async throws {
        let server = RaceServer([], hold: true)
        defer { server.stop() }
        let s = storeWithoutFolders(server)
        s.merge([inviteMessage("M")], account: acct.id, mailbox: .inbox)
        let id = s.messages[0].id
        s.respond(InviteReply(response: .decline, send: false), to: id)
        try await serve(server, [RX.answered, RX.standardFolders, RX.noFolders, RX.movedInvite("M-T")])
        try await waitFor(.seconds(10)) { s.message(id)?.remoteID == "M-T" && s.outbox.isEmpty }
        #expect(s.message(id)?.remoteID == "M-T", "rid \(s.message(id)?.remoteID ?? ""), requests \(server.served), status \(s.status ?? "nil")")
        #expect(s.message(id)?.mailbox == .trash)
    }

    /// Remove from Calendar queued offline last session, sent at launch before any folder list is read. (Restored
    /// from the old cache, which writes waiting changes like `finishLoading` but starts no history, whose requests
    /// would take this script's answers.)
    @Test func removeFromCalendarSentAtLaunchMovesTheCancellation() async throws {
        let s1 = MailStore(accounts: [acct], messages: [])  // no backend: the change stays queued
        s1.merge([inviteMessage("C", cancel: true)], account: acct.id, mailbox: .inbox)
        s1.removeFromCalendar(s1.messages[0].id)
        let saved = s1.cache()
        let server = RaceServer([], hold: true)
        defer { server.stop() }
        let s = storeWithoutFolders(server)
        s.restore(saved)
        try await serve(server, [RX.answered, RX.standardFolders, RX.noFolders, RX.movedInvite("C-T")])
        try await waitFor(.seconds(10)) { s.messages.first?.remoteID == "C-T" && s.outbox.isEmpty }
        let m = try #require(s.messages.first)
        #expect(m.remoteID == "C-T", "rid \(m.remoteID ?? ""), requests \(server.served), status \(s.status ?? "nil")")
        #expect(m.mailbox == .trash)
    }

    /// Exchange is busy when the follow-up move goes out: the move stays queued (the answer itself went out).
    @Test func aBusyServerKeepsTheMoveAfterAnUnsentAnswerQueued() async throws {
        let server = RaceServer([], hold: true)
        defer { server.stop() }
        let s = store(server)
        s.merge([inviteMessage("M")], account: acct.id, mailbox: .inbox)
        let id = s.messages[0].id
        s.respond(InviteReply(response: .accept, send: false), to: id)
        try await serve(server, [RX.answered, RX.busy])
        try await waitFor(.seconds(10)) { server.served == 2 && s.outbox.allSatisfy { if case .move = $0.change { true } else { false } } }
        #expect(s.outbox.map(\.change) == [.move(["M"], to: .trash)], "outbox \(s.outbox.map(\.change)), status \(s.status ?? "nil")")
        #expect(s.message(id)?.mailbox == .trash && s.message(id)?.invite?.reply?.response == .accept)
    }
}
}
