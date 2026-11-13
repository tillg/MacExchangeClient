import Foundation
import Testing
@testable import EWS
@testable import MailModel

// MARK: - Harness

/// file:// fixture (FIFO), as in Probe_EWSFlowTests: a named pipe at a `file://` URL stands in for the EWS endpoint.
/// The real EWSClient opens the pipe for every request and reads the next scripted response. With `hold`, a request
/// waits until a response is pushed, so the test decides when the server's answer arrives.
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
            if lock.withLock({ stopped }) { return }
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
    static func textMessage(_ id: String, subject: String, body: String) -> String {
        "<t:Message><t:ItemId Id=\"\(id)\" ChangeKey=\"CK\"/><t:Subject>\(subject)</t:Subject>"
            + "<t:Body BodyType=\"Text\">\(body)</t:Body><t:Attachments/>"
            + "<t:From><t:Mailbox><t:Name>Ann</t:Name><t:EmailAddress>ann@x.com</t:EmailAddress></t:Mailbox></t:From>"
            + "<t:ToRecipients><t:Mailbox><t:Name>Me</t:Name><t:EmailAddress>me@work.com</t:EmailAddress></t:Mailbox></t:ToRecipients>"
            + "<t:TextBody BodyType=\"Text\">\(body)</t:TextBody></t:Message>"
    }
}

@MainActor
@Suite(.serialized)
struct Probe_Race4Tests {
    let acct = Account(name: "Exchange", address: "me@work.com")

    func store(_ server: RaceServer) -> MailStore {
        let s = MailStore(accounts: [], messages: [])
        s.add(acct, backend: EWSBackend(client: EWSClient(url: server.url, username: "u", password: "p")))
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

    /// Lets a cancelled file:// read finish on the pipe, so it doesn't hold up URLSession's file loader for later tests.
    func drained(_ server: RaceServer) async throws {
        try await waitFor(.seconds(2)) { server.served == 1 }
        try await Task.sleep(for: .milliseconds(400))
    }

    func waitFor(_ timeout: Duration = .seconds(5), _ cond: () -> Bool) async throws {
        let end = ContinuousClock.now + timeout
        while !cond() && ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(10)) }
    }

    // MARK: A. A load cancelled because the user moved on is reported as an error

    /// The message view loads in `.task(id: message.id)` (body, inline pictures, calendar day); the attachment
    /// thumbnails in AttachmentsView's `.task(id: message.id)`. Selecting the next message cancels those tasks.
    /// A cancelled request must not be reported as a failure. Cancelled before the request goes out (arrow key held
    /// down); the in-flight case is `zzProbeCancelledInFlightBodyLoadIsNotAnError` at the end (each probe feeds the
    /// pipe after cancelling: a cancelled file:// read left waiting stalls URLSession's file loader for later tests).
    // file:// fixture
    @Test func probeBodyLoadCancelledBeforeStartIsNotAnError() async throws {
        let server = RaceServer([RX.fault("Unused", "for the cancelled read")])
        defer { server.stop() }
        let s = store(server)
        s.merge([summary("R1")], account: acct.id, mailbox: .inbox)
        let id = s.messages[0].id
        let t = Task { await s.loadBody(id) }
        t.cancel()
        await t.value
        #expect(s.status == nil)
        try await drained(server)
    }

    // file:// fixture
    @Test func probeCancelledInlineImagesAreNotAnError() async throws {
        let server = RaceServer([RX.fault("Unused", "for the cancelled read")])
        defer { server.stop() }
        let s = store(server)
        var m = summary("R1")
        m.bodyLoaded = true; m.htmlChecked = true; m.html = "<p>Hi <img src=\"cid:logo@x\"></p>"
        s.merge([m], account: acct.id, mailbox: .inbox)
        let id = s.messages[0].id
        let t = Task { await s.loadInlineImages(for: id) }
        t.cancel()
        await t.value
        #expect(s.status == nil)
        try await drained(server)
    }

    // file:// fixture
    @Test func probeCancelledDayLoadIsNotAnError() async throws {
        let server = RaceServer([RX.fault("Unused", "for the cancelled read")])
        defer { server.stop() }
        let s = store(server)
        var m = summary("R1")
        m.bodyLoaded = true; m.htmlChecked = true
        m.invite = Invite(start: Date(timeIntervalSince1970: 1_700_000_000), end: Date(timeIntervalSince1970: 1_700_003_600),
                          isCancellation: false)
        s.merge([m], account: acct.id, mailbox: .inbox)
        let id = s.messages[0].id
        let t = Task { await s.loadDay(for: id) }
        t.cancel()
        await t.value
        #expect(s.status == nil)
        try await drained(server)
    }

    // file:// fixture
    @Test func probeCancelledThumbnailIsNotAnError() async throws {
        let server = RaceServer([RX.fault("Unused", "for the cancelled read")])
        defer { server.stop() }
        let s = store(server)
        var m = summary("R1")
        m.bodyLoaded = true; m.htmlChecked = true; m.attachments = [Attachment(name: "photo.jpg", size: 10, contentType: "image/jpeg")]
        m.hasAttachments = true
        s.merge([m], account: acct.id, mailbox: .inbox)
        let id = s.messages[0].id
        let t = Task { await s.attachmentFile(0, of: id) }
        t.cancel()
        _ = await t.value
        #expect(s.status == nil)
        try await drained(server)
    }

    // MARK: B. A body requested before the server changed the message is stored after the change

    /// The body request goes out; a sync then brings a new version of the message (edited draft, updated meeting);
    /// then the answer to the old request arrives. It is stored as the body of the new version and marked loaded,
    /// so the new text is never fetched.
    // file:// fixture
    @Test func probeBodyRequestedBeforeServerChangeIsNotKept() async throws {
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
        server.push(RX.getItem(RX.textMessage("R1", subject: "Plan v1", body: "old text")))
        await t.value
        try #require(s.status == nil, "the body request failed: \(s.status ?? "")")
        let m = try #require(s.message(id))
        // Either the new text, or the body still to be fetched: never the old text under the new subject.
        #expect(m.body != "old text" || m.needsBody, "subject \(m.subject), body \(m.body), needsBody \(m.needsBody)")
    }

    // MARK: C. A server answer fetched before a local change is applied after that change was sent

    /// Inbox not fully synced yet: every check merges its newest messages. The user flags a message purple while a
    /// check's answer (taken before the flag) is on its way; the flag is written to Exchange first. The late answer
    /// then removes the flag, and the next answer brings it back red: the colour is lost.
    // file:// fixture
    @Test func probeFlagSentWhileCheckInFlightKeepsItsColour() async throws {
        let server = RaceServer([RX.updated(["R1"])])
        defer { server.stop() }
        let s = store(server)
        s.merge([summary("R1")], account: acct.id, mailbox: .inbox)
        let id = s.messages[0].id
        let stale = [summary("R1")]  // the newest-50 answer, taken by Exchange before the flag
        s.setFlag(.purple, for: [id])
        try await waitFor { s.outbox.isEmpty }
        try #require(s.outbox.isEmpty, "the change never reached the server: \(s.status ?? "")")
        s.merge(stale, account: acct.id, mailbox: .inbox)  // refresh() applies its late answer
        #expect(s.message(id)?.flag == .purple, "after the late answer")
        s.merge([summary("R1", flagged: true)], account: acct.id, mailbox: .inbox)  // next check
        #expect(s.message(id)?.flag == .purple, "after the next check")
    }

    /// Same for Mark as Read: the message turns unread again although Exchange has it read.
    // file:// fixture
    @Test func probeReadSentWhileHistoryBatchCollectedStaysRead() async throws {
        let server = RaceServer([RX.updated(["R1"])])
        defer { server.stop() }
        let s = store(server)
        s.merge([summary("R1")], account: acct.id, mailbox: .inbox)
        let id = s.messages[0].id
        // A history batch (collected for up to 1.5 s before it is shown) holds a page taken before the read.
        let page = SyncResult(upserts: [summary("R1")], deletedRemoteIDs: [], token: "T1", more: true)
        s.toggleRead([id])
        try await waitFor { s.outbox.isEmpty }
        try #require(s.outbox.isEmpty, "the change never reached the server: \(s.status ?? "")")
        s.apply([page], account: acct.id, mailbox: .inbox)
        #expect(s.message(id)?.isRead == true)
    }

    /// The user archives a message; the move reaches Exchange (new ItemId) before the Inbox check's answer, taken
    /// before the move, arrives. The old ID is added back to the Inbox as a new message. Nothing ever reports it deleted
    /// (later newest-N answers only add), so the Inbox keeps a ghost that can't be opened.
    // file:// fixture
    @Test func probeMoveSentWhileCheckInFlightLeavesNoGhost() async throws {
        let server = RaceServer([RX.moved(["N1"])])
        defer { server.stop() }
        let s = store(server)
        s.merge([summary("R1"), summary("R2")], account: acct.id, mailbox: .inbox)
        let id = try #require(s.messages.first { $0.remoteID == "R1" }).id
        let stale = [summary("R1"), summary("R2")]  // newest answer taken before the move
        s.archive([id])
        try await waitFor { s.outbox.isEmpty }
        try #require(s.outbox.isEmpty, "the change never reached the server: \(s.status ?? "")")
        #expect(s.message(id)?.remoteID == "N1")
        s.merge(stale, account: acct.id, mailbox: .inbox)
        s.merge([summary("R2")], account: acct.id, mailbox: .inbox)  // the next checks: R1 is gone on the server
        #expect(s.count(.account(acct.id, .inbox)) == 1, "inbox \(s.messages.filter { $0.mailbox == .inbox }.map { $0.remoteID ?? "" })")
        #expect(s.messages.filter { $0.subject == "S R1" }.count == 1)
        // The history then completes the Inbox with a full sync that lists only R2: the ghost is still there.
        s.apply(SyncResult(upserts: [summary("R2")], deletedRemoteIDs: [], token: "T9", more: false), account: acct.id, mailbox: .inbox)
        #expect(s.isComplete(acct.id, .inbox))
        #expect(s.count(.account(acct.id, .inbox)) == 1, "after the full sync: \(s.messages.filter { $0.mailbox == .inbox }.map { $0.remoteID ?? "" })")
        // Control: only an explicit deletion of R1 (as a sync page would report if the stale answer had been a sync
        // page listing R1) removes the ghost. The newest-N path never produces one.
        s.apply(SyncResult(upserts: [], deletedRemoteIDs: ["R1"], token: "T10", more: false), account: acct.id, mailbox: .inbox)
        #expect(s.count(.account(acct.id, .inbox)) == 1 && s.count(.account(acct.id, .archive)) == 1, "control")
    }


    // MARK: D. Quick Look of an earlier message takes over when its file arrives late

    /// Space on message A (its attachment still downloading), then on message B (file at hand): Quick Look shows B.
    /// When A's download finishes, `previewItems`/`previewItem` are replaced by A's file: the panel jumps back to
    /// the earlier message's attachment, which the user no longer asked for.
    // file:// fixture
    @Test func probeLateQuickLookDoesNotReplaceNewerOne() async throws {
        let server = RaceServer([], hold: true)
        defer { server.stop() }
        var b = Message(accountID: acct.id, from: Contact(name: "Bob", email: "bob@x.com"), to: [], subject: "B", body: "b",
                        date: Date(timeIntervalSince1970: 1_700_000_100), attachments: [Attachment(name: "b.txt", size: 1)])
        b.hasAttachments = true
        let s = MailStore(accounts: [], messages: [b])
        s.add(acct, backend: EWSBackend(client: EWSClient(url: server.url, username: "u", password: "p")))
        s.downloadsFolder = FileManager.default.temporaryDirectory.appendingPathComponent("race-dl-\(UUID().uuidString)")
        s.setAttachmentData([Data("B".utf8)], for: b.id)
        var a = summary("R1")
        a.bodyLoaded = true; a.htmlChecked = true; a.hasAttachments = true
        a.attachments = [Attachment(name: "a.pdf", size: 7, contentType: "application/pdf")]
        s.merge([a], account: acct.id, mailbox: .inbox)
        let aid = try #require(s.messages.first { $0.remoteID == "R1" }).id
        let t = Task { await s.quickLookAttachments(of: aid) }
        try await Task.sleep(for: .milliseconds(300))  // A's GetItem is out
        await s.quickLookAttachments(of: b.id)
        #expect(s.previewItem?.lastPathComponent == "b.txt")
        server.push(RX.getItem("<t:Message><t:ItemId Id=\"R1\" ChangeKey=\"CK\"/><t:Attachments><t:FileAttachment>"
            + "<t:AttachmentId Id=\"AT-PDF\"/><t:Name>a.pdf</t:Name><t:ContentType>application/pdf</t:ContentType>"
            + "<t:Size>7</t:Size><t:IsInline>false</t:IsInline></t:FileAttachment></t:Attachments></t:Message>"))
        server.push(RX.resp("GetAttachment", RX.ok("GetAttachment", "<m:Attachments><t:FileAttachment><t:AttachmentId Id=\"AT-PDF\"/>"
            + "<t:Name>a.pdf</t:Name><t:Content>\(Data("PDFDATA".utf8).base64EncodedString())</t:Content></t:FileAttachment></m:Attachments>")))
        await t.value
        try #require(s.status == nil, "A's download failed: \(s.status ?? "")")
        #expect(s.previewItem?.lastPathComponent == "b.txt", "previewItems \(s.previewItems.map(\.lastPathComponent))")
    }


    // MARK: E. A refused erase, queued behind the move that renamed the message, brings it back under its old ID

    /// Delete twice on a server message before the first change is written: a move to Trash and an erase are queued.
    /// The move's answer renames R1 to T1 in the queued erase. Exchange refuses the erase; the message is put back,
    /// but from the copy taken when the erase was queued, with the old ID R1. The next Trash check lists T1, which
    /// is then added a second time.
    // file:// fixture
    @Test func probeRefusedEraseAfterRenameKeepsNewID() async throws {
        let server = RaceServer([RX.moved(["T1"]), RX.fault("ErrorAccessDenied", "Access is denied.")])
        defer { server.stop() }
        let s = store(server)
        s.merge([summary("R1")], account: acct.id, mailbox: .inbox)
        let id = s.messages[0].id
        s.delete([id])  // to Trash (queued move)
        s.delete([id])  // erase from Trash (queued delete of R1)
        try await waitFor { s.outbox.isEmpty }
        try #require(s.outbox.isEmpty, "the changes never reached the server: \(s.status ?? "")")
        try #require(s.status?.hasPrefix("Exchange refused a change") == true, "status \(s.status ?? "nil")")
        #expect(s.message(id)?.remoteID == "T1", "the erase was refused, the message is back with ID \(s.message(id)?.remoteID ?? "none")")
        s.merge([summary("T1", box: .trash)], account: acct.id, mailbox: .trash)  // next Trash check
        #expect(s.count(.account(acct.id, .trash)) == 1, "trash \(s.messages.filter { $0.mailbox == .trash }.map { $0.remoteID ?? "" })")
    }

    /// Control: the same two deletes, both accepted.
    // file:// fixture
    @Test func controlMoveThenEraseBothAccepted() async throws {
        let server = RaceServer([RX.moved(["T1"]), RX.resp("DeleteItem", RX.ok("DeleteItem"))])
        defer { server.stop() }
        let s = store(server)
        s.merge([summary("R1")], account: acct.id, mailbox: .inbox)
        let id = s.messages[0].id
        s.delete([id]); s.delete([id])
        try await waitFor { s.outbox.isEmpty }
        try #require(s.outbox.isEmpty)
        #expect(s.messages.isEmpty && s.status == nil, "status \(s.status ?? "nil")")
    }

    // MARK: A (continued): the in-flight variant

    /// The body request is out and the server hasn't answered when the user selects the next message.
    // file:// fixture
    @Test func zzProbeCancelledInFlightBodyLoadIsNotAnError() async throws {
        let server = RaceServer([], hold: true)
        defer { server.stop() }
        let s = store(server)
        s.merge([summary("R1")], account: acct.id, mailbox: .inbox)
        let id = s.messages[0].id
        let t = Task { await s.loadBody(id) }
        try await Task.sleep(for: .milliseconds(300))  // the request is out, the server hasn't answered
        t.cancel()  // the user selected the next message
        await t.value
        #expect(s.status == nil)
        server.push(RX.fault("Unused", "for the cancelled read"))
        try await drained(server)
    }
}
