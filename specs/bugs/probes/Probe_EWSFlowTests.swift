import Foundation
import Testing
@testable import EWS
@testable import MailModel

// MARK: - Harness

/// file:// fixture (FIFO). A named pipe at a `file://` URL stands in for the EWS endpoint: every request the real
/// EWSClient makes opens the pipe and reads the next hand-written response of the script, in order. No network,
/// no fake class: the real EWSClient, EWSBackend and MailStore run unchanged. After the script, `fallback` is
/// served (by default a SOAP fault, so a request the script didn't expect fails instead of hanging); with `hold`,
/// a request after the script waits until a response is pushed.
final class FlowServer: @unchecked Sendable {
    let url: URL
    private let path: String
    private let lock = NSLock()
    private var script: [String]
    private var fallbackXML: String
    private var stopped = false
    private var hold = false
    private var _served = 0

    var served: Int { lock.withLock { _served } }

    init(_ script: [String], fallback: String? = nil, hold: Bool = false) {
        self.hold = hold
        path = FileManager.default.temporaryDirectory.appendingPathComponent("ews-fifo-\(UUID().uuidString).xml").path
        mkfifo(path, 0o600)
        url = URL(fileURLWithPath: path)
        self.script = script
        fallbackXML = fallback ?? FX.fault("ErrorScriptExhausted", "No scripted response left")
        let t = Thread { [self] in loop() }
        t.start()
    }

    func push(_ xml: String) { lock.withLock { script.append(xml) } }
    func setFallback(_ xml: String) { lock.withLock { fallbackXML = xml } }
    func stop() { lock.withLock { stopped = true } }
    var pending: Int { lock.withLock { script.count } }

    private func loop() {
        signal(SIGPIPE, SIG_IGN)
        while true {
            if lock.withLock({ stopped }) { return }
            if lock.withLock({ hold && script.isEmpty }) { usleep(500); continue }
            let fd = open(path, O_WRONLY | O_NONBLOCK)  // fails until a request opens the pipe
            if fd < 0 { usleep(500); continue }
            _ = fcntl(fd, F_SETFL, 0)
            let xml = lock.withLock { script.isEmpty ? fallbackXML : script.removeFirst() }
            let bytes = Array(xml.utf8)
            var off = 0
            while off < bytes.count {
                let n = bytes[off...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
                if n <= 0 { break }
                off += n
            }
            lock.withLock { _served += 1 }
            close(fd)
            // URLSession's file loader keeps reading the pipe for a while after the end of the response (it
            // finishes about 150 ms later). Serving the next response before it lets go would hand it to this
            // request, so wait until no reader is left.
            usleep(300_000)
        }
    }
}

/// Hand-written Exchange responses.
enum FX {
    static func env(_ body: String) -> String {
        """
        <?xml version="1.0" encoding="utf-8"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">\
        <s:Header><h:ServerVersionInfo MajorVersion="15" MinorVersion="1" MajorBuildNumber="2507" MinorBuildNumber="6" \
        xmlns:h="http://schemas.microsoft.com/exchange/services/2006/types"/></s:Header><s:Body \
        xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema">\(body)</s:Body></s:Envelope>
        """
    }
    static let ns = "xmlns:m=\"http://schemas.microsoft.com/exchange/services/2006/messages\" xmlns:t=\"http://schemas.microsoft.com/exchange/services/2006/types\""

    static func ok(_ op: String, _ inner: String = "") -> String {
        "<m:\(op)ResponseMessage ResponseClass=\"Success\"><m:ResponseCode>NoError</m:ResponseCode>\(inner)</m:\(op)ResponseMessage>"
    }
    static func err(_ op: String, _ code: String, _ text: String? = nil) -> String {
        "<m:\(op)ResponseMessage ResponseClass=\"Error\"><m:MessageText>\(text ?? code + " text")</m:MessageText>"
            + "<m:ResponseCode>\(code)</m:ResponseCode><m:DescriptiveLinkKey>0</m:DescriptiveLinkKey></m:\(op)ResponseMessage>"
    }
    static func resp(_ op: String, _ messages: String) -> String {
        env("<m:\(op)Response \(ns)><m:ResponseMessages>\(messages)</m:ResponseMessages></m:\(op)Response>")
    }
    static func fault(_ code: String, _ text: String) -> String {
        """
        <?xml version="1.0" encoding="utf-8"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>\
        <s:Fault><faultcode xmlns:a="http://schemas.microsoft.com/exchange/services/2006/types">a:\(code)</faultcode>\
        <faultstring xml:lang="en-US">\(text)</faultstring><detail>\
        <e:ResponseCode xmlns:e="http://schemas.microsoft.com/exchange/services/2006/errors">\(code)</e:ResponseCode>\
        <e:Message xmlns:e="http://schemas.microsoft.com/exchange/services/2006/errors">\(text)</e:Message></detail></s:Fault></s:Body></s:Envelope>
        """
    }

    /// One SyncFolderItems page.
    static func sync(_ changes: String, token: String, last: Bool) -> String {
        resp("SyncFolderItems", ok("SyncFolderItems", "<m:SyncState>\(token)</m:SyncState>"
            + "<m:IncludesLastItemInRange>\(last)</m:IncludesLastItemInRange><m:Changes>\(changes)</m:Changes>"))
    }
    /// A list summary as SyncFolderItems / FindItem return it.
    static func summary(_ id: String, subject: String = "Hello", read: Bool = false, kind: String = "Message",
                        date: String = "2026-11-10T09:30:00Z", preview: String = "Preview", from: String = "Ann") -> String {
        "<t:\(kind)><t:ItemId Id=\"\(id)\" ChangeKey=\"CK\"/><t:Subject>\(subject)</t:Subject>"
            + "<t:DateTimeReceived>\(date)</t:DateTimeReceived><t:HasAttachments>false</t:HasAttachments>"
            + "<t:Preview>\(preview)</t:Preview><t:DisplayTo>Me</t:DisplayTo><t:DisplayCc/>"
            + "<t:ConversationId Id=\"CONV-\(id)\"/><t:IsRead>\(read)</t:IsRead>"
            + "<t:From><t:Mailbox><t:Name>\(from)</t:Name></t:Mailbox></t:From></t:\(kind)>"
    }
    static func create(_ item: String) -> String { "<t:Create>\(item)</t:Create>" }
    static func update(_ item: String) -> String { "<t:Update>\(item)</t:Update>" }
    static func delete(_ id: String) -> String { "<t:Delete><t:ItemId Id=\"\(id)\" ChangeKey=\"CK\"/></t:Delete>" }

    static func findItem(_ items: String, last: Bool = true) -> String {
        resp("FindItem", ok("FindItem", "<m:RootFolder IndexedPagingOffset=\"0\" TotalItemsInView=\"1\" "
            + "IncludesLastItemInRange=\"\(last)\"><t:Items>\(items)</t:Items></m:RootFolder>"))
    }
    static func getItem(_ item: String) -> String { resp("GetItem", ok("GetItem", "<m:Items>\(item)</m:Items>")) }
    static func created(_ id: String, ck: String = "CK1") -> String {
        resp("CreateItem", ok("CreateItem", "<m:Items><t:Message><t:ItemId Id=\"\(id)\" ChangeKey=\"\(ck)\"/></t:Message></m:Items>"))
    }
    static let createdNoItems = resp("CreateItem", ok("CreateItem", "<m:Items/>"))
    static func attachmentsCreated(root: String, count: Int = 1) -> String {
        resp("CreateAttachment", (0..<count).map { i in
            ok("CreateAttachment", "<m:Attachments><t:FileAttachment><t:AttachmentId Id=\"AT\(i)\" RootItemId=\"\(root)\" "
                + "RootItemChangeKey=\"CK\(i + 2)\"/></t:FileAttachment></m:Attachments>")
        }.joined())
    }
    static let sent = resp("SendItem", ok("SendItem"))
    static func deleted(_ n: Int = 1) -> String { resp("DeleteItem", String(repeating: ok("DeleteItem"), count: n)) }
    static func moved(_ new: [String]) -> String {
        resp("MoveItem", new.map { ok("MoveItem", "<m:Items><t:Message><t:ItemId Id=\"\($0)\" ChangeKey=\"CK\"/></t:Message></m:Items>") }.joined())
    }
    static func updated(_ ids: [String]) -> String {
        resp("UpdateItem", ids.map { ok("UpdateItem", "<m:Items><t:Message><t:ItemId Id=\"\($0)\" ChangeKey=\"CK\"/></t:Message></m:Items>") }.joined())
    }
    static func mailTips(_ size: String) -> String {
        env("<m:GetMailTipsResponse ResponseClass=\"Success\" \(ns)><m:ResponseCode>NoError</m:ResponseCode><m:ResponseMessages>"
            + "<m:MailTipsResponseMessageType ResponseClass=\"Success\"><m:ResponseCode>NoError</m:ResponseCode><m:MailTips>"
            + "<t:RecipientAddress><t:Name/><t:EmailAddress>me@work.com</t:EmailAddress><t:RoutingType>SMTP</t:RoutingType></t:RecipientAddress>"
            + "<t:PendingMailTips/><t:MaxMessageSize>\(size)</t:MaxMessageSize></m:MailTips></m:MailTipsResponseMessageType>"
            + "</m:ResponseMessages></m:GetMailTipsResponse>")
    }
    static func folders(_ list: [(String, String)]) -> String {
        resp("GetFolder", list.map { id, name in
            ok("GetFolder", "<m:Folders><t:Folder><t:FolderId Id=\"\(id)\" ChangeKey=\"AQ\"/><t:DisplayName>\(name)</t:DisplayName>"
                + "<t:TotalCount>0</t:TotalCount></t:Folder></m:Folders>")
        }.joined())
    }
    static let standardFolders = folders([("INBOX", "Inbox"), ("DRAFTS", "Drafts"), ("SENT", "Sent Items"),
                                          ("JUNK", "Junk Email"), ("DEL", "Deleted Items"), ("OUTBOX", "Outbox")])
    static func findFolder(_ folders: String = "", last: Bool = true, offset: Int = 0) -> String {
        resp("FindFolder", ok("FindFolder", "<m:RootFolder IndexedPagingOffset=\"\(offset)\" TotalItemsInView=\"0\" "
            + "IncludesLastItemInRange=\"\(last)\"><t:Folders>\(folders)</t:Folders></m:RootFolder>"))
    }
}

@MainActor
@Suite(.serialized)
struct Probe_EWSFlowTests {
    let acct = Account(name: "Exchange", address: "me@work.com")

    /// A store with one Exchange account whose server is `server`; the folder list is already known.
    func store(_ server: FlowServer, folders: Bool = true) -> MailStore {
        let s = MailStore(accounts: [], messages: [])
        s.add(acct, backend: EWSBackend(client: EWSClient(url: server.url, username: "u", password: "p")))
        if folders {
            s.setRemoteFolders([RemoteFolder(role: .inbox, id: "INBOX"), RemoteFolder(role: .drafts, id: "DRAFTS"),
                                RemoteFolder(role: .sent, id: "SENT"), RemoteFolder(role: .trash, id: "DEL"),
                                RemoteFolder(role: .archive, id: "ARCH")], account: acct.id)
        }
        return s
    }

    /// Marks a folder fully synced, so the quick check asks it for changes.
    func complete(_ s: MailStore, _ box: MailboxKind, token: String = "T0") {
        s.apply(SyncResult(upserts: [], deletedRemoteIDs: [], token: token, more: false), account: acct.id, mailbox: box)
    }

    func serverMessage(_ rid: String, box: MailboxKind = .inbox, subject: String? = nil, body: String = "",
                       loaded: Bool = false, invite: Invite? = nil) -> Message {
        var m = Message(accountID: acct.id, mailbox: box, from: Contact(name: "Ann", email: "ann@x.com"),
                        to: [Contact(name: "Me", email: "me@work.com")], subject: subject ?? "S \(rid)", body: body,
                        date: Date(timeIntervalSince1970: 1_000_000), remoteID: rid, bodyLoaded: loaded, invite: invite)
        if loaded { m.htmlChecked = true }
        return m
    }

    func waitFor(_ timeout: Duration = .seconds(5), _ cond: () -> Bool) async throws {
        let end = ContinuousClock.now + timeout
        while !cond() && ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(10)) }
    }

    // MARK: Controls (the harness works)

    // file:// fixture
    @Test func controlSendPlainText() async throws {
        let server = FlowServer([FX.created("NEW")])
        defer { server.stop() }
        let s = store(server)
        s.send(Draft(accountID: acct.id, to: "bob@x.com", subject: "Hi", body: "Hello"))
        try await waitFor { s.outbox.isEmpty }
        #expect(s.outbox.isEmpty && s.status == nil && server.served == 1, "status \(s.status ?? "") served \(server.served)")
    }

    // file:// fixture
    @Test func controlSendWithAttachmentsThreeSteps() async throws {
        let server = FlowServer([FX.created("D1"), FX.attachmentsCreated(root: "D1"), FX.sent])
        defer { server.stop() }
        let s = store(server)
        var d = Draft(accountID: acct.id, to: "bob@x.com", subject: "Report", body: "See file")
        d.attachments = [DraftAttachment(name: "r.pdf", contentType: "application/pdf", data: Data(repeating: 7, count: 100))]
        s.send(d)
        try await waitFor { s.outbox.isEmpty }
        #expect(s.status == nil && server.served == 3, "status \(s.status ?? "") served \(server.served)")
    }

    // MARK: Folder list

    /// GetFolder answers each standard folder with an error (mailbox store unavailable, e.g. during a mailbox move).
    /// The check ends without any status and the empty folder list is kept for the session: the Inbox is never
    /// checked again until relaunch.
    // file:// fixture
    @Test func probeFolderListWithoutInboxIsReportedOrRetried() async throws {
        let e = FX.err("GetFolder", "ErrorMailboxStoreUnavailable", "The mailbox database is temporarily unavailable.")
        let server = FlowServer([FX.resp("GetFolder", String(repeating: e, count: 6)), FX.findFolder()],
                                    fallback: FX.sync("", token: "T1", last: true))
        defer { server.stop() }
        let s = store(server, folders: false)
        await s.refresh(history: false)
        let afterFirst = server.served, status = s.status
        await s.refresh(history: false)
        #expect(status != nil || server.served > afterFirst,
                "status \(String(describing: status)); requests: first check \(afterFirst), second check \(server.served - afterFirst)")
    }

    // MARK: Paging

    // MARK: Drafts edited elsewhere

    /// A draft opened here, then edited in Outlook: the sync reports an Update with the new preview. The text
    /// stays the old one and is never fetched again.
    // file:// fixture
    @Test func probeDraftEditedElsewhereShowsNewText() async throws {
        let server = FlowServer([
            FX.sync("", token: "T1", last: true),  // Inbox
            FX.sync(FX.update(FX.summary("D", subject: "Plan v2", read: true, preview: "New text from Outlook")), token: "T1", last: true),
        ])
        defer { server.stop() }
        let s = store(server)
        complete(s, .inbox); complete(s, .drafts)
        s.merge([serverMessage("D", box: .drafts, subject: "Plan", body: "Old text", loaded: true)], account: acct.id, mailbox: .drafts)
        s.selectedMailbox = .account(acct.id, .drafts)
        await s.refresh(history: false)
        let d = try #require(s.messages.first { $0.remoteID == "D" })
        #expect(d.subject == "Plan v2")
        #expect(d.body != "Old text" || d.needsBody, "body \(d.body.debugDescription), needsBody \(d.needsBody), preview \(d.preview.debugDescription)")
    }

    // MARK: History

    func meetingRequest(_ id: String, subject: String = "Sync", start: String = "2026-11-23T10:00:00Z",
                        end: String = "2026-11-23T11:00:00Z", kind: String = "MeetingRequest", extra: String = "") -> String {
        "<t:\(kind)><t:ItemId Id=\"\(id)\" ChangeKey=\"CK\"/><t:Subject>\(subject)</t:Subject>"
            + "<t:Body BodyType=\"Text\">Let's meet</t:Body><t:Attachments/>"
            + "<t:From><t:Mailbox><t:Name>Org</t:Name><t:EmailAddress>org@work.com</t:EmailAddress></t:Mailbox></t:From>"
            + "<t:ToRecipients><t:Mailbox><t:Name>Me</t:Name><t:EmailAddress>me@work.com</t:EmailAddress></t:Mailbox></t:ToRecipients>"
            + "<t:TextBody BodyType=\"Text\">Let's meet</t:TextBody>\(extra)"
            + "<t:Start>\(start)</t:Start><t:End>\(end)</t:End><t:Location>Room 1</t:Location><t:IsAllDayEvent>false</t:IsAllDayEvent>"
            + "<t:Organizer><t:Mailbox><t:Name>Org</t:Name><t:EmailAddress>org@work.com</t:EmailAddress></t:Mailbox></t:Organizer>"
            + "</t:\(kind)>"
    }

    /// History over three pages (control).
    // file:// fixture
    @Test func controlHistoryThreePages() async throws {
        let server = FlowServer([
            FX.findItem(FX.summary("A")),
            FX.sync(FX.create(FX.summary("A")) + FX.create(FX.summary("B")), token: "T1", last: false),
            FX.sync(FX.create(FX.summary("C")), token: "T2", last: false),
            FX.sync(FX.create(FX.summary("D")) + FX.delete("B"), token: "T3", last: true),
        ])
        defer { server.stop() }
        let s = store(server, folders: false)
        s.setRemoteFolders([RemoteFolder(role: .inbox, id: "INBOX", totalCount: 3)], account: acct.id)
        await s.syncHistory()
        #expect(s.isComplete(acct.id, .inbox) && s.syncToken(acct.id, .inbox) == "T3")
        #expect(s.messages.compactMap(\.remoteID).sorted() == ["A", "C", "D"], "\(s.messages.compactMap(\.remoteID)) served \(server.served)")
    }

    /// NOT FILED (README: "A folder whose history fails is skipped, and the error stays under the window title";
    /// transient errors treated as final are BUG-061's theme). Kept as a record.
    /// Exchange throttles big downloads (ErrorServerBusy, "try again later"). One throttled page abandons the
    /// folder's history for the rest of the session: later history runs never ask for it again, the folder never
    /// completes, and the error stays under the window title.
    // file:// fixture
    @Test func probeHistoryContinuesAfterThrottling() async throws {
        let server = FlowServer([
            FX.findItem(FX.summary("A")),
            FX.sync(FX.create(FX.summary("A")), token: "T1", last: false),
            FX.fault("ErrorServerBusy", "The server cannot service this request right now. Try again later."),
            FX.sync(FX.create(FX.summary("B")), token: "T2", last: true),
        ])
        defer { server.stop() }
        let s = store(server, folders: false)
        s.setRemoteFolders([RemoteFolder(role: .inbox, id: "INBOX", totalCount: 2)], account: acct.id)
        await s.syncHistory()
        let firstStatus = s.status
        // The app starts the history again with every check (every 15 s).
        await s.syncHistory()
        await s.syncHistory()
        let done = s.isComplete(acct.id, .inbox), token = s.syncToken(acct.id, .inbox), requests = server.served
        #expect(done, "complete \(done), token \(String(describing: token)), requests \(requests) (4 scripted), status \(String(describing: firstStatus))")
    }

    // MARK: Invites

    /// Accept an invite: it moves to Trash here at once, as README says Exchange will do. Exchange then moves it
    /// to Deleted Items under a new ID: the Inbox sync deletes the old ID, the Trash sync brings the new one. The
    /// answer given here is gone: the invite in Trash says "Please respond" again and offers Accept/Decline.
    // file:// fixture
    @Test func probeAnsweredInviteKeepsItsAnswerAfterExchangeMovesIt() async throws {
        let server = FlowServer([
            FX.resp("CreateItem", FX.ok("CreateItem")),               // AcceptItem
            FX.sync(FX.delete("M"), token: "T1", last: true),         // Inbox
            FX.sync(FX.create(FX.summary("M2", subject: "Sync", read: true, kind: "MeetingRequest")), token: "T1", last: true),  // Trash
            FX.getItem(meetingRequest("M2")),                        // body of the invite in Trash
        ])
        defer { server.stop() }
        let s = store(server)
        complete(s, .inbox); complete(s, .trash)
        let inv = Invite(start: Date(timeIntervalSince1970: 1_795_428_000), end: Date(timeIntervalSince1970: 1_795_431_600),
                         organizer: Contact(name: "Org", email: "org@work.com"), isCancellation: false)
        s.merge([serverMessage("M", subject: "Sync", body: "Let's meet", loaded: true, invite: inv)], account: acct.id, mailbox: .inbox)
        let id = try #require(s.messages.first?.id)
        s.respond(.accept, to: id)
        try await waitFor { s.outbox.isEmpty }
        #expect(s.messages.first?.invite?.response == .accept)
        s.selectedMailbox = .account(acct.id, .trash)
        await s.refresh(history: false)
        let m = try #require(s.messages.first { $0.mailbox == .trash })
        await s.loadBody(m.id)
        let after = try #require(s.message(m.id))
        #expect(after.invite?.response == .accept,
                "invite in Trash: rid \(after.remoteID ?? ""), response \(String(describing: after.invite?.response)), requests \(server.served), status \(String(describing: s.status))")
    }

    /// Do Not Send a Response: answer saved only, then the store moves the invite to Trash itself (control).
    // file:// fixture
    @Test func controlAnswerWithoutSendingMovesToTrash() async throws {
        let server = FlowServer([FX.resp("CreateItem", FX.ok("CreateItem")), FX.moved(["M-T"])])
        defer { server.stop() }
        let s = store(server)
        let inv = Invite(start: .now, end: .now.addingTimeInterval(3600), isCancellation: false)
        s.merge([serverMessage("M", loaded: true, invite: inv)], account: acct.id, mailbox: .inbox)
        s.respond(InviteReply(response: .decline, send: false), to: s.messages[0].id)
        try await waitFor { s.outbox.isEmpty }
        #expect(s.messages[0].remoteID == "M-T" && s.messages[0].mailbox == .trash && server.served == 2 && s.status == nil,
                "rid \(s.messages[0].remoteID ?? "") served \(server.served) status \(s.status ?? "")")
    }

    /// Open an invite, then its calendar day (control): the invite's own tentative entry is not a conflict.
    // file:// fixture
    @Test func controlInviteBodyAndDay() async throws {
        let cal = FX.findItem("""
            <t:CalendarItem><t:ItemId Id="C1"/><t:Subject>Sync</t:Subject><t:Start>2026-11-23T10:00:00Z</t:Start><t:End>2026-11-23T11:00:00Z</t:End>\
            <t:IsAllDayEvent>false</t:IsAllDayEvent><t:LegacyFreeBusyStatus>Tentative</t:LegacyFreeBusyStatus></t:CalendarItem>\
            <t:CalendarItem><t:ItemId Id="C2"/><t:Subject>1:1</t:Subject><t:Start>2026-11-23T10:30:00Z</t:Start><t:End>2026-11-23T11:30:00Z</t:End>\
            <t:IsAllDayEvent>false</t:IsAllDayEvent><t:LegacyFreeBusyStatus>Busy</t:LegacyFreeBusyStatus></t:CalendarItem>
            """)
        let server = FlowServer([FX.getItem(meetingRequest("M")), cal])
        defer { server.stop() }
        let s = store(server)
        s.merge([serverMessage("M", subject: "Sync")], account: acct.id, mailbox: .inbox)
        let id = s.messages[0].id
        await s.loadBody(id)
        await s.loadDay(for: id)
        let m = try #require(s.message(id)), inv = try #require(m.invite)
        #expect(inv.conflicts(in: s.dayEvents[id] ?? [], subject: m.subject).map(\.subject) == ["1:1"], "status \(s.status ?? "")")
    }

    // MARK: Attachments, pictures, size

    // file:// fixture
    @Test func controlOpenAttachmentAndInlineImages() async throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3]).base64EncodedString()
        let pdf = Data("PDFDATA".utf8).base64EncodedString()
        let item = """
            <t:Message><t:ItemId Id="M" ChangeKey="CK"/><t:Subject>Pics</t:Subject>\
            <t:Body BodyType="HTML">&lt;html&gt;&lt;body&gt;Hi &lt;img src="cid:logo@x"&gt;&lt;/body&gt;&lt;/html&gt;</t:Body>\
            <t:Attachments><t:FileAttachment><t:AttachmentId Id="AT-LOGO"/><t:Name>logo.png</t:Name><t:ContentType>image/png</t:ContentType>\
            <t:ContentId>logo@x</t:ContentId><t:Size>7</t:Size><t:IsInline>true</t:IsInline></t:FileAttachment>\
            <t:FileAttachment><t:AttachmentId Id="AT-PDF"/><t:Name>a.pdf</t:Name><t:ContentType>application/pdf</t:ContentType>\
            <t:Size>7</t:Size><t:IsInline>false</t:IsInline></t:FileAttachment></t:Attachments>\
            <t:TextBody BodyType="Text">Hi</t:TextBody></t:Message>
            """
        let server = FlowServer([
            FX.getItem(item), FX.getItem(item),
            FX.resp("GetAttachment", FX.ok("GetAttachment", "<m:Attachments><t:FileAttachment><t:AttachmentId Id=\"AT-LOGO\"/><t:Name>logo.png</t:Name><t:ContentType>image/png</t:ContentType><t:ContentId>logo@x</t:ContentId><t:Content>\(png)</t:Content></t:FileAttachment></m:Attachments>")),
            FX.getItem(item),
            FX.resp("GetAttachment", FX.ok("GetAttachment", "<m:Attachments><t:FileAttachment><t:AttachmentId Id=\"AT-PDF\"/><t:Name>a.pdf</t:Name><t:Content>\(pdf)</t:Content></t:FileAttachment></m:Attachments>")),
        ])
        defer { server.stop() }
        let s = store(server)
        s.downloadsFolder = FileManager.default.temporaryDirectory.appendingPathComponent("dl-\(UUID().uuidString)")
        s.merge([serverMessage("M")], account: acct.id, mailbox: .inbox)
        let id = s.messages[0].id
        await s.loadBody(id)
        await s.loadInlineImages(for: id)
        #expect(s.message(id)?.attachments.map(\.name) == ["a.pdf"])
        #expect(s.inlineImages(for: id)["logo@x"]?.data.count == 7, "status \(s.status ?? "")")
        let url = await s.attachmentFile(0, of: id)
        #expect(url.flatMap { try? Data(contentsOf: $0) } == Data("PDFDATA".utf8), "status \(s.status ?? "")")
    }

    // file:// fixture
    @Test func controlMaxMessageSize() async throws {
        let server = FlowServer([FX.mailTips("36700160")])
        defer { server.stop() }
        let s = store(server)
        await s.loadMaxMessageSize(for: acct.id)
        #expect(s.maxMessageSizes[acct.id] == 36_700_160)
    }

    // MARK: Batch 3

    /// file:// fixture (plain file): the history's paging has the same gap. A server repeating "more" with the same
    /// SyncState keeps the history asking for the same page without end (the progress bar never goes away).
    @Test func probeHistoryPagingEndsStaticFile() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ews-\(UUID().uuidString).xml")
        try Data(FX.sync("", token: "T1", last: false).utf8).write(to: url)
        let s = MailStore(accounts: [], messages: [])
        s.add(acct, backend: EWSBackend(client: EWSClient(url: url, username: "u", password: "p")))  // file:// fixture
        s.setRemoteFolders([RemoteFolder(role: .inbox, id: "INBOX", totalCount: 1)], account: acct.id)
        let task = Task { await s.syncHistory() }
        try await Task.sleep(for: .seconds(4))
        let progress = s.progress, token = s.syncToken(acct.id, .inbox)
        try Data(FX.sync("", token: "T1", last: true).utf8).write(to: url)
        await task.value
        #expect(progress == nil, "history still running after 4 s, token \(String(describing: token)), progress \(String(describing: progress))")
    }

    /// NOT FILED: BUG-060's trigger (an answer without any EWS result). Kept as a record.
    /// The folder list from an answer without any result (empty SOAP body): no Inbox, no status, never asked again.
    // file:// fixture
    @Test func probeFolderListFromEmptyAnswerIsRetried() async throws {
        let server = FlowServer([FX.env(""), FX.env("")], fallback: FX.sync("", token: "T1", last: true))
        defer { server.stop() }
        let s = store(server, folders: false)
        await s.refresh(history: false)
        let afterFirst = server.served, status = s.status
        await s.refresh(history: false)
        let second = server.served - afterFirst
        #expect(status != nil || second > 0, "status \(String(describing: status)); requests: first check \(afterFirst), second check \(second)")
    }

    /// A cancellation: open it, Remove from Calendar (control).
    // file:// fixture
    @Test func controlCancellationRemoveFromCalendar() async throws {
        let server = FlowServer([FX.getItem(meetingRequest("C", subject: "Canceled: Sync", kind: "MeetingCancellation")),
                                     FX.resp("CreateItem", FX.ok("CreateItem")), FX.moved(["C-T"])])
        defer { server.stop() }
        let s = store(server)
        s.merge([serverMessage("C", subject: "Canceled: Sync")], account: acct.id, mailbox: .inbox)
        let id = s.messages[0].id
        await s.loadBody(id)
        #expect(s.message(id)?.invite?.isCancellation == true)
        s.removeFromCalendar(id)
        try await waitFor { s.outbox.isEmpty }
        let m = try #require(s.message(id))
        #expect(m.mailbox == .trash && m.remoteID == "C-T" && s.status == nil, "\(m.mailbox.rawValue) \(m.remoteID ?? "") \(s.status ?? "")")
    }

    /// A picture placed in the text: HTML body, inline attachment, send (control).
    // file:// fixture
    @Test func controlSendPlacedPicture() async throws {
        let server = FlowServer([FX.created("D1"), FX.attachmentsCreated(root: "D1"), FX.sent])
        defer { server.stop() }
        let s = store(server)
        var d = Draft(accountID: acct.id, to: "bob@x.com", subject: "Pic", body: "Look:\n\(Draft.fileMark)\nNice")
        d.attachments = [DraftAttachment(name: "p.png", contentType: "image/png", data: Data([1, 2, 3]))]
        s.send(d)
        try await waitFor { s.outbox.isEmpty }
        #expect(s.status == nil && server.served == 3, "status \(s.status ?? "") served \(server.served)")
    }

    /// Folder list over two FindFolder pages (control).
    // file:// fixture
    @Test func controlFolderListTwoPages() async throws {
        let f = { (id: String, name: String) in
            "<t:Folder><t:FolderId Id=\"\(id)\"/><t:ParentFolderId Id=\"ROOT\"/><t:FolderClass>IPF.Note</t:FolderClass><t:DisplayName>\(name)</t:DisplayName><t:TotalCount>1</t:TotalCount></t:Folder>"
        }
        let server = FlowServer([FX.standardFolders, FX.findFolder(f("P1", "Projects"), last: false, offset: 1),
                                     FX.findFolder(f("P2", "Archive"), last: true, offset: 2)],
                                    fallback: FX.sync("", token: "T1", last: true))
        defer { server.stop() }
        let s = store(server, folders: false)
        await s.refresh(history: false)
        #expect(s.children(of: nil, account: acct.id).map(\.name) == ["Projects"], "status \(s.status ?? "")")
        #expect(s.name(of: .archive, in: acct.id) == "Archive")
    }

    /// Offline (the endpoint can't be reached): what the user sees (control).
    // file:// fixture
    @Test func controlOffline() async throws {
        let s = MailStore(accounts: [], messages: [])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("no-such-\(UUID().uuidString).xml")
        s.add(acct, backend: EWSBackend(client: EWSClient(url: url, username: "u", password: "p")))
        s.setRemoteFolders([RemoteFolder(role: .inbox, id: "INBOX")], account: acct.id)
        s.merge([serverMessage("A")], account: acct.id, mailbox: .inbox)
        s.toggleRead(Set(s.messages.map(\.id)))
        try await waitFor(.seconds(2)) { s.status != nil }
        #expect(s.outbox.count == 1 && s.messages[0].isRead, "status \(s.status ?? "")")
    }

    // MARK: Batch 4

    // file:// fixture (FIFO)
    /// file:// fixture (plain file, as round 2): the quick check's paging loop against a server that repeats
    /// "more" with the same SyncState.
    // file:// fixture
    @Test func probeQuickCheckPagingEndsStaticFile() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ews-\(UUID().uuidString).xml")
        try Data(FX.sync("", token: "T1", last: false).utf8).write(to: url)
        let s = MailStore(accounts: [], messages: [])
        s.add(acct, backend: EWSBackend(client: EWSClient(url: url, username: "u", password: "p")))  // file:// fixture
        s.setRemoteFolders([RemoteFolder(role: .inbox, id: "INBOX")], account: acct.id)
        complete(s, .inbox, token: "T1")
        let task = Task { await s.refresh(history: false) }
        try await Task.sleep(for: .seconds(3))
        let stillRunning = s.isRefreshing
        try Data(FX.sync("", token: "T1", last: true).utf8).write(to: url)
        await task.value
        #expect(!stillRunning, "the check is still running after 3 s (same page asked again and again)")
    }

    // file:// fixture (FIFO)
    /// README: the quick check runs "at once when you select a mailbox". Selecting one while a check is running
    /// (every 15 s, so often) does nothing: the running check doesn't include it and the new one returns at once.
    // file:// fixture
    @Test func probeMailboxSelectedDuringCheckIsChecked() async throws {
        let server = FlowServer([], hold: true)
        defer { server.stop() }
        let s = store(server)
        complete(s, .inbox); complete(s, .archive)
        let first = Task { await s.refresh(history: false) }
        try await waitFor { s.isRefreshing }
        try await Task.sleep(for: .milliseconds(100))   // the Inbox request is waiting for the server
        s.selectedMailbox = .account(acct.id, .archive)
        let second = Task { await s.refresh(history: false) }   // what the sidebar does on selection
        try await Task.sleep(for: .milliseconds(100))
        server.push(FX.sync("", token: "T1", last: true))   // Inbox
        server.push(FX.sync(FX.create(FX.summary("NEWARCH", subject: "Filed elsewhere")), token: "T1", last: true))  // Archive
        await first.value; await second.value
        try await Task.sleep(for: .milliseconds(200))
        #expect(s.messages.contains { $0.remoteID == "NEWARCH" }, "requests \(server.served), unasked responses \(server.pending)")
    }

    // file:// fixture (FIFO)
    /// Per-item errors when opening things, then a retry that works (control).
    // file:// fixture
    @Test func controlPerItemErrorsThenRetry() async throws {
        let notFound = { (op: String) in FX.resp(op, FX.err(op, "ErrorItemNotFound", "The specified object was not found in the store.")) }
        let server = FlowServer([
            notFound("GetItem"), FX.getItem(meetingRequest("M")),
            FX.resp("FindItem", FX.err("FindItem", "ErrorCalendarViewRangeTooBig")),
            FX.findItem(""),
            FX.resp("GetMailTips", FX.err("GetMailTips", "ErrorMailTipsDisabled")), FX.mailTips("1000"),
        ])
        defer { server.stop() }
        let s = store(server)
        s.merge([serverMessage("M", subject: "Sync")], account: acct.id, mailbox: .inbox)
        let id = s.messages[0].id
        await s.loadBody(id)
        let st1 = s.status
        await s.loadBody(id)
        #expect(st1?.contains("Couldn't load message") == true && s.message(id)?.invite != nil)
        await s.loadDay(for: id)
        let st2 = s.status
        await s.loadDay(for: id)
        #expect(st2?.contains("calendar") == true && s.dayEvents[id] == [])
        await s.loadMaxMessageSize(for: acct.id)
        await s.loadMaxMessageSize(for: acct.id)
        #expect(s.maxMessageSizes[acct.id] == 1000)
    }

    // MARK: Plain-file ports (file:// fixture, a plain file rewritten between awaited calls)

    func fileStore(_ first: String) throws -> (MailStore, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ews-\(UUID().uuidString).xml")
        try Data(first.utf8).write(to: url)
        let s = MailStore(accounts: [], messages: [])
        s.add(acct, backend: EWSBackend(client: EWSClient(url: url, username: "u", password: "p")))  // file:// fixture
        s.setRemoteFolders([RemoteFolder(role: .inbox, id: "INBOX"), RemoteFolder(role: .drafts, id: "DRAFTS"),
                            RemoteFolder(role: .trash, id: "DEL")], account: acct.id)
        return (s, url)
    }

    // file:// fixture
    /// R3-EWSFlow-03 on a plain response file: the Inbox is still syncing (its newest-50 lookup finds no items in this
    /// answer), the Drafts folder gets the Update.
    @Test func probeDraftEditedElsewhereShowsNewTextStaticFile() async throws {
        let (s, _) = try fileStore(FX.sync(FX.update(FX.summary("D", subject: "Plan v2", read: true, preview: "New text from Outlook")), token: "T1", last: true))
        complete(s, .drafts)
        s.merge([serverMessage("D", box: .drafts, subject: "Plan", body: "Old text", loaded: true)], account: acct.id, mailbox: .drafts)
        s.selectedMailbox = .account(acct.id, .drafts)
        await s.refresh(history: false)
        let d = try #require(s.messages.first { $0.remoteID == "D" })
        #expect(d.subject == "Plan v2", "status \(s.status ?? "")")
        #expect(d.body != "Old text" || d.needsBody, "body \(d.body.debugDescription), needsBody \(d.needsBody), preview \(d.preview.debugDescription)")
    }

    // file:// fixture
    /// Every step against garbage and against an empty (0-byte) answer: the user gets a status, a change stays
    /// queued (BUG-061), a failed send is kept in Drafts, nothing is marked complete (control table).
    @Test func controlGarbageAndEmptyAnswerAtEachStep() async throws {
        for (label, answer) in [("garbage", "<html><body>Proxy error<br></body>"), ("empty", "")] {
            let (s, url) = try fileStore(answer)
            s.downloadsFolder = FileManager.default.temporaryDirectory.appendingPathComponent("dl-\(UUID().uuidString)")
            let inv = Invite(start: .now, end: .now.addingTimeInterval(3600), isCancellation: false)
            s.merge([serverMessage("A"), serverMessage("B", loaded: true, invite: inv)], account: acct.id, mailbox: .inbox)
            var m = serverMessage("C", loaded: true); m.attachments = [Attachment(name: "a.pdf", size: 3)]; m.html = "<img src=\"cid:x@y\">"
            s.merge([m], account: acct.id, mailbox: .inbox)
            let a = s.messages.first { $0.remoteID == "A" }!.id, b = s.messages.first { $0.remoteID == "B" }!.id
            let c = s.messages.first { $0.remoteID == "C" }!.id
            var notes: [String] = []
            func check(_ step: String) { notes.append("\(step): \(s.status ?? "NO STATUS")"); s.status = nil }
            await s.loadBody(a); check("loadBody")
            _ = await s.attachmentFile(0, of: c); check("attachment")
            await s.loadInlineImages(for: c); check("inline images")
            await s.loadDay(for: b); check("calendar")
            await s.refresh(history: false); check("refresh")
            await s.syncHistory(); check("history")
            s.send(Draft(accountID: acct.id, to: "bob@x.com", subject: "Report", body: "x")); try await waitFor { s.outbox.isEmpty }
            let kept = s.messages.contains { $0.mailbox == .drafts && $0.subject == "Report" }; check("send")
            s.respond(.accept, to: b); try await waitFor { s.outbox.isEmpty }
            let inviteBack = s.message(b)?.mailbox == .inbox; check("respond")
            // Not an Exchange answer, so not a refusal (BUG-061): the change stays queued.
            s.toggleRead([a]); try await waitFor { s.status != nil }
            let readKept = s.message(a)?.isRead == true && !s.outbox.isEmpty; check("mark read")
            try? FileManager.default.removeItem(at: url)
            #expect(!notes.contains { $0.hasSuffix("NO STATUS") } && readKept && kept && inviteBack && !s.isComplete(acct.id, .inbox),
                    "\(label): \(notes.joined(separator: " | ")); read kept \(readKept), send kept \(kept), invite back \(inviteBack)")
        }
    }
}
