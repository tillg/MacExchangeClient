import Foundation
import Testing
@testable import EWS
@testable import MailModel

// MARK: - Harness (copied from specs/bugs/probes/Probe_EWSFlowTests.swift, renamed so all probes compile together)

/// file:// fixture (FIFO). A named pipe at a `file://` URL stands in for the EWS endpoint: each request the real
/// EWSClient makes reads the next hand-written response. No network, no fake class.
final class I4Server: @unchecked Sendable {
    let url: URL
    private let path: String
    private let lock = NSLock()
    private var script: [String]
    private var fallbackXML: String
    private var stopped = false
    private var _served = 0

    var served: Int { lock.withLock { _served } }

    init(_ script: [String], fallback: String? = nil) {
        path = FileManager.default.temporaryDirectory.appendingPathComponent("ews-i4-\(UUID().uuidString).xml").path
        mkfifo(path, 0o600)
        url = URL(fileURLWithPath: path)
        self.script = script
        fallbackXML = fallback ?? I4.fault("ErrorScriptExhausted", "No scripted response left")
        let t = Thread { [self] in loop() }
        t.start()
    }

    func stop() { lock.withLock { stopped = true } }

    private func loop() {
        signal(SIGPIPE, SIG_IGN)
        while true {
            if lock.withLock({ stopped }) { return }
            let fd = open(path, O_WRONLY | O_NONBLOCK)
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
            usleep(300_000)
        }
    }
}

/// Hand-written Exchange responses.
enum I4 {
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
        </detail></s:Fault></s:Body></s:Envelope>
        """
    }
    static let answered = resp("CreateItem", ok("CreateItem", "<m:Items/>"))
    static func moved(_ new: String) -> String {
        resp("MoveItem", ok("MoveItem", "<m:Items><t:MeetingRequest><t:ItemId Id=\"\(new)\" ChangeKey=\"CK\"/></t:MeetingRequest></m:Items>"))
    }
    static func folders(_ list: [(String, String)]) -> String {
        resp("GetFolder", list.map { id, name in
            ok("GetFolder", "<m:Folders><t:Folder><t:FolderId Id=\"\(id)\" ChangeKey=\"AQ\"/><t:DisplayName>\(name)</t:DisplayName>"
                + "<t:TotalCount>0</t:TotalCount></t:Folder></m:Folders>")
        }.joined())
    }
    static let standardFolders = folders([("INBOX", "Inbox"), ("DRAFTS", "Drafts"), ("SENT", "Sent Items"),
                                          ("JUNK", "Junk Email"), ("DEL", "Deleted Items"), ("OUTBOX", "Outbox")])
    static let noFolders = resp("FindFolder", ok("FindFolder", "<m:RootFolder IndexedPagingOffset=\"0\" TotalItemsInView=\"0\" "
        + "IncludesLastItemInRange=\"true\"><t:Folders/></m:RootFolder>"))
}

@MainActor
@Suite(.serialized)
struct Probe_Invite4FlowTests {
    let acct = Account(name: "Exchange", address: "me@work.com")

    func store(_ server: I4Server, folders: Bool) -> MailStore {
        let s = MailStore(accounts: [], messages: [])
        s.add(acct, backend: EWSBackend(client: EWSClient(url: server.url, username: "u", password: "p")))  // file:// fixture
        if folders {
            s.setRemoteFolders([RemoteFolder(role: .inbox, id: "INBOX"), RemoteFolder(role: .drafts, id: "DRAFTS"),
                                RemoteFolder(role: .sent, id: "SENT"), RemoteFolder(role: .trash, id: "DEL")], account: acct.id)
        }
        return s
    }

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

    func waitFor(_ timeout: Duration = .seconds(6), _ cond: () -> Bool) async throws {
        let end = ContinuousClock.now + timeout
        while !cond() && ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(10)) }
    }

    /// Control: folder list known. Do Not Send answers (SaveOnly), then the store moves the invite to Deleted Items.
    // file:// fixture
    @Test func controlDoNotSendMovesInviteWhenFoldersKnown() async throws {
        let server = I4Server([I4.answered, I4.moved("M-T")])
        defer { server.stop() }
        let s = store(server, folders: true)
        s.merge([inviteMessage("M")], account: acct.id, mailbox: .inbox)
        s.respond(InviteReply(response: .accept, send: false), to: s.messages[0].id)
        try await waitFor { s.outbox.isEmpty }
        try await Task.sleep(for: .milliseconds(800))
        #expect(s.messages[0].remoteID == "M-T", "rid \(s.messages[0].remoteID ?? "") served \(server.served) status \(s.status ?? "")")
    }
}

// MARK: - Pure / store probes (no server)

@MainActor
struct Probe_Invite4Tests {
    let acct = Account(name: "Exchange", address: "me@work.com")

    func doc(_ body: String) throws -> XMLDocument {
        try XMLDocument(xmlString: """
            <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" \
            xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages" \
            xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types"><s:Body>\(body)</s:Body></s:Envelope>
            """)
    }

    /// Control: invite fields with entities, all-day, no organizer, attendees without addresses.
    @Test func controlParseInviteShapes() throws {
        let d = try doc("""
            <t:MeetingRequest><t:ItemId Id="M"/><t:Subject>X</t:Subject>\
            <t:Start>2026-11-23T00:00:00+01:00</t:Start><t:End>2026-11-24T00:00:00.000+01:00</t:End>\
            <t:Location>R&amp;D &lt;Room 4&gt;</t:Location><t:IsAllDayEvent>true</t:IsAllDayEvent>\
            <t:RequiredAttendees><t:Attendee><t:Mailbox><t:Name>Ann</t:Name></t:Mailbox></t:Attendee>\
            <t:Attendee><t:Mailbox><t:EmailAddress>bob@x.com</t:EmailAddress></t:Mailbox></t:Attendee></t:RequiredAttendees>\
            <t:OptionalAttendees/></t:MeetingRequest>
            """)
        let item = try #require(d.first("MeetingRequest"))
        let inv = try #require(EWSBackend.parseInvite(item))
        #expect(inv.location == "R&D <Room 4>")
        #expect(inv.isAllDay && inv.organizer == nil)
        #expect(inv.start == ISO8601DateFormatter().date(from: "2026-11-22T23:00:00Z"))
        #expect(inv.required.map(\.name) == ["Ann", "bob@x.com"])
    }

    /// Control: an answered invite with a proposal and comment survives the database.
    @Test func controlAnsweredInviteRoundTripsDatabase() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ProbeI4-\(UUID()).sqlite")
        var inv = Invite(start: Date(timeIntervalSince1970: 1_795_428_000.25), end: Date(timeIntervalSince1970: 1_795_431_600))
        inv.isCancellation = false
        let m = Message(accountID: acct.id, from: Contact(name: "O", email: "o@x.com"), to: [], subject: "S", body: "B",
                        date: .now, remoteID: "R", invite: inv)
        let s = MailStore(accounts: [acct], messages: [])
        s.merge([m], account: acct.id, mailbox: .inbox)
        s.respond(InviteReply(response: .decline, comment: "Nope 🙂", proposedStart: Date(timeIntervalSince1970: 1_795_500_000),
                              proposedEnd: Date(timeIntervalSince1970: 1_795_503_600)), to: s.messages[0].id)
        let db = try MailDatabase(url: url)
        try db.write(s.takeChanges().resolved())
        let back = try MailDatabase(url: url).messages()
        #expect(back.first?.invite == s.messages[0].invite)
        #expect(back.first?.mailbox == .trash)
    }

    /// Property: DayLayout never puts two overlapping events in the same column, and every column < of.
    @Test func controlDayLayoutNoOverlapInColumn() {
        var rng = SystemRandomNumberGenerator()
        let base = Date(timeIntervalSince1970: 1_795_392_000)
        for _ in 0..<2000 {
            let events = (0..<Int.random(in: 1...9, using: &rng)).map { i -> CalendarEvent in
                let s = Double(Int.random(in: 0...47, using: &rng)) * 1800
                let len = Double(Int.random(in: 1...8, using: &rng)) * 1800
                return CalendarEvent(subject: "E\(i)", start: base.addingTimeInterval(s), end: base.addingTimeInterval(s + len))
            }
            let placed = DayLayout.columns(events)
            #expect(placed.count == events.count)
            for a in placed { #expect(a.column < a.of) }
            for a in placed { for b in placed where a != b && a.column == b.column {
                let overlap = a.event.start < b.event.end && b.event.start < a.event.end
                if overlap { Issue.record("overlap in column: \(a.event.subject) \(b.event.subject)"); return }
            } }
        }
    }
}
