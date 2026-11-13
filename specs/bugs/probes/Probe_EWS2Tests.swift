import Foundation
import Testing
@testable import EWS
@testable import MailModel

/// Round-2 EWS probes. No network: pure request builders / parsers, and EWSClient.call against a
/// `file://` URL holding a canned server response (real URLSession, real parser, no mock).
struct Probe_EWS2Tests {
    func doc(_ body: String) throws -> XMLDocument {
        try XMLDocument(xmlString: """
            <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" \
            xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages" \
            xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types"><s:Body>\(body)</s:Body></s:Envelope>
            """)
    }
    func request(_ body: String) throws -> XMLDocument { try XMLDocument(xmlString: EWSClient.envelope(body)) }

    /// A file standing in for one server response.
    func responseFile(_ xml: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ews-\(UUID().uuidString).xml")
        try Data(xml.utf8).write(to: url)
        return url
    }
    func envelope(_ body: String) -> String {
        """
        <?xml version="1.0" encoding="utf-8"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" \
        xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages" \
        xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types"><s:Body>\(body)</s:Body></s:Envelope>
        """
    }

    @Test func probeFileClientSmoke() async throws {
        let url = try responseFile(envelope("<m:X><m:ResponseMessages><m:R ResponseClass=\"Success\"><m:ResponseCode>NoError</m:ResponseCode></m:R></m:ResponseMessages></m:X>"))
        let d = try await EWSClient(url: url, username: "u", password: "p").call("<m:X/>")
        #expect(d.first("ResponseCode")?.stringValue == "NoError")
    }

    func backend(_ xml: String) throws -> EWSBackend {
        EWSBackend(client: EWSClient(url: try responseFile(xml), username: "u", password: "p"))
    }
    func ok(_ op: String, _ inner: String = "") -> String {
        "<m:\(op)ResponseMessage ResponseClass=\"Success\"><m:ResponseCode>NoError</m:ResponseCode>\(inner)</m:\(op)ResponseMessage>"
    }
    func err(_ op: String, _ code: String) -> String {
        "<m:\(op)ResponseMessage ResponseClass=\"Error\"><m:MessageText>\(code) text</m:MessageText><m:ResponseCode>\(code)</m:ResponseCode><m:DescriptiveLinkKey>0</m:DescriptiveLinkKey></m:\(op)ResponseMessage>"
    }
    func response(_ op: String, _ messages: String) -> String {
        envelope("<m:\(op)Response><m:ResponseMessages>\(messages)</m:ResponseMessages></m:\(op)Response>")
    }

    // MARK: Folders

    /// Outlook treats every IPF.Note.* class as a mail folder (e.g. RSS Feeds is IPF.Note.OutlookHomepage).
    @Test func probeMailFolderSubclassShown() throws {
        let d = try doc("""
            <m:Folders><t:Folder><t:FolderId Id="RSS"/><t:ParentFolderId Id="ROOT"/><t:DisplayName>RSS Feeds</t:DisplayName>
            <t:FolderClass>IPF.Note.OutlookHomepage</t:FolderClass></t:Folder></m:Folders>
            """)
        #expect(EWSBackend.folderTree(d.all("Folder"), known: [], skip: []).map(\.id) == ["RSS"])
    }

    // MARK: Attachments

    /// An attachment Exchange flags inline that the body never shows (text body, no cid: reference): it is
    /// neither listed nor shown, so the user can't see or save it.
    @Test func probeInlineAttachmentNotReferencedIsListed() throws {
        let d = try doc("""
            <t:Message><t:ItemId Id="A"/><t:Body BodyType="Text">See the attached scan.</t:Body>
            <t:Attachments><t:FileAttachment><t:AttachmentId Id="AT1"/><t:Name>scan.pdf</t:Name>
            <t:ContentType>application/pdf</t:ContentType><t:ContentId>3A1F@apple</t:ContentId><t:Size>1234</t:Size>
            <t:IsInline>true</t:IsInline></t:FileAttachment></t:Attachments></t:Message>
            """)
        let b = EWSBackend.parseBody(d.first("Message")!)
        #expect(b.attachments.map(\.name) == ["scan.pdf"])
    }

    // MARK: Randomized round-trips of every request builder (controls)

    struct RNG: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 { state &+= 0x9E3779B97F4A7C15; var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB; return z ^ (z >> 31) }
    }
    /// Text that XML 1.0 can carry (no C0 controls but tab/newline, no CR, no noncharacters).
    func randomText(_ g: inout RNG, max: Int = 40) -> String {
        let pools: [[UInt32]] = [Array(0x20...0x7E), [0x0A, 0x09], Array(0xC0...0x17F), Array(0x5D0...0x5EA),
                                 Array(0x4E00...0x4E40), Array(0x1F600...0x1F64F), [0x26, 0x3C, 0x3E, 0x22, 0x27, 0x5D]]
        let n = Int.random(in: 0...max, using: &g)
        return String(String.UnicodeScalarView((0..<n).map { _ in
            Unicode.Scalar(pools.randomElement(using: &g)!.randomElement(using: &g)!)! }))
    }

    @Test func probeRandomRequestRoundTrips() throws {
        var g = RNG(state: 42)
        for _ in 0..<300 {
            // The test parser (XMLDocument) drops whitespace-only text nodes, so each value carries a letter.
            let subject = "s" + randomText(&g), body = "b" + randomText(&g, max: 200)
            let id = String(randomText(&g, max: 20).filter { !$0.isWhitespace })  // IDs are base64: no blanks
            let name = String(randomText(&g, max: 15).filter { !",;\"<>@\n\t".contains($0) }).trimmingCharacters(in: .whitespaces)
            let draft = Draft(accountID: UUID(), to: name.isEmpty ? "a@x.com" : "\(name) <a@x.com>", subject: subject, body: body)
            let m = try #require(try request(EWSBackend.createRequest(draft, send: true)).first("Message"))
            #expect(m.text("Subject") == subject, "\(subject.unicodeScalars.map { String($0.value, radix: 16) }) → \(String(describing: m.text("Subject")?.unicodeScalars.map { String($0.value, radix: 16) }))")
            #expect(m.text("Body") == body)
            #expect(m.child("ToRecipients")?.text("EmailAddress") == "a@x.com")
            let files = [DraftAttachment(name: subject, contentType: id, data: Data(body.utf8))]
            let a = try #require(try request(EWSBackend.createAttachmentRequest(parentID: id, files)).first("FileAttachment"))
            #expect(a.text("Name") == subject && a.text("ContentType") == id)
            #expect(Data(base64Encoded: a.text("Content") ?? "") == Data(body.utf8))
            let r = try request(EWSBackend.respondRequest(id, InviteReply(response: .tentative, comment: body)))
            #expect(r.first("ReferenceItemId")?.attr("Id") == id && r.text("Body") == body)
            #expect(try request(EWSBackend.updateRequest([id], field: "message:IsRead", value: "<t:IsRead>true</t:IsRead>")).first("ItemId")?.attr("Id") == id)
            #expect(try request(EWSBackend.deleteRequest([id])).first("ItemId")?.attr("Id") == id)
            #expect(try request(EWSBackend.removeFromCalendarRequest(id)).first("ReferenceItemId")?.attr("Id") == id)
            let tips = try request(EWSBackend.mailTipsRequest(from: id)).text("EmailAddress")
            #expect(tips == id, "\(id.debugDescription) → \(tips.debugDescription)")
            #expect(try request(EWSBackend.attachmentContentRequest(id)).first("AttachmentId")?.attr("Id") == id)
            #expect(try request(EWSBackend.bodyRequest(id)).first("ItemId")?.attr("Id") == id)
        }
    }

    /// Element order inside each write request, per the EWS schema (sequence order matters).
    @Test func probeRequestElementOrder() throws {
        func order(_ x: String, _ name: String) throws -> [String] {
            try #require(try request(x).first(name)).elementChildren.compactMap(\.localName)
        }
        let d = Draft(accountID: UUID(), to: "a@x.com", cc: "b@x.com", subject: "s", body: "b")
        #expect(try order(EWSBackend.createRequest(d, send: true), "Message") == ["Subject", "Body", "ToRecipients", "CcRecipients"])
        #expect(try order(EWSBackend.createRequest(d, send: true), "CreateItem") == ["SavedItemFolderId", "Items"])
        #expect(try order(EWSBackend.moveRequest(["A"], to: "F"), "MoveItem") == ["ToFolderId", "ItemIds", "ReturnNewItemIds"])
        #expect(try order(EWSBackend.sendItemRequest(.init(id: "I", changeKey: "K")), "SendItem") == ["ItemIds", "SavedItemFolderId"])
        let f = [DraftAttachment(name: "p.png", contentType: "image/png", data: Data([1]))]
        #expect(try order(EWSBackend.createAttachmentRequest(parentID: "P", f, contentIDs: [0: "c"]), "FileAttachment")
                == ["Name", "ContentType", "ContentId", "IsInline", "Content"])
        let reply = InviteReply(response: .decline, comment: "c", proposedStart: Date(timeIntervalSince1970: 0), proposedEnd: Date(timeIntervalSince1970: 3600))
        #expect(try order(EWSBackend.respondRequest("M", reply), "DeclineItem") == ["Body", "ReferenceItemId", "ProposedStart", "ProposedEnd"])
        #expect(try order(EWSBackend.calendarViewRequest(from: .now, to: .now), "FindItem") == ["ItemShape", "CalendarView", "ParentFolderIds"])
        #expect(try order(EWSBackend.mailTipsRequest(from: "a@x.com"), "GetMailTips") == ["SendingAs", "Recipients", "MailTipsRequested"])
        #expect(try order(EWSBackend.findFoldersRequest(offset: 0), "FindFolder") == ["FolderShape", "IndexedPageFolderView", "ParentFolderIds"])
        #expect(try order(EWSBackend.bodyRequest("I"), "ItemShape") == ["BaseShape", "BodyType", "AdditionalProperties"])
    }

    /// parseSync over random pages vs a simple reference model.
    @Test func probeRandomSyncPagesMatchReference() throws {
        var g = RNG(state: 7)
        for _ in 0..<200 {
            var xml = "", ups: [String] = [], dels: [String] = [], reads: [String: Bool] = [:]
            for k in 0..<Int.random(in: 0...30, using: &g) {
                let id = "I\(Int.random(in: 0..<20, using: &g))_\(k)"
                switch Int.random(in: 0..<4, using: &g) {
                case 0: xml += "<t:Create><t:Message><t:ItemId Id=\"\(id)\"/><t:IsRead>false</t:IsRead></t:Message></t:Create>"; ups.append(id)
                case 1: xml += "<t:Update><t:MeetingRequest><t:ItemId Id=\"\(id)\"/></t:MeetingRequest></t:Update>"; ups.append(id)
                case 2: xml += "<t:Delete><t:ItemId Id=\"\(id)\"/></t:Delete>"; dels.append(id)
                default: let v = Bool.random(using: &g); xml += "<t:ReadFlagChange><t:ItemId Id=\"\(id)\"/><t:IsRead>\(v)</t:IsRead></t:ReadFlagChange>"; reads[id] = v
                }
            }
            let more = Bool.random(using: &g)
            let r = EWSBackend.parseSync(try doc(helperSync(xml, more: more)))
            #expect(r.upserts.compactMap(\.remoteID) == ups && r.deletedRemoteIDs == dels && r.readChanges == reads && r.more == more && r.token == "ST")
        }
    }
    func helperSync(_ changes: String, more: Bool) -> String {
        "<m:SyncFolderItemsResponse><m:ResponseMessages><m:SyncFolderItemsResponseMessage ResponseClass=\"Success\"><m:ResponseCode>NoError</m:ResponseCode>"
            + "<m:SyncState>ST</m:SyncState><m:IncludesLastItemInRange>\(!more)</m:IncludesLastItemInRange><m:Changes>\(changes)</m:Changes>"
            + "</m:SyncFolderItemsResponseMessage></m:ResponseMessages></m:SyncFolderItemsResponse>"
    }
}

/// MailStore driven by the real EWSBackend, whose server is a canned response file (no network, no mock).
@MainActor
struct Probe_EWS2StoreTests {
    let acct = Account(name: "Exchange", address: "me@work.com")
    let helper = Probe_EWS2Tests()

    func serverMessage(_ rid: String, read: Bool = false, box: MailboxKind = .inbox) -> Message {
        Message(accountID: acct.id, mailbox: box, from: Contact(name: "Ann", email: "ann@x.com"), to: [],
                subject: "S \(rid)", body: "", date: Date(timeIntervalSince1970: 1_000_000), isRead: read,
                remoteID: rid, bodyLoaded: false)
    }

    func store(_ xml: String, _ msgs: [Message]) throws -> (MailStore, URL) {
        let url = try helper.responseFile(xml)
        let s = MailStore(accounts: [], messages: [])
        s.add(acct, backend: EWSBackend(client: EWSClient(url: url, username: "u", password: "p")))
        s.merge(msgs, account: acct.id, mailbox: .inbox)
        s.setRemoteFolders([RemoteFolder(role: .inbox, id: "INBOX"), RemoteFolder(role: .trash, id: "DEL"),
                            RemoteFolder(role: .archive, id: "ARCH")], account: acct.id)
        return (s, url)
    }

    func waitForOutbox(_ s: MailStore) async throws {
        for _ in 0..<250 where !s.outbox.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
    }

    /// The same sync page applied twice changes nothing the second time (idempotence, control).
    @Test func probeSamePageTwiceIsIdempotent() async throws {
        let page = Probe_EWS2Tests().helperSync("""
            <t:Create><t:Message><t:ItemId Id="A"/><t:Subject>a</t:Subject><t:IsRead>false</t:IsRead><t:DateTimeReceived>2026-11-10T09:30:00Z</t:DateTimeReceived></t:Message></t:Create>
            <t:Create><t:MeetingRequest><t:ItemId Id="B"/><t:Subject>b</t:Subject><t:DateTimeReceived>2026-11-10T09:30:00Z</t:DateTimeReceived></t:MeetingRequest></t:Create>
            <t:ReadFlagChange><t:ItemId Id="A"/><t:IsRead>true</t:IsRead></t:ReadFlagChange>
            """, more: false)
        let r = EWSBackend.parseSync(try Probe_EWS2Tests().doc(page))
        let (s, _) = try store(helper.envelope(""), [])
        s.apply(r, account: acct.id, mailbox: .inbox)
        let first = s.messages
        s.apply(r, account: acct.id, mailbox: .inbox)
        #expect(s.messages == first)
        #expect(s.messages.count == 2)
    }


    /// ExchangeAccount list round-trips through UserDefaults (control; never the Keychain).
    @Test func probeAccountsRoundTrip() throws {
        let suite = "probe-ews2-\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        let list = [ExchangeAccount(email: "ä@x.com", username: "DOM\\till", server: "mail.x.com"),
                    ExchangeAccount(email: "b@x.com", username: "b", server: "https://h/EWS/Exchange.asmx")]
        ExchangeAccount.save(list, d)
        #expect(ExchangeAccount.saved(d) == list)
        ExchangeAccount.save([], d)
        #expect(ExchangeAccount.saved(d).isEmpty)
    }
}

/// Response-side whitespace (control): XMLDocument drops whitespace-only text nodes unless asked to keep them.
struct Probe_EWS2WhitespaceTests {
    @Test func probeBodyKeepsIndentation() throws {
        let raw = "<a xmlns:t=\"t\"><t:Message><t:ItemId Id=\"A\"/><t:Body BodyType=\"Text\">  indented\n\n\tcode  </t:Body><t:Subject>  two  spaces </t:Subject></t:Message></a>"
        let d = try XMLDocument(data: EWSClient.sanitize(Data(raw.utf8)))
        let item = d.first("Message")!
        #expect(EWSBackend.parseBody(item).text == "  indented\n\n\tcode  ")
        #expect(EWSBackend.message(item)?.subject == "  two  spaces ")
    }

    // MARK: Fields missing on one element are taken from a later one (XPath `.//` from a context node)

    func getItem(_ item: String) throws -> XMLNode {
        let x = """
            <?xml version="1.0" encoding="utf-8"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>\
            <m:GetItemResponse xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages" \
            xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types"><m:ResponseMessages>\
            <m:GetItemResponseMessage ResponseClass="Success"><m:ResponseCode>NoError</m:ResponseCode><m:Items>\(item)</m:Items>\
            </m:GetItemResponseMessage></m:ResponseMessages></m:GetItemResponse></s:Body></s:Envelope>
            """
        return try #require(try XMLDocument(data: EWSClient.sanitize(Data(x.utf8))).first("Items")?.elementChildren.first)
    }

    /// A recipient without an address (an Outlook contact group, RoutingType MAPIPDL) before an ordinary one.
    @Test func probeRecipientWithoutAddressKeepsNoAddress() throws {
        let item = try getItem("""
            <t:Message><t:ItemId Id="A"/><t:Body BodyType="Text">x</t:Body><t:ToRecipients>\
            <t:Mailbox><t:Name>Team Group</t:Name><t:RoutingType>MAPIPDL</t:RoutingType><t:MailboxType>PrivateDL</t:MailboxType></t:Mailbox>\
            <t:Mailbox><t:Name>Bob</t:Name><t:EmailAddress>bob@x.com</t:EmailAddress><t:RoutingType>SMTP</t:RoutingType></t:Mailbox>\
            </t:ToRecipients></t:Message>
            """)
        let to = EWSBackend.parseBody(item).to ?? []
        #expect(to.map(\.email) == ["", "bob@x.com"], "\(to)")
    }

    @Test func probeSenderWithoutAddressDoesNotTakeRecipientAddress() throws {
        let item = try getItem("""
            <t:Message><t:ItemId Id="A"/><t:Body BodyType="Text">x</t:Body>\
            <t:From><t:Mailbox><t:Name>Ann</t:Name></t:Mailbox></t:From>\
            <t:ToRecipients><t:Mailbox><t:Name>Bob</t:Name><t:EmailAddress>bob@x.com</t:EmailAddress></t:Mailbox></t:ToRecipients></t:Message>
            """)
        let from = EWSBackend.parseBody(item).from
        #expect(from?.email == "", "\(String(describing: from))")
    }

    @Test func probeAttendeeWithoutAddressDoesNotTakeNextAddress() throws {
        let item = try getItem("""
            <t:MeetingRequest><t:ItemId Id="M"/><t:Body BodyType="Text">x</t:Body>\
            <t:Start>2026-11-23T10:00:00Z</t:Start><t:End>2026-11-23T11:00:00Z</t:End>\
            <t:Organizer><t:Mailbox><t:Name>Org</t:Name></t:Mailbox></t:Organizer>\
            <t:RequiredAttendees><t:Attendee><t:Mailbox><t:Name>Room 1</t:Name></t:Mailbox><t:ResponseType>Unknown</t:ResponseType></t:Attendee>\
            <t:Attendee><t:Mailbox><t:Name>Bob</t:Name><t:EmailAddress>bob@x.com</t:EmailAddress></t:Mailbox><t:ResponseType>Unknown</t:ResponseType></t:Attendee></t:RequiredAttendees>\
            <t:OptionalAttendees><t:Attendee><t:Mailbox><t:Name>Cid</t:Name><t:EmailAddress>cid@x.com</t:EmailAddress></t:Mailbox></t:Attendee></t:OptionalAttendees>\
            </t:MeetingRequest>
            """)
        let inv = try #require(EWSBackend.parseBody(item).invite)
        #expect(inv.organizer?.email == "", "organizer \(String(describing: inv.organizer))")
        #expect(inv.required.map(\.email) == ["", "bob@x.com"], "required \(inv.required)")
        #expect(inv.optional.map(\.email) == ["cid@x.com"])
    }

    /// A sync page: the first item's summary lacks fields a later item has (control, in Exchange's element order:
    /// IsRead after From). With From as the last child, Foundation's `.//` search leaks into the next item.
    @Test func probeSyncItemDoesNotTakeLaterItemsFields() throws {
        let page = Probe_EWS2Tests().helperSync("""
            <t:Create><t:Message><t:ItemId Id="A"/><t:Subject>a</t:Subject>\
            <t:From><t:Mailbox><t:Name>Ann</t:Name></t:Mailbox></t:From><t:IsRead>true</t:IsRead></t:Message></t:Create>\
            <t:Create><t:Message><t:ItemId Id="B"/><t:Subject>b</t:Subject><t:IsRead>false</t:IsRead>\
            <t:DateTimeReceived>2026-11-10T09:30:00Z</t:DateTimeReceived><t:HasAttachments>true</t:HasAttachments>\
            <t:DisplayTo>Zoe</t:DisplayTo><t:DisplayCc>Yan</t:DisplayCc><t:Flag><t:FlagStatus>Flagged</t:FlagStatus></t:Flag>\
            <t:From><t:Mailbox><t:Name>Bob</t:Name><t:EmailAddress>bob@x.com</t:EmailAddress></t:Mailbox></t:From></t:Message></t:Create>
            """, more: false)
        let x = "<?xml version=\"1.0\" encoding=\"utf-8\"?><s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" xmlns:m=\"http://schemas.microsoft.com/exchange/services/2006/messages\" xmlns:t=\"http://schemas.microsoft.com/exchange/services/2006/types\"><s:Body>\(page)</s:Body></s:Envelope>"
        let r = EWSBackend.parseSync(try XMLDocument(data: Data(x.utf8)))
        let a = try #require(r.upserts.first { $0.remoteID == "A" })
        #expect(a.from.email == "", "from \(a.from)")
        #expect(a.cc.isEmpty && a.to.isEmpty, "to \(a.to) cc \(a.cc)")
        #expect(a.date == .distantPast && !a.hasAttachments && a.flag == nil, "date \(a.date) att \(a.hasAttachments) flag \(String(describing: a.flag))")
    }

    /// A folder without FolderClass (null class = mail, per folderTree) before a Notes folder (IPF.StickyNote).
    @Test func probeClasslessFolderDoesNotTakeNextFoldersClass() throws {
        let x = """
            <?xml version="1.0" encoding="utf-8"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" \
            xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages" xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types"><s:Body>\
            <m:FindFolderResponse><m:ResponseMessages><m:FindFolderResponseMessage ResponseClass="Success"><m:ResponseCode>NoError</m:ResponseCode>\
            <m:RootFolder IndexedPagingOffset="2" TotalItemsInView="2" IncludesLastItemInRange="true"><t:Folders>\
            <t:Folder><t:FolderId Id="IMAP"/><t:ParentFolderId Id="ROOT"/><t:DisplayName>Old IMAP</t:DisplayName><t:TotalCount>5</t:TotalCount></t:Folder>\
            <t:Folder><t:FolderId Id="NOTES"/><t:ParentFolderId Id="ROOT"/><t:DisplayName>Notes</t:DisplayName><t:TotalCount>1</t:TotalCount><t:FolderClass>IPF.StickyNote</t:FolderClass></t:Folder>\
            </t:Folders></m:RootFolder></m:FindFolderResponseMessage></m:ResponseMessages></m:FindFolderResponse></s:Body></s:Envelope>
            """
        let d = try XMLDocument(data: Data(x.utf8))
        #expect(EWSBackend.folderTree(d.all("Folder"), known: [], skip: []).map(\.id) == ["IMAP"])
    }
}
