import Foundation
import Testing
@testable import EWS
@testable import MailModel

// MARK: - file:// fixture (FIFO)

/// A named pipe at a `file://` URL stands in for the EWS endpoint: every request the real EWSClient makes opens the
/// pipe and reads the next hand-written response of the script, in order. No network, no fake class: the real
/// EWSClient, EWSBackend and MailStore run unchanged. After the script, `fallback` is served (by default a SOAP
/// fault, so a request the script didn't expect fails instead of hanging).
final class ScriptedServer: @unchecked Sendable {
    let url: URL
    private let path: String
    private let lock = NSLock()
    private var script: [String]
    private var fallbackXML: String
    private var stopped = false
    private var _served = 0

    var served: Int { lock.withLock { _served } }

    init(_ script: [String], fallback: String? = nil) {
        path = FileManager.default.temporaryDirectory.appendingPathComponent("ews-fifo-\(UUID().uuidString).xml").path
        mkfifo(path, 0o600)
        url = URL(fileURLWithPath: path)
        self.script = script
        fallbackXML = fallback ?? EWSReply.fault("ErrorScriptExhausted", "No scripted response left")
        let t = Thread { [self] in loop() }
        t.start()
    }

    func push(_ xml: String) { lock.withLock { script.append(xml) } }
    func stop() { lock.withLock { stopped = true } }

    private func loop() {
        signal(SIGPIPE, SIG_IGN)
        while true {
            if lock.withLock({ stopped }) { return }
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
            // URLSession's file loader keeps reading the pipe for a while after the end of the response. Serving
            // the next response before it lets go would hand it to this request, so wait until no reader is left.
            usleep(300_000)
        }
    }
}

/// Hand-written Exchange responses.
enum EWSReply {
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
        """
        <?xml version="1.0" encoding="utf-8"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>\
        <s:Fault><faultcode xmlns:a="http://schemas.microsoft.com/exchange/services/2006/types">a:\(code)</faultcode>\
        <faultstring xml:lang="en-US">\(text)</faultstring><detail>\
        <e:ResponseCode xmlns:e="http://schemas.microsoft.com/exchange/services/2006/errors">\(code)</e:ResponseCode>\
        <e:Message xmlns:e="http://schemas.microsoft.com/exchange/services/2006/errors">\(text)</e:Message></detail></s:Fault></s:Body></s:Envelope>
        """
    }
    static let busy = fault("ErrorServerBusy", "The server cannot service this request right now. Try again later.")

    /// One SyncFolderItems page.
    static func sync(_ changes: String, token: String, last: Bool = true) -> String {
        resp("SyncFolderItems", ok("SyncFolderItems", "<m:SyncState>\(token)</m:SyncState>"
            + "<m:IncludesLastItemInRange>\(last)</m:IncludesLastItemInRange><m:Changes>\(changes)</m:Changes>"))
    }
    /// A list summary as SyncFolderItems / FindItem return it.
    static func summary(_ id: String, subject: String = "Hello", read: Bool = false) -> String {
        "<t:Message><t:ItemId Id=\"\(id)\" ChangeKey=\"CK\"/><t:Subject>\(subject)</t:Subject>"
            + "<t:DateTimeReceived>2026-11-10T09:30:00Z</t:DateTimeReceived><t:HasAttachments>false</t:HasAttachments>"
            + "<t:Preview>Preview</t:Preview><t:DisplayTo>Me</t:DisplayTo><t:DisplayCc/>"
            + "<t:ConversationId Id=\"CONV-\(id)\"/><t:IsRead>\(read)</t:IsRead>"
            + "<t:From><t:Mailbox><t:Name>Ann</t:Name></t:Mailbox></t:From></t:Message>"
    }
    static func create(_ item: String) -> String { "<t:Create>\(item)</t:Create>" }
    static func delete(_ id: String) -> String { "<t:Delete><t:ItemId Id=\"\(id)\" ChangeKey=\"CK\"/></t:Delete>" }

    static func created(_ id: String) -> String {
        resp("CreateItem", ok("CreateItem", "<m:Items><t:Message><t:ItemId Id=\"\(id)\" ChangeKey=\"CK1\"/></t:Message></m:Items>"))
    }
    static func attachmentsCreated(root: String) -> String {
        resp("CreateAttachment", ok("CreateAttachment", "<m:Attachments><t:FileAttachment><t:AttachmentId Id=\"AT0\" "
            + "RootItemId=\"\(root)\" RootItemChangeKey=\"CK2\"/></t:FileAttachment></m:Attachments>"))
    }
    static func deleted(_ n: Int = 1) -> String { resp("DeleteItem", String(repeating: ok("DeleteItem"), count: n)) }
}

// MARK: - Flows

/// Whole flows (store, outbox, backend, client) against a scripted server.
@MainActor
@Suite(.serialized)
struct EWSFlowTests {
    let acct = Account(name: "Exchange", address: "me@work.com")

    /// A store with one Exchange account whose server is `server`; the folder list is already known.
    func store(_ server: ScriptedServer) -> MailStore {
        let s = MailStore(accounts: [], messages: [])
        s.add(acct, backend: EWSBackend(client: EWSClient(url: server.url, username: "u", password: "p")))
        s.setRemoteFolders([RemoteFolder(role: .inbox, id: "INBOX"), RemoteFolder(role: .drafts, id: "DRAFTS"),
                            RemoteFolder(role: .sent, id: "SENT"), RemoteFolder(role: .trash, id: "DEL")], account: acct.id)
        return s
    }

    /// Marks a folder fully synced, so the quick check asks it for changes.
    func complete(_ s: MailStore, _ box: MailboxKind, token: String = "T0") {
        s.apply(SyncResult(upserts: [], deletedRemoteIDs: [], token: token, more: false), account: acct.id, mailbox: box)
    }

    func waitFor(_ timeout: Duration = .seconds(5), _ cond: () -> Bool) async throws {
        let end = ContinuousClock.now + timeout
        while !cond() && ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(10)) }
        #expect(cond(), "timed out")
    }

    func erasing(_ s: MailStore, _ rid: String) -> Bool {
        s.outbox.contains { if case let .delete(ids) = $0.change { ids == [rid] } else { false } }
    }

    /// A Drafts page that still lists the half message, as the server does until it is erased.
    func draftsPageWith(_ rid: String) -> SyncResult {
        let m = Message(accountID: acct.id, mailbox: .drafts, from: Contact(name: "Me", email: "me@work.com"), to: [],
                        subject: "Contract", body: "", date: .now, remoteID: rid, bodyLoaded: false)
        return SyncResult(upserts: [m], deletedRemoteIDs: [], token: "T1", more: false)
    }

    func file() -> DraftAttachment {
        DraftAttachment(name: "contract.pdf", contentType: "application/pdf", data: Data(repeating: 1, count: 500))
    }

    /// Sending with files: the message is created in Exchange's Drafts, then adding the files fails and so does the
    /// clean-up. The half message is erased later and never shows next to the copy kept on this Mac.
    @Test func failedSendWithFilesLeavesNoHalfDraft() async throws {
        let server = ScriptedServer([EWSReply.created("D1"), EWSReply.busy, EWSReply.busy])
        defer { server.stop() }
        let s = store(server)
        complete(s, .inbox); complete(s, .drafts)
        var d = Draft(accountID: acct.id, to: "bob@x.com", subject: "Contract", body: "Signed copy attached")
        d.attachments = [file()]
        s.send(d)
        try await waitFor { erasing(s, "D1") && server.served == 3 }
        #expect(s.status?.hasPrefix("Couldn't send “Contract”") == true, "\(String(describing: s.status))")
        s.apply(draftsPageWith("D1"), account: acct.id, mailbox: .drafts)
        #expect(!s.messages.contains { $0.remoteID == "D1" })

        // The next drain erases it; the Drafts page then reports it gone.
        server.push(EWSReply.deleted())
        server.push(EWSReply.sync("", token: "T1"))
        server.push(EWSReply.sync(EWSReply.delete("D1"), token: "T2"))
        s.selectedMailbox = .account(acct.id, .drafts)
        await s.refresh(history: false)
        let drafts = s.messages.filter { $0.mailbox == .drafts }
        #expect(drafts.map(\.remoteID) == [nil])
        #expect(drafts.first?.attachments.count == 1)
        #expect(s.outbox.isEmpty)
    }

    /// The same for Save Draft with files: it stays queued (the server was busy), and the half message is erased.
    @Test func failedSaveDraftWithFilesLeavesNoHalfDraft() async throws {
        let server = ScriptedServer([EWSReply.created("D1"), EWSReply.busy, EWSReply.busy])
        defer { server.stop() }
        let s = store(server)
        complete(s, .inbox); complete(s, .drafts)
        var d = Draft(accountID: acct.id, to: "bob@x.com", subject: "Contract", body: "Draft")
        d.attachments = [file()]
        s.saveDraft(d)
        try await waitFor { erasing(s, "D1") && server.served == 3 }
        s.apply(draftsPageWith("D1"), account: acct.id, mailbox: .drafts)
        #expect(!s.messages.contains { $0.remoteID == "D1" })

        server.push(EWSReply.created("D2"))
        server.push(EWSReply.attachmentsCreated(root: "D2"))
        server.push(EWSReply.deleted())
        server.push(EWSReply.sync("", token: "T1"))
        server.push(EWSReply.sync(EWSReply.create(EWSReply.summary("D2", subject: "Contract", read: true)) + EWSReply.delete("D1"), token: "T2"))
        s.selectedMailbox = .account(acct.id, .drafts)
        await s.refresh(history: false)
        #expect(s.messages.filter { $0.mailbox == .drafts }.map(\.remoteID) == ["D2"])
        #expect(s.outbox.isEmpty)
    }
}
