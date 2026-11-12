import Foundation
import Testing
@testable import EWS
@testable import MailModel

/// Bug-hunt probes for the EWS layer. Pure parsing / request building only, no network.
struct Probe_EWSTests {
    func doc(_ body: String) throws -> XMLDocument {
        try XMLDocument(xmlString: """
            <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" \
            xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages" \
            xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types"><s:Body>\(body)</s:Body></s:Envelope>
            """)
    }
    func request(_ body: String) throws -> XMLDocument { try XMLDocument(xmlString: EWSClient.envelope(body)) }

    // MARK: Dates

    @Test func probeReceivedDateWithOffset() throws {
        let d = try doc("""
            <t:Message><t:ItemId Id="ID1"/><t:DateTimeReceived>2026-11-10T10:30:00+01:00</t:DateTimeReceived></t:Message>
            """)
        let m = try #require(EWSBackend.message(d.first("Message")!))
        #expect(m.date == ISO8601DateFormatter().date(from: "2026-11-10T09:30:00Z"))
    }

    // MARK: Request building

    @Test func probeSpecialCharsRoundTrip() throws {
        let subject = "A & B < C > D \" E ' F 😀 עברית \t G"
        let draft = Draft(accountID: UUID(), to: "a@x.com", subject: subject, body: "x")
        let msg = try #require(try request(EWSBackend.createRequest(draft, send: true)).first("Message"))
        #expect(msg.text("Subject") == subject)
    }

    @Test func probeIDsWithSpecialChars() throws {
        let id = "AAMk+/=&<>\"'x"
        let d = try request(EWSBackend.moveRequest([id], to: id))
        #expect(d.first("ItemId")?.attr("Id") == id)
        #expect(d.first("FolderId")?.attr("Id") == id)
        let s = try request(EWSBackend.sendItemRequest(.init(id: id, changeKey: id)))
        #expect(s.first("ItemId")?.attr("ChangeKey") == id)
    }

    // MARK: Response sanitizing

    // MARK: Plain text fallback

    @Test func probePlainTextDecodesCommonEntities() {
        #expect(EWSBackend.plainText("<p>Gr&uuml;&szlig;e &ndash; Till&#8217;s &euro;5 &#x27;x&#x27;</p>") == "Grüße – Till’s €5 'x'")
    }

    @Test func probePlainTextBreaksLinesAtBrWithAttributes() {
        #expect(EWSBackend.plainText("Line1<br clear=\"all\">Line2") == "Line1\nLine2")
    }

    @Test func probePlainTextKeepsTableCellsApart() {
        #expect(EWSBackend.plainText("<table><tr><td>Name</td><td>Value</td></tr></table>") != "NameValue")
    }

    @Test func probePlainTextDropsComments() {
        #expect(EWSBackend.plainText("<!-- if a > b then --><p>Hi</p>") == "Hi")
    }

    // MARK: Parsing shapes

    @Test func probeSummaryCDATASubject() throws {
        let d = try doc("<t:Message><t:ItemId Id=\"ID1\"/><t:Subject><![CDATA[a < b & c]]></t:Subject></t:Message>")
        #expect(EWSBackend.message(d.first("Message")!)?.subject == "a < b & c")
    }

    @Test func probeSyncWithDefaultNamespacePrefixes() throws {
        let x = """
            <Envelope xmlns="http://schemas.xmlsoap.org/soap/envelope/"><Body>
            <SyncFolderItemsResponse xmlns="http://schemas.microsoft.com/exchange/services/2006/messages">
            <ResponseMessages><SyncFolderItemsResponseMessage ResponseClass="Success"><ResponseCode>NoError</ResponseCode>
            <SyncState>S</SyncState><IncludesLastItemInRange>true</IncludesLastItemInRange>
            <Changes><Create xmlns="http://schemas.microsoft.com/exchange/services/2006/types"><Message><ItemId Id="A"/>
            <Subject>x</Subject></Message></Create></Changes></SyncFolderItemsResponseMessage></ResponseMessages>
            </SyncFolderItemsResponse></Body></Envelope>
            """
        let r = EWSBackend.parseSync(try XMLDocument(xmlString: x))
        #expect(r.upserts.map(\.remoteID) == ["A"])
        #expect(!r.more)
    }

    @Test func probeSyncEmpty() throws {
        let d = try doc("""
            <m:SyncFolderItemsResponse><m:ResponseMessages><m:SyncFolderItemsResponseMessage ResponseClass="Success">
            <m:ResponseCode>NoError</m:ResponseCode><m:SyncState>S</m:SyncState>
            <m:IncludesLastItemInRange>true</m:IncludesLastItemInRange><m:Changes/></m:SyncFolderItemsResponseMessage>
            </m:ResponseMessages></m:SyncFolderItemsResponse>
            """)
        let r = EWSBackend.parseSync(d)
        #expect(r.upserts.isEmpty && r.deletedRemoteIDs.isEmpty && !r.more && r.token == "S")
    }

    /// A message-type item (summary) whose Body has an item attachment containing its own IsInline etc.
    @Test func probeFromMailboxWithoutName() throws {
        let d = try doc("<t:Message><t:ItemId Id=\"A\"/><t:From><t:Mailbox><t:EmailAddress>x@y.com</t:EmailAddress></t:Mailbox></t:From></t:Message>")
        let m = try #require(EWSBackend.message(d.first("Message")!))
        #expect(m.from == Contact(name: "x@y.com", email: "x@y.com"))
    }

    @Test func probeManyRecipientsInBody() throws {
        let boxes = (0..<300).map { "<t:Mailbox><t:Name>N\($0)</t:Name><t:EmailAddress>n\($0)@x.com</t:EmailAddress></t:Mailbox>" }.joined()
        let d = try doc("<t:Message><t:ItemId Id=\"A\"/><t:Body BodyType=\"Text\">b</t:Body><t:ToRecipients>\(boxes)</t:ToRecipients></t:Message>")
        let b = EWSBackend.parseBody(d.first("Message")!)
        #expect(b.to?.count == 300)
        #expect(b.from == nil)
    }

    @Test func probeInlineImageCaseInsensitiveContentID() throws {
        let d = try doc("""
            <t:Message><t:Attachments><t:FileAttachment><t:AttachmentId Id="A1"/><t:Name>i.png</t:Name>
            <t:ContentType>image/png</t:ContentType><t:ContentId>&lt;Image001.PNG@01D&gt;</t:ContentId></t:FileAttachment></t:Attachments></t:Message>
            """)
        #expect(EWSBackend.inlineAttachmentIDs(d.first("Message")!, wanted: ["Image001.PNG@01D"]) == ["A1"])
    }

    @Test func probeMoveWithErrorInMiddle() throws {
        let ok = { (id: String) in "<m:MoveItemResponseMessage ResponseClass=\"Success\"><m:ResponseCode>NoError</m:ResponseCode><m:Items><t:Message><t:ItemId Id=\"\(id)\"/></t:Message></m:Items></m:MoveItemResponseMessage>" }
        let bad = "<m:MoveItemResponseMessage ResponseClass=\"Error\"><m:MessageText>x</m:MessageText><m:ResponseCode>ErrorItemNotFound</m:ResponseCode><m:Items/></m:MoveItemResponseMessage>"
        let d = try doc("<m:MoveItemResponse><m:ResponseMessages>" + ok("N1") + bad + ok("N3") + "</m:ResponseMessages></m:MoveItemResponse>")
        #expect(EWSBackend.parseMove(d, ids: ["A", "B", "C"]) == ["A": "N1", "C": "N3"])
    }

    @Test func probeFolderTreeSubfolderOfArchive() throws {
        let d = try doc("""
            <m:FindFolderResponse><m:RootFolder><t:Folders>
            <t:Folder><t:FolderId Id="AR"/><t:ParentFolderId Id="R"/><t:DisplayName>Archive</t:DisplayName></t:Folder>
            <t:Folder><t:FolderId Id="Y"/><t:ParentFolderId Id="AR"/><t:DisplayName>2025</t:DisplayName></t:Folder>
            </t:Folders></m:RootFolder></m:FindFolderResponse>
            """)
        let arch = try #require(EWSBackend.archiveFolder(d.all("Folder")))
        #expect(EWSBackend.folderTree(d.all("Folder"), known: [arch], skip: []).map(\.parent) == [.archive])
    }

    @Test func probeSyncHugeBatchIsFast() throws {
        let items = (0..<512).map { i in
            "<t:Create><t:Message><t:ItemId Id=\"ID\(i)\"/><t:Subject>S\(i)</t:Subject><t:DateTimeReceived>2026-11-10T09:30:00Z</t:DateTimeReceived><t:Preview>\(String(repeating: "x", count: 255))</t:Preview><t:DisplayTo>A; B; C</t:DisplayTo></t:Message></t:Create>"
        }.joined()
        let d = try doc("<m:SyncFolderItemsResponse><m:ResponseMessages><m:SyncFolderItemsResponseMessage><m:SyncState>S</m:SyncState><m:Changes>\(items)</m:Changes></m:SyncFolderItemsResponseMessage></m:ResponseMessages></m:SyncFolderItemsResponse>")
        let t = Date()
        let r = EWSBackend.parseSync(d)
        #expect(r.upserts.count == 512)
        #expect(Date().timeIntervalSince(t) < 2)
    }

    /// "Accepted: …" answers carry the meeting's Start/End in Exchange 2013; they are not invites to answer.
    @Test func probeMeetingResponseIsNotAnInvite() throws {
        let d = try doc("""
            <t:MeetingResponse><t:ItemId Id="R1"/><t:Body BodyType="Text">ok</t:Body>
            <t:Start>2026-11-23T11:30:00Z</t:Start><t:End>2026-11-23T12:00:00Z</t:End><t:Location>Room</t:Location></t:MeetingResponse>
            """)
        let item = d.first("MeetingResponse")!
        #expect(EWSBackend.message(item)?.isInvite == false)
        #expect(EWSBackend.parseBody(item).invite == nil)
    }

    /// Folder pages that overlap (a folder created between two FindFolder pages shifts the offsets) list a folder twice.
    @Test func probeFolderTreeDeduplicatesRepeatedFolders() throws {
        let f = "<t:Folder><t:FolderId Id=\"P\"/><t:ParentFolderId Id=\"R\"/><t:DisplayName>Projects</t:DisplayName></t:Folder>"
        let d = try doc("<m:Folders>" + f + f + "</m:Folders>")
        #expect(EWSBackend.folderTree(d.all("Folder"), known: [], skip: []).count == 1)
    }

    // MARK: Round 2

    @Test func probeEmptyTextBodyFallsBackToHTML() throws {
        let d = try doc("""
            <t:Message><t:ItemId Id="A"/><t:Body BodyType="HTML">&lt;p&gt;Hello&lt;/p&gt;</t:Body><t:TextBody BodyType="Text"/></t:Message>
            """)
        #expect(EWSBackend.parseBody(d.first("Message")!).text == "Hello")
    }

    @Test func probeInlineImageWithGenericContentType() throws {
        let d = try doc("""
            <t:Message><t:Attachments><t:FileAttachment><t:AttachmentId Id="A1"/><t:Name>image001.png</t:Name>
            <t:ContentType>application/octet-stream</t:ContentType><t:ContentId>image001.png@01D</t:ContentId></t:FileAttachment></t:Attachments></t:Message>
            """)
        #expect(EWSBackend.inlineAttachmentIDs(d.first("Message")!, wanted: ["image001.png@01D"]) == ["A1"])
    }

    @Test func probePlainTextOnHugeHTMLIsFast() {
        let html = "<html><head><style>p{}</style></head><body>" + String(repeating: "<p>Hello <b>world</b> &amp; more</p>\n", count: 100_000) + "</body></html>"
        let t = Date()
        let out = EWSBackend.plainText(html)
        #expect(out.hasPrefix("Hello world & more"))
        #expect(Date().timeIntervalSince(t) < 5)
    }

    @Test func probePlainTextUnclosedStyleIsFast() {
        let html = String(repeating: "<style>x", count: 5_000) + String(repeating: "a", count: 100_000)
        let t = Date()
        _ = EWSBackend.plainText(html)
        #expect(Date().timeIntervalSince(t) < 5)
    }

    @Test func probeSanitizeHugeResponseIsFast() {
        let raw = "<a>" + String(repeating: "<s>x&#8;y&amp;z</s>", count: 200_000) + "</a>"
        let t = Date()
        let d = try? XMLDocument(data: EWSClient.sanitize(Data(raw.utf8)))
        #expect(d != nil)
        #expect(Date().timeIntervalSince(t) < 5)
    }


    @Test func probeServerInnerSpace() {
        #expect(ExchangeAccount(email: "", username: "", server: "mail example.com").ewsURL == nil)
    }
}
