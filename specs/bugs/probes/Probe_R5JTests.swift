import Foundation
import Testing
@testable import EWS
@testable import MailModel

/// Bug hunt round 5, hunter J: the SOAP requests the real EWSClient sends, checked against the EWS contract
/// (Microsoft's EWS reference and the Exchange 2013 SP1 schema). Every test here fails now and passes once fixed.

/// A loopback HTTP endpoint on 127.0.0.1 that keeps every request body it receives and answers each one with
/// `answer(body)`. The real EWSClient talks HTTP to it; nothing leaves the machine.
final class RecordingServer: @unchecked Sendable {
    let url: URL
    private let listener: Int32
    private let lock = NSLock()
    private var _requests: [String] = []
    private let answer: @Sendable (String) -> String
    var requests: [String] { lock.withLock { _requests } }

    init(_ answer: @escaping @Sendable (String) -> String) {
        self.answer = answer
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
            var bodyStart: Int?
            while true {
                if let (start, complete) = Self.parse(data), complete { bodyStart = start; break }
                let n = read(c, &buf, buf.count)
                if n <= 0 { break }
                data += buf[0..<n]
            }
            let body = bodyStart.map { String(decoding: data[$0...], as: UTF8.self) } ?? ""
            lock.withLock { _requests.append(body) }
            let bytes = Array(answer(body).utf8)
            let head = "HTTP/1.1 200 OK\r\nContent-Type: text/xml; charset=utf-8\r\nContent-Length: \(bytes.count)\r\n"
                + "Connection: close\r\n\r\n"
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

    /// Where the body starts, and whether it is all in.
    private static func parse(_ data: [UInt8]) -> (Int, Bool)? {
        guard let end = data.indices.dropLast(3).first(where: {
            data[$0] == 13 && data[$0 + 1] == 10 && data[$0 + 2] == 13 && data[$0 + 3] == 10
        }) else { return nil }
        let head = String(decoding: data[..<end], as: UTF8.self).lowercased()
        let line = head.split(separator: "\r\n").first { $0.hasPrefix("content-length:") }
        let length = line.flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
        return (end + 4, data.count - (end + 4) >= length)
    }
}

enum R5J {
    /// A plausible success answer for whichever operation `request` holds.
    static func answer(_ request: String) -> String {
        let ops = ["GetFolder", "FindFolder", "FindItem", "SyncFolderItems", "GetItem", "GetAttachment", "UpdateItem",
                   "MoveItem", "DeleteItem", "CreateItem", "CreateAttachment", "SendItem", "GetMailTips"]
        guard let op = ops.first(where: { request.contains("<m:\($0) ") || request.contains("<m:\($0)>") }) else {
            return EWSReply.fault("ErrorInvalidRequest", "unknown")
        }
        let n = max(1, request.components(separatedBy: "<t:ItemId ").count - 1)
        switch op {
        case "GetFolder":
            return EWSReply.resp("GetFolder", ["INBOX", "DRAFTS", "SENT", "JUNK", "DEL", "OUTBOX"].map {
                EWSReply.ok("GetFolder", "<m:Folders><t:Folder><t:FolderId Id=\"\($0)\" ChangeKey=\"CK\"/><t:TotalCount>0</t:TotalCount></t:Folder></m:Folders>")
            }.joined())
        case "FindFolder":
            return EWSReply.findFolder()
        case "FindItem":
            return EWSReply.resp("FindItem", EWSReply.ok("FindItem", "<m:RootFolder TotalItemsInView=\"0\" IncludesLastItemInRange=\"true\"><t:Items/></m:RootFolder>"))
        case "SyncFolderItems":
            return EWSReply.sync("", token: "T1")
        case "GetItem":
            return EWSReply.resp("GetItem", EWSReply.ok("GetItem", "<m:Items><t:Message><t:ItemId Id=\"R1\" ChangeKey=\"CK\"/>"
                + "<t:Attachments><t:FileAttachment><t:AttachmentId Id=\"AT1\"/><t:Name>a.png</t:Name><t:ContentType>image/png</t:ContentType>"
                + "<t:ContentId>pic</t:ContentId></t:FileAttachment></t:Attachments></t:Message></m:Items>"))
        case "GetAttachment":
            return EWSReply.resp("GetAttachment", EWSReply.ok("GetAttachment", "<m:Attachments><t:FileAttachment><t:AttachmentId Id=\"AT1\"/>"
                + "<t:Name>a.png</t:Name><t:ContentType>image/png</t:ContentType><t:ContentId>pic</t:ContentId><t:Content>AAAA</t:Content></t:FileAttachment></m:Attachments>"))
        case "UpdateItem", "MoveItem", "DeleteItem":
            return EWSReply.resp(op, String(repeating: EWSReply.ok(op, op == "MoveItem" ? "<m:Items><t:Message><t:ItemId Id=\"NEW\" ChangeKey=\"CK\"/></t:Message></m:Items>" : ""), count: n))
        case "CreateItem":
            return EWSReply.created("D1")
        case "CreateAttachment":
            return EWSReply.attachmentsCreated(root: "D1")
        case "SendItem":
            return EWSReply.resp("SendItem", EWSReply.ok("SendItem"))
        default:
            return EWSReply.resp("GetMailTips", "")
        }
    }

    static func backend(_ server: RecordingServer) -> EWSBackend {
        EWSBackend(client: EWSClient(url: server.url, username: "u", password: "p"))
    }
}

@Suite(.serialized)
struct Probe_R5JDump {
    /// Not a bug: writes every request body to tmp/requests, for checking against the schema with xmllint.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["R5J_DUMP"] != nil)) func dumpRequests() async throws {
        let server = RecordingServer { R5J.answer($0) }
        defer { server.stop() }
        let b = R5J.backend(server)
        let inbox = RemoteFolder(role: .inbox, id: "INBOX")
        _ = try? await b.folders()
        _ = try? await b.newest(in: inbox, limit: 50)
        _ = try? await b.sync(inbox, token: nil)
        _ = try? await b.sync(inbox, token: "T0")
        _ = try? await b.body(remoteID: "R1")
        _ = try? await b.inlineImages(remoteID: "R1", contentIDs: ["pic"])
        _ = try? await b.attachment(remoteID: "R1", index: 0)
        _ = try? await b.events(from: Date(timeIntervalSince1970: 1_800_000_000), to: Date(timeIntervalSince1970: 1_800_086_400))
        _ = try? await b.maxMessageSize(from: "me@work.com")
        _ = try? await b.setRead(["R1", "R2"], true)
        _ = try? await b.setFlagged(["R1"], true)
        _ = try? await b.move(["R1"], to: RemoteFolder(role: .trash, id: "DEL"))
        _ = try? await b.delete(["R1"])
        let acct = UUID()
        _ = try? await b.send(Draft(accountID: acct, to: "Ann <ann@x.com>", cc: "bob@x.com", subject: "Hi", body: "Text"))
        _ = try? await b.saveDraft(Draft(accountID: acct, to: "ann@x.com", subject: "Hi", body: "Text"))
        var d = Draft(accountID: acct, to: "ann@x.com", subject: "Files", body: "See \u{FFFC}")
        d.attachments = [DraftAttachment(name: "a.png", contentType: "image/png", data: Data([1, 2, 3]))]
        _ = try? await b.send(d)
        _ = try? await b.respond("R1", InviteReply(response: .accept, comment: "ok"))
        _ = try? await b.respond("R1", InviteReply(response: .tentative, comment: "later?", proposedStart: Date(timeIntervalSince1970: 1_800_000_000),
                                                   proposedEnd: Date(timeIntervalSince1970: 1_800_003_600)))
        _ = try? await b.respond("R1", InviteReply(response: .decline, send: false))
        _ = try? await b.removeFromCalendar("R1")
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("tmp/requests")
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (i, r) in server.requests.enumerated() {
            try r.write(to: dir.appendingPathComponent(String(format: "%02d.xml", i)), atomically: true, encoding: .utf8)
        }
    }
}

@MainActor
@Suite(.serialized)
struct Probe_R5JTests {
    let acct = Account(name: "Exchange", address: "me@work.com")

    func request(_ body: String) throws -> XMLDocument { try XMLDocument(xmlString: body) }

    func waitFor(_ timeout: Duration = .seconds(5), _ cond: () -> Bool) async throws {
        var left = timeout
        while !cond() && left > .zero {
            let start = ContinuousClock.now
            try await Task.sleep(for: .milliseconds(10))
            left -= min(start.duration(to: .now), .milliseconds(100))
        }
    }

    // MARK: R5J-01

    /// Erasing a message (Delete in Trash) sends `DeleteItem` without `SuppressReadReceipts`. Per Microsoft's
    /// DeleteItem reference, read receipts are then sent to the sender: an unread message that asked for one tells
    /// the sender it was deleted unread, although the app never sends receipts.
    @Test func r5j01_eraseSuppressesReadReceipts() async throws {
        let server = RecordingServer { R5J.answer($0) }
        defer { server.stop() }
        try await R5J.backend(server).delete(["R1"])
        let sent = try #require(server.requests.first)
        let del = try #require(try request(sent).first("DeleteItem"))
        #expect(del.attr("SuppressReadReceipts") == "true", "DeleteItem attributes: \((del as? XMLElement)?.attributes?.map { "\($0.name ?? "")=\($0.stringValue ?? "")" } ?? [])")
    }

    // MARK: R5J-02

    /// A recipient written as `Name <>` (an empty address) goes into CreateItem as an empty `t:EmailAddress`, which the
    /// schema forbids (NonEmptyStringType). Exchange rejects the whole request, so the message doesn't reach the
    /// other, valid recipient either.
    @Test func r5j02_emptyAddressRecipientNotSentAsEmptyEmailAddress() async throws {
        let server = RecordingServer { R5J.answer($0) }
        defer { server.stop() }
        try await R5J.backend(server).send(Draft(accountID: acct.id, to: "Ann <ann@x.com>, Bob <>", subject: "Hi", body: "Text"))
        let sent = try #require(server.requests.first)
        let addresses = try request(sent).all("EmailAddress").map { $0.stringValue ?? "" }
        #expect(!addresses.contains(""), "EmailAddress values sent: \(addresses)")
    }

    // MARK: R5J-03 / R5J-04

    /// A Deleted Items sync page as Exchange sends it after an appointment and a task were deleted in Outlook: both
    /// land in Deleted Items, and the app lists them like mail.
    func trashWithAppointmentAndTask(_ server: RecordingServer) -> MailStore {
        let s = MailStore(accounts: [], messages: [])
        s.add(acct, backend: R5J.backend(server))
        s.setRemoteFolders([RemoteFolder(role: .inbox, id: "INBOX"), RemoteFolder(role: .trash, id: "DEL")], account: acct.id)
        let page = EWSReply.sync(EWSReply.create("<t:CalendarItem><t:ItemId Id=\"CAL1\" ChangeKey=\"CK\"/><t:Subject>Dentist</t:Subject>"
            + "<t:DateTimeReceived>2026-11-10T09:30:00Z</t:DateTimeReceived><t:HasAttachments>false</t:HasAttachments></t:CalendarItem>")
            + EWSReply.create("<t:Task><t:ItemId Id=\"TASK1\" ChangeKey=\"CK\"/><t:Subject>Call back</t:Subject>"
            + "<t:DateTimeReceived>2026-11-10T09:31:00Z</t:DateTimeReceived><t:HasAttachments>false</t:HasAttachments></t:Task>"), token: "T1")
        s.apply(EWSBackend.parseSync(try! XMLDocument(xmlString: page)), account: acct.id, mailbox: .trash)
        return s
    }

    /// Exchange as Microsoft's ResponseCode reference documents it: DeleteItem of a calendar item without
    /// SendMeetingCancellations, or of a task without AffectedTaskOccurrences, and UpdateItem of a calendar item without
    /// SendMeetingInvitationsOrCancellations, are refused for that item.
    nonisolated static func strictExchange(_ request: String) -> String {
        guard let doc = try? XMLDocument(xmlString: request) else { return R5J.answer(request) }
        let ids = doc.all("ItemId").compactMap { $0.attr("Id") }
        if let del = doc.first("DeleteItem") {
            return EWSReply.resp("DeleteItem", ids.map { id in
                if id.hasPrefix("CAL"), del.attr("SendMeetingCancellations") == nil {
                    return EWSReply.err("DeleteItem", "ErrorSendMeetingCancellationsRequired", "SendMeetingCancellations attribute is required for Calendar items.")
                }
                if id.hasPrefix("TASK"), del.attr("AffectedTaskOccurrences") == nil {
                    return EWSReply.err("DeleteItem", "ErrorAffectedTaskOccurrencesRequired", "AffectedTaskOccurrences attribute is required for Task items.")
                }
                return EWSReply.ok("DeleteItem")
            }.joined())
        }
        if let upd = doc.first("UpdateItem") {
            return EWSReply.resp("UpdateItem", ids.map { id in
                id.hasPrefix("CAL") && upd.attr("SendMeetingInvitationsOrCancellations") == nil
                    ? EWSReply.err("UpdateItem", "ErrorSendMeetingInvitationsOrCancellationsRequired",
                                   "SendMeetingInvitationsOrCancellations attribute is required for Calendar items.")
                    : EWSReply.ok("UpdateItem")
            }.joined())
        }
        return R5J.answer(request)
    }

    /// Delete in Trash of a deleted appointment and a deleted task: the bare DeleteItem is refused for both, so they
    /// come back with "Exchange refused a change", and can never be erased from Trash.
    @Test func r5j03_eraseAppointmentAndTaskFromTrash() async throws {
        let server = RecordingServer { Self.strictExchange($0) }
        defer { server.stop() }
        let s = trashWithAppointmentAndTask(server)
        #expect(s.messages.count == 2, "the Trash sync lists the appointment and the task")
        s.delete(Set(s.messages.map(\.id)))
        try await waitFor { !server.requests.isEmpty && s.outbox.isEmpty }
        try await Task.sleep(for: .milliseconds(200))
        let del = try request(try #require(server.requests.first)).first("DeleteItem")
        #expect(s.messages.isEmpty, "back in Trash: \(s.messages.map(\.subject)); status: \(s.status ?? "")")
        #expect(del?.attr("SendMeetingCancellations") == "SendToNone" && del?.attr("AffectedTaskOccurrences") != nil,
                "DeleteItem attributes: \((del as? XMLElement)?.attributes?.map { "\($0.name ?? "")=\($0.stringValue ?? "")" } ?? [])")
    }

    /// Flagging (or marking read) a deleted appointment in Trash sends UpdateItem without
    /// SendMeetingInvitationsOrCancellations, which Exchange refuses for a calendar item: the change is undone.
    @Test func r5j04_flagAppointmentInTrash() async throws {
        let server = RecordingServer { Self.strictExchange($0) }
        defer { server.stop() }
        let s = trashWithAppointmentAndTask(server)
        let cal = try #require(s.messages.first { $0.remoteID == "CAL1" })
        s.setFlag(.red, for: [cal.id])
        try await waitFor { !server.requests.isEmpty && s.outbox.isEmpty }
        try await Task.sleep(for: .milliseconds(200))
        let upd = try request(try #require(server.requests.first)).first("UpdateItem")
        #expect(s.message(cal.id)?.flag != nil, "flag undone; status: \(s.status ?? "")")
        #expect(upd?.attr("SendMeetingInvitationsOrCancellations") != nil,
                "UpdateItem attributes: \((upd as? XMLElement)?.attributes?.map { "\($0.name ?? "")=\($0.stringValue ?? "")" } ?? [])")
    }
}
