import Foundation
import Testing
@testable import EWS
@testable import MailModel

// MARK: - Scripted server (loopback)

/// A scripted server stands in for the EWS endpoint: every request the real EWSClient makes gets the next hand-written
/// response of the script, in order. No fake class: the real EWSClient, EWSBackend and MailStore run unchanged, over
/// HTTP to this process on 127.0.0.1 (nothing leaves the machine). After the script, `fallback` is served (by default
/// a SOAP fault, so a request the script didn't expect fails instead of hanging).
final class ScriptedServer: @unchecked Sendable {
    let url: URL
    private let endpoint: LoopbackEndpoint
    private let lock = NSLock()
    private var script: [String]
    private var fallbackXML: String

    var served: Int { endpoint.served }

    init(_ script: [String], fallback: String? = nil) {
        self.script = script
        fallbackXML = fallback ?? EWSReply.fault("ErrorScriptExhausted", "No scripted response left")
        endpoint = LoopbackEndpoint()
        url = endpoint.url
        endpoint.start { [self] in lock.withLock { self.script.isEmpty ? fallbackXML : self.script.removeFirst() } }
    }

    func push(_ xml: String) { lock.withLock { script.append(xml) } }
    func stop() { endpoint.stop() }
}

/// An HTTP endpoint on 127.0.0.1 that answers each request with the next answer, in the order the requests arrived.
/// `next` returns nil while there is no answer yet (a held server): the request then waits, as one waits for a slow
/// server, until there is one. A request given up meanwhile (its task cancelled) doesn't use an answer.
///
/// (It replaces named pipes at `file://` URLs. URLSession's file loader kept a pipe open after the end of an answer,
/// so a next answer could end up in the previous request, and it sometimes missed the end of a pipe and waited for its
/// 60 s time-out. Each request here has its own connection, and each answer its length.)
final class LoopbackEndpoint: @unchecked Sendable {
    private(set) var url: URL = URL(string: "http://127.0.0.1/")!
    private let listener: Int32
    private let lock = NSLock()
    private var stopped = false
    private var _served = 0
    var served: Int { lock.withLock { _served } }

    init() {
        signal(SIGPIPE, SIG_IGN)
        listener = socket(AF_INET, SOCK_STREAM, 0)
        var yes: Int32 = 1
        setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0  // any free port
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                _ = bind(listener, sa, len)
                _ = listen(listener, 16)
                _ = getsockname(listener, sa, &len)
            }
        }
        url = URL(string: "http://127.0.0.1:\(UInt16(bigEndian: addr.sin_port))/EWS/Exchange.asmx")!
    }

    func start(_ next: @escaping () -> String?) {
        let t = Thread { [self] in loop(next) }
        t.start()
    }

    func stop() { lock.withLock { stopped = true } }

    private func loop(_ next: () -> String?) {
        var reading: [Int32: [UInt8]] = [:]  // connections whose request isn't complete yet
        var waiting: [Int32] = []  // connections whose request is read, oldest first
        while !lock.withLock({ stopped }) {
            var fds = [pollfd(fd: listener, events: Int16(POLLIN), revents: 0)]
                + reading.keys.map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
            if poll(&fds, nfds_t(fds.count), waiting.isEmpty ? 10 : 1) > 0 {
                if fds[0].revents != 0 {
                    let c = accept(listener, nil, nil)
                    if c >= 0 { _ = fcntl(c, F_SETFL, O_NONBLOCK); reading[c] = [] }
                }
                for f in fds.dropFirst() where f.revents != 0 {
                    var buf = [UInt8](repeating: 0, count: 65536)
                    let n = read(f.fd, &buf, buf.count)
                    if n <= 0 { reading[f.fd] = nil; close(f.fd); continue }
                    reading[f.fd]! += buf[0..<n]
                    if Self.isComplete(reading[f.fd]!) { reading[f.fd] = nil; waiting.append(f.fd) }
                }
            }
            while let c = waiting.first {
                guard isOpen(c) else { close(c); waiting.removeFirst(); continue }
                guard let xml = next() else { break }
                waiting.removeFirst()
                respond(c, xml)
                lock.withLock { _served += 1 }
            }
        }
        (Array(reading.keys) + waiting).forEach { close($0) }
        close(listener)
    }

    /// Whether `data` holds a whole request: its head and a body as long as its Content-Length says.
    private static func isComplete(_ data: [UInt8]) -> Bool {
        guard let end = data.indices.dropLast(3).first(where: {
            data[$0] == 13 && data[$0 + 1] == 10 && data[$0 + 2] == 13 && data[$0 + 3] == 10
        }) else { return false }
        let head = String(decoding: data[..<end], as: UTF8.self).lowercased()
        let line = head.split(separator: "\r\n").first { $0.hasPrefix("content-length:") }
        let length = line.flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
        return data.count - (end + 4) >= length
    }

    /// Whether the client still waits on this connection (a cancelled request closes it).
    private func isOpen(_ c: Int32) -> Bool {
        var p = pollfd(fd: c, events: Int16(POLLIN), revents: 0)
        guard poll(&p, 1, 0) > 0 else { return true }
        var byte: UInt8 = 0
        return recv(c, &byte, 1, MSG_PEEK | MSG_DONTWAIT) > 0
    }

    private func respond(_ c: Int32, _ xml: String) {
        _ = fcntl(c, F_SETFL, 0)  // blocking: the whole answer is written
        let body = Array(xml.utf8)
        let head = "HTTP/1.1 200 OK\r\nContent-Type: text/xml; charset=utf-8\r\nContent-Length: \(body.count)\r\n"
            + "Connection: close\r\n\r\n"
        let bytes = Array(head.utf8) + body
        var off = 0
        while off < bytes.count {
            let n = bytes[off...].withUnsafeBytes { write(c, $0.baseAddress, $0.count) }
            if n <= 0 { break }
            off += n
        }
        shutdown(c, SHUT_WR)
        close(c)
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
    static func err(_ op: String, _ code: String, _ text: String) -> String {
        "<m:\(op)ResponseMessage ResponseClass=\"Error\"><m:MessageText>\(text)</m:MessageText>"
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
    static func findFolder(_ folders: String = "") -> String {
        resp("FindFolder", ok("FindFolder", "<m:RootFolder IndexedPagingOffset=\"0\" TotalItemsInView=\"0\" "
            + "IncludesLastItemInRange=\"true\"><t:Folders>\(folders)</t:Folders></m:RootFolder>"))
    }
    static func deleted(_ n: Int = 1) -> String { resp("DeleteItem", String(repeating: ok("DeleteItem"), count: n)) }
}

// MARK: - Flows

/// Set when a task started by a test has finished.
@MainActor final class Done { var yes = false }

/// Whole flows (store, outbox, backend, client) against a scripted server.
@MainActor
@Suite(.serialized)
struct EWSFlowTests {
    let acct = Account(name: "Exchange", address: "me@work.com")

    /// A store with one Exchange account whose server is `server`; the folder list is already known unless
    /// `folders` is false.
    func store(_ server: ScriptedServer, folders: Bool = true) -> MailStore {
        let s = MailStore(accounts: [], messages: [])
        s.add(acct, backend: EWSBackend(client: EWSClient(url: server.url, username: "u", password: "p")))
        guard folders else { return s }
        s.setRemoteFolders([RemoteFolder(role: .inbox, id: "INBOX"), RemoteFolder(role: .drafts, id: "DRAFTS"),
                            RemoteFolder(role: .sent, id: "SENT"), RemoteFolder(role: .trash, id: "DEL")], account: acct.id)
        return s
    }

    /// Marks a folder fully synced, so the quick check asks it for changes.
    func complete(_ s: MailStore, _ box: MailboxKind, token: String = "T0") {
        s.apply(SyncResult(upserts: [], deletedRemoteIDs: [], token: token, more: false), account: acct.id, mailbox: box)
    }

    /// Waits up to `timeout` for `cond`. A step that took longer than 100 ms (another suite held the main actor for
    /// seconds, or the machine is busy) counts as 100 ms, so that doesn't use up the wait.
    func waitFor(_ timeout: Duration = .seconds(5), _ cond: () -> Bool) async throws {
        var left = timeout
        while !cond() && left > .zero {
            let start = ContinuousClock.now
            try await Task.sleep(for: .milliseconds(10))
            left -= min(start.duration(to: .now), .milliseconds(100))
        }
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

    /// GetFolder answers each standard folder with an error (mailbox store unavailable, e.g. during a mailbox move):
    /// the check says so, and the folder list is asked again at the next check.
    @Test func folderListWithoutInboxIsReportedAndRetried() async throws {
        let e = EWSReply.err("GetFolder", "ErrorMailboxStoreUnavailable", "The mailbox database is temporarily unavailable.")
        let server = ScriptedServer([EWSReply.resp("GetFolder", String(repeating: e, count: 6)), EWSReply.findFolder()],
                                    fallback: EWSReply.sync("", token: "T1"))
        defer { server.stop() }
        let s = store(server, folders: false)
        await s.refresh(history: false)
        let afterFirst = server.served
        #expect(s.status?.contains("The mailbox database is temporarily unavailable.") == true, "\(String(describing: s.status))")
        await s.refresh(history: false)
        #expect(server.served > afterFirst)
    }

    /// A server that keeps answering "more" with the same SyncState (a fault, not Exchange's way): the quick check
    /// stops at the repeated page and says so, instead of asking for it forever (BUG-126).
    // file:// fixture (a plain file: every request reads the same answer)
    @Test func quickCheckPagingEndsWhenTheServerRepeatsAPage() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ews-\(UUID().uuidString).xml")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(EWSReply.sync("", token: "T1", last: false).utf8).write(to: url)
        let s = MailStore(accounts: [], messages: [])
        s.add(acct, backend: EWSBackend(client: EWSClient(url: url, username: "u", password: "p")))
        s.setRemoteFolders([RemoteFolder(role: .inbox, id: "INBOX")], account: acct.id)
        complete(s, .inbox, token: "T1")
        let done = Done()
        let task = Task { await s.refresh(history: false); done.yes = true }
        try await waitFor(.seconds(10)) { done.yes }
        let stillRunning = !done.yes
        try Data(EWSReply.sync("", token: "T1", last: true).utf8).write(to: url)
        await task.value
        #expect(!stillRunning, "the check is still running (same page asked again and again)")
        #expect(s.status?.contains("same page") == true, "\(String(describing: s.status))")
    }

    /// The same for the history: the folder stops after the repeated page and the progress bar goes away.
    // file:// fixture (a plain file)
    @Test func historyPagingEndsWhenTheServerRepeatsAPage() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ews-\(UUID().uuidString).xml")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(EWSReply.sync("", token: "T1", last: false).utf8).write(to: url)
        let s = MailStore(accounts: [], messages: [])
        s.add(acct, backend: EWSBackend(client: EWSClient(url: url, username: "u", password: "p")))
        s.setRemoteFolders([RemoteFolder(role: .inbox, id: "INBOX", totalCount: 1)], account: acct.id)
        let done = Done()
        let task = Task { await s.syncHistory(); done.yes = true }
        try await waitFor(.seconds(10)) { done.yes }
        let progress = s.progress
        try Data(EWSReply.sync("", token: "T1", last: true).utf8).write(to: url)
        await task.value
        #expect(progress == nil, "history still running, progress \(String(describing: progress))")
    }

    /// A meeting cancellation in `box`, from `from`.
    func cancellation(_ s: MailStore, _ rid: String, in box: MailboxKind, from: String) -> Message.ID {
        var m = Message(accountID: acct.id, mailbox: box, from: Contact(name: from, email: from), to: [],
                        subject: "Canceled: Janos & Till", body: "", date: .now, remoteID: rid, bodyLoaded: false)
        m.invite = Invite(start: .now, end: .now.addingTimeInterval(1800), isCancellation: true)
        s.apply(SyncResult(upserts: [m], deletedRemoteIDs: [], token: "T1", more: false), account: acct.id, mailbox: box)
        return s.messages.first { $0.remoteID == rid }!.id
    }

    /// Your own cancellation in Sent offers no Remove from Calendar (only a received one does, as in Outlook), and
    /// removing it anyway changes nothing and asks the server nothing.
    @Test func ownSentCancellationCantBeRemovedFromTheCalendar() async throws {
        let server = ScriptedServer([])
        defer { server.stop() }
        let s = store(server)
        let sent = cancellation(s, "S1", in: .sent, from: "me@work.com")
        let received = cancellation(s, "R1", in: .inbox, from: "janos@work.com")
        let mine = cancellation(s, "R2", in: .inbox, from: "Me@Work.com")
        #expect(!s.canAnswer(sent))
        #expect(s.canAnswer(received))
        #expect(!s.canAnswer(mine))
        s.removeFromCalendar(sent)
        s.respond(.accept, to: sent)
        try await Task.sleep(for: .milliseconds(200))
        #expect(s.message(sent)?.mailbox == .sent)
        #expect(s.outbox.isEmpty)
        #expect(server.served == 0)
    }

    /// Exchange refuses Remove from Calendar (the organizer can't remove their own meeting): the cancellation comes
    /// back and the status line says why.
    @Test func refusedRemoveFromCalendarComesBackWithTheReason() async throws {
        let server = ScriptedServer([EWSReply.resp("CreateItem", EWSReply.err("CreateItem", "ErrorCalendarIsOrganizerForRemove",
                                                                              "The organizer can't remove the meeting."))])
        defer { server.stop() }
        let s = store(server)
        let id = cancellation(s, "R1", in: .inbox, from: "janos@work.com")
        s.removeFromCalendar(id)
        #expect(s.message(id)?.mailbox == .trash)
        try await waitFor { s.message(id)?.mailbox == .inbox }
        #expect(s.status?.contains("The organizer can't remove the meeting.") == true, "\(String(describing: s.status))")
        #expect(s.outbox.isEmpty)
    }

    /// The meeting is off the calendar, but Exchange refuses to move the cancellation to Deleted Items: the status
    /// line says so, instead of the message quietly coming back at the next check.
    @Test func refusedTrashMoveAfterRemoveFromCalendarIsReported() async throws {
        let server = ScriptedServer([EWSReply.created("X1"),
                                     EWSReply.resp("MoveItem", EWSReply.err("MoveItem", "ErrorAccessDenied", "Access is denied."))])
        defer { server.stop() }
        let s = store(server)
        let id = cancellation(s, "R1", in: .inbox, from: "janos@work.com")
        s.removeFromCalendar(id)
        try await waitFor { server.served == 2 && s.outbox.isEmpty }
        #expect(s.status?.contains("Access is denied.") == true, "\(String(describing: s.status))")
    }

    /// Two Exchange accounts are named after their addresses, so their Inboxes can be told apart.
    @Test func twoExchangeAccountsCanBeToldApart() {
        let one = ExchangeAccount(email: "till@work.com", username: "W\\till", server: "mail.work.com")
        let two = ExchangeAccount(email: "till@club.org", username: "C\\till", server: "mail.club.org")
        let s = MailStore(accounts: [one.account, two.account], messages: [])
        s.selectedMailbox = .account(one.id, .inbox)
        let t1 = s.title
        s.selectedMailbox = .account(two.id, .inbox)
        #expect(t1 != s.title, "both Inboxes are titled \(t1)")
        #expect(one.account.name == "till@work.com")
        #expect(ExchangeAccount(email: " ", username: "u", server: "s").account.name == "Exchange")
    }

    /// BUG-177: moving Cache.json into the database sends nothing until the database has its real name and the cache
    /// is renamed. Before, a waiting send went out during "Updating Mail Storage…": quit then, and the next launch
    /// imported the cache again and sent the message a second time.
    @Test func importSendsNothingWhileTheCacheCanStillBeImportedAgain() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ImportSend-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let cacheURL = dir.appendingPathComponent("Cache.json"), dbURL = dir.appendingPathComponent("Mail.sqlite")
        // A cache from the old build: a big mailbox and a send still waiting.
        let msgs = (0..<30_000).map { n in
            Message(accountID: acct.id, from: Contact(name: "Ann", email: "ann@x.com"), to: [Contact(name: "Me", email: "me@work.com")],
                    subject: "Message \(n)", body: String(repeating: "text ", count: 40), date: Date(timeIntervalSinceReferenceDate: Double(n)),
                    remoteID: "R\(n)")
        }
        let send = PendingChange(account: acct.id, change: .send(Draft(accountID: acct.id, to: "bob@x.com", subject: "Offer", body: "Hi")),
                                 previous: [])
        try MailCache(accounts: [acct.id: .init(messages: msgs, syncTokens: [.inbox: "T"], outbox: [send], complete: [.inbox], folders: [])])
            .save(to: cacheURL)

        // The server notes, when the send arrives, whether a quit right then would import (and send) again.
        let endpoint = LoopbackEndpoint()
        defer { endpoint.stop() }
        let seen = SeenAtSend()
        endpoint.start {
            seen.note(cacheStillThere: FileManager.default.fileExists(atPath: cacheURL.path))
            return EWSReply.resp("CreateItem", EWSReply.ok("CreateItem"))
        }
        let s = MailStore(accounts: [], messages: [])
        s.add(acct, backend: EWSBackend(client: EWSClient(url: endpoint.url, username: "u", password: "p")))
        s.setRemoteFolders([RemoteFolder(role: .inbox, id: "INBOX"), RemoteFolder(role: .sent, id: "SENT")], account: acct.id)

        _ = try await MailDatabase.importCache(from: cacheURL, into: dbURL, store: s)
        for _ in 0..<300 where seen.value == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(seen.value != nil, "the send never went out")
        #expect(seen.value == false, "the send went out while Cache.json (holding it) was still there to import again")
    }


    /// BUG-170: Exchange rejects the password (HTTP 401) when the compose window asks for the size limit (MailTips). The
    /// account must be paused like for any other request (README: "the app stops sending requests for that account
    /// until you relaunch"); the error was swallowed and the next check sent the rejected password again.
    @Test func rejectedPasswordOnMailTipsPausesTheAccount() async throws {
        let server = StatusServer([(401, "")])
        defer { server.stop() }
        let s = MailStore(accounts: [], messages: [])
        s.add(acct, backend: EWSBackend(client: EWSClient(url: server.url, username: "u", password: "wrong")))
        await s.loadMaxMessageSize(for: acct.id)
        #expect(server.served == 1)
        #expect(s.isPaused(acct.id), "status: \(s.status ?? "")")
    }

    /// The same after "Do Not Send a Response": the answer went out, then the move of the invite to Deleted Items gets
    /// a 401. The move is queued, but the account isn't paused, so the drain at once sends it again with the
    /// rejected password.
    @Test func rejectedPasswordOnTheMoveAfterAnAnswerPausesTheAccount() async throws {
        let server = StatusServer([(200, EWSReply.created("X1")), (401, ""), (401, "")])
        defer { server.stop() }
        let s = MailStore(accounts: [], messages: [])
        s.add(acct, backend: EWSBackend(client: EWSClient(url: server.url, username: "u", password: "p")))
        s.setRemoteFolders([RemoteFolder(role: .inbox, id: "INBOX"), RemoteFolder(role: .trash, id: "DEL")], account: acct.id)
        var m = Message(accountID: acct.id, mailbox: .inbox, from: Contact(name: "Jan", email: "jan@work.com"), to: [],
                        subject: "Planning", body: "", date: .now, remoteID: "R1", bodyLoaded: true)
        m.invite = Invite(start: .now, end: .now.addingTimeInterval(1800))
        s.merge([m], account: acct.id, mailbox: .inbox)
        s.respond(InviteReply(response: .accept, send: false), to: s.messages.first { $0.remoteID == "R1" }!.id)
        try await waitFor { server.served >= 2 }
        try await Task.sleep(for: .milliseconds(400))
        #expect(server.served == 2, "\(server.served) requests; the rejected password was sent again")
        #expect(s.isPaused(acct.id))
    }

}

/// What the server saw when the send arrived (BUG-177).
final class SeenAtSend: @unchecked Sendable {
    private let lock = NSLock()
    private var first: Bool?
    var value: Bool? { lock.withLock { first } }
    func note(cacheStillThere: Bool) { lock.withLock { if first == nil { first = cacheStillThere } } }
}

/// A loopback HTTP endpoint that answers each request with the next (status, body) of its script, so a test can
/// get an HTTP 401 (ScriptedServer always answers 200). Same approach as `LoopbackEndpoint`: 127.0.0.1 only.
final class StatusServer: @unchecked Sendable {
    let url: URL
    private let listener: Int32
    private let lock = NSLock()
    private var script: [(Int, String)]
    private var _served = 0
    var served: Int { lock.withLock { _served } }

    init(_ script: [(Int, String)]) {
        self.script = script
        signal(SIGPIPE, SIG_IGN)
        let l = socket(AF_INET, SOCK_STREAM, 0)
        var yes: Int32 = 1
        setsockopt(l, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                _ = bind(l, sa, len); _ = listen(l, 16); _ = getsockname(l, sa, &len)
            }
        }
        listener = l
        url = URL(string: "http://127.0.0.1:\(UInt16(bigEndian: addr.sin_port))/EWS/Exchange.asmx")!
        let t = Thread { [self] in loop() }
        t.start()
    }

    func stop() { close(listener) }

    private func loop() {
        while true {
            let c = accept(listener, nil, nil)
            if c < 0 { return }
            var data: [UInt8] = []
            var buf = [UInt8](repeating: 0, count: 65536)
            while !Self.isComplete(data) {
                let n = read(c, &buf, buf.count)
                if n <= 0 { break }
                data += buf[0..<n]
            }
            let (status, body) = lock.withLock { () -> (Int, String) in
                _served += 1
                return script.isEmpty ? (500, EWSReply.fault("ErrorScriptExhausted", "No scripted response left")) : script.removeFirst()
            }
            let bytes = Array(body.utf8)
            let head = "HTTP/1.1 \(status) \(status == 200 ? "OK" : status == 401 ? "Unauthorized" : "Error")\r\n"
                + "Content-Type: text/xml; charset=utf-8\r\nContent-Length: \(bytes.count)\r\nConnection: close\r\n\r\n"
            let all = Array(head.utf8) + bytes
            var off = 0
            while off < all.count {
                let n = all[off...].withUnsafeBytes { write(c, $0.baseAddress, $0.count) }
                if n <= 0 { break }
                off += n
            }
            shutdown(c, SHUT_WR); close(c)
        }
    }

    private static func isComplete(_ data: [UInt8]) -> Bool {
        guard let end = data.indices.dropLast(3).first(where: {
            data[$0] == 13 && data[$0 + 1] == 10 && data[$0 + 2] == 13 && data[$0 + 3] == 10
        }) else { return false }
        let head = String(decoding: data[..<end], as: UTF8.self).lowercased()
        let line = head.split(separator: "\r\n").first { $0.hasPrefix("content-length:") }
        let length = line.flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
        return data.count - (end + 4) >= length
    }
}
