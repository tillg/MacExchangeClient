import Foundation
import Testing
@testable import EWS
@testable import MailModel

/// Parsing of EWS responses, using hand-written XML in the documented shapes (no real mail).
struct EWSParsingTests {
    func doc(_ body: String) throws -> XMLDocument {
        try XMLDocument(xmlString: """
            <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" \
            xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages" \
            xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types"><s:Body>\(body)</s:Body></s:Envelope>
            """)
    }

    let summary = """
        <t:Message><t:ItemId Id="ID1" ChangeKey="CK"/><t:Subject>Hello &amp; welcome</t:Subject>
        <t:DateTimeReceived>2026-11-10T09:30:00Z</t:DateTimeReceived><t:HasAttachments>true</t:HasAttachments>
        <t:DisplayCc></t:DisplayCc><t:DisplayTo>Ann Smith; Bob Jones</t:DisplayTo><t:Preview>First line</t:Preview>
        <t:Flag><t:FlagStatus>Flagged</t:FlagStatus></t:Flag><t:IsRead>false</t:IsRead>
        <t:From><t:Mailbox><t:Name>Carol</t:Name></t:Mailbox></t:From>
        <t:ConversationId Id="CONV1" ChangeKey="CK"/></t:Message>
        """

    @Test func summaryMessage() throws {
        let item = try #require(try doc(summary).first("Message"))
        let m = try #require(EWSBackend.message(item))
        #expect(m.remoteID == "ID1")
        #expect(m.subject == "Hello & welcome")
        #expect(m.date == ISO8601DateFormatter().date(from: "2026-11-10T09:30:00Z"))
        #expect(m.hasAttachments)
        #expect(m.to.map(\.name) == ["Ann Smith", "Bob Jones"])
        #expect(m.cc.isEmpty)
        #expect(m.flag == .red)
        #expect(!m.isRead)
        #expect(m.from.name == "Carol")
        #expect(!m.bodyLoaded)
        #expect(m.preview == "First line")
        #expect(m.conversationID == "CONV1")
        #expect(EWSBackend.summaryProps.contains("item:ConversationId"))
    }

    @Test func syncChanges() throws {
        let d = try doc("""
            <m:SyncFolderItemsResponse><m:ResponseMessages><m:SyncFolderItemsResponseMessage ResponseClass="Success">
            <m:ResponseCode>NoError</m:ResponseCode><m:SyncState>STATE2</m:SyncState>
            <m:IncludesLastItemInRange>false</m:IncludesLastItemInRange><m:Changes>
            <t:Create>\(summary)</t:Create>
            <t:Update><t:Message><t:ItemId Id="ID2"/><t:Subject>Changed</t:Subject></t:Message></t:Update>
            <t:Delete><t:ItemId Id="ID3"/></t:Delete>
            <t:ReadFlagChange><t:ItemId Id="ID4"/><t:IsRead>true</t:IsRead></t:ReadFlagChange>
            </m:Changes></m:SyncFolderItemsResponseMessage></m:ResponseMessages></m:SyncFolderItemsResponse>
            """)
        let r = EWSBackend.parseSync(d)
        #expect(r.upserts.map(\.remoteID) == ["ID1", "ID2"])
        #expect(r.deletedRemoteIDs == ["ID3"])
        #expect(r.readChanges == ["ID4": true])
        #expect(r.token == "STATE2")
        #expect(r.more)
    }

    @Test func bodySkipsInlineAttachmentsAndReadsAddresses() throws {
        let d = try doc("""
            <t:Message><t:ItemId Id="ID1"/><t:Body BodyType="Text">Hi there</t:Body>
            <t:Attachments><t:FileAttachment><t:Name>report.pdf</t:Name><t:IsInline>false</t:IsInline></t:FileAttachment>
            <t:FileAttachment><t:Name>image001.png</t:Name><t:IsInline>true</t:IsInline></t:FileAttachment></t:Attachments>
            <t:From><t:Mailbox><t:Name>Carol</t:Name><t:EmailAddress>carol@x.com</t:EmailAddress></t:Mailbox></t:From>
            <t:ToRecipients><t:Mailbox><t:EmailAddress>ann@x.com</t:EmailAddress></t:Mailbox></t:ToRecipients></t:Message>
            """)
        let b = EWSBackend.parseBody(try #require(d.first("Message")))
        #expect(b.text == "Hi there")
        #expect(b.attachments == ["report.pdf"])
        #expect(b.from == Contact(name: "Carol", email: "carol@x.com"))
        #expect(b.to == [Contact(name: "ann@x.com", email: "ann@x.com")])
        #expect(b.cc == [])
    }

    @Test func htmlBodyKeepsTheHTMLAndTakesTextFromTextBody() throws {
        let d = try doc("""
            <t:Message><t:ItemId Id="ID1"/><t:Body BodyType="HTML">&lt;p&gt;Hi &lt;b&gt;there&lt;/b&gt;&lt;/p&gt;</t:Body>
            <t:TextBody BodyType="Text">Hi there</t:TextBody></t:Message>
            """)
        let b = EWSBackend.parseBody(try #require(d.first("Message")))
        #expect(b.html == "<p>Hi <b>there</b></p>")
        #expect(b.text == "Hi there")
    }

    @Test func htmlBodyWithoutTextBodyFallsBackToStrippedHTML() throws {
        let d = try doc("""
            <t:Message><t:ItemId Id="ID1"/><t:Body BodyType="HTML">&lt;html&gt;&lt;head&gt;&lt;style&gt;p{color:red}&lt;/style&gt;&lt;/head&gt;            &lt;body&gt;&lt;p&gt;Fish &amp;amp; chips&lt;/p&gt;&lt;p&gt;Bye&lt;/p&gt;&lt;/body&gt;&lt;/html&gt;</t:Body></t:Message>
            """)
        let b = EWSBackend.parseBody(try #require(d.first("Message")))
        #expect(b.html != nil)
        #expect(b.text == "Fish & chips\nBye")
    }

    @Test func plainTextBodyHasNoHTML() throws {
        let d = try doc(#"<t:Message><t:ItemId Id="ID1"/><t:Body BodyType="Text">Hi there</t:Body></t:Message>"#)
        let b = EWSBackend.parseBody(try #require(d.first("Message")))
        #expect(b.html == nil)
        #expect(b.text == "Hi there")
    }

    @Test func bodyRequestAsksForBestBodyAndTextBody() throws {
        let d = try request(EWSBackend.bodyRequest("ID&1"))
        #expect(d.text("BodyType") == "Best")
        let fields = (d.first("AdditionalProperties")?.children("FieldURI") ?? []).compactMap { $0.attr("FieldURI") }
        #expect(fields.contains("item:Body") && fields.contains("item:TextBody"))
        #expect(d.first("ItemId")?.attr("Id") == "ID&1")
    }

    @Test func inlineImagesAreTheReferencedImageAttachments() throws {
        let d = try doc("""
            <t:Message><t:ItemId Id="ID1"/><t:Attachments>
            <t:FileAttachment><t:AttachmentId Id="A1"/><t:Name>image001.png</t:Name><t:ContentType>image/png</t:ContentType>\
            <t:ContentId>image001.png@01DA</t:ContentId><t:IsInline>true</t:IsInline></t:FileAttachment>
            <t:FileAttachment><t:AttachmentId Id="A2"/><t:Name>logo.gif</t:Name><t:ContentType>image/gif</t:ContentType>\
            <t:ContentId>&lt;logo@x&gt;</t:ContentId><t:IsInline>false</t:IsInline></t:FileAttachment>
            <t:FileAttachment><t:AttachmentId Id="A3"/><t:Name>unused.png</t:Name><t:ContentType>image/png</t:ContentType>\
            <t:ContentId>unused@x</t:ContentId></t:FileAttachment>
            <t:FileAttachment><t:AttachmentId Id="A4"/><t:Name>run.sh</t:Name><t:ContentType>text/x-sh</t:ContentType>\
            <t:ContentId>script@x</t:ContentId></t:FileAttachment>
            <t:FileAttachment><t:AttachmentId Id="A5"/><t:Name>report.pdf</t:Name><t:ContentType>application/pdf</t:ContentType></t:FileAttachment>
            </t:Attachments></t:Message>
            """)
        let item = try #require(d.first("Message"))
        let wanted: Set = ["image001.png@01DA", "logo@x", "script@x"]
        #expect(EWSBackend.inlineAttachmentIDs(item, wanted: wanted) == ["A1", "A2"])
    }

    /// Some mailers send pictures in the text as `application/octet-stream` or without a type: referenced by the
    /// HTML, they are fetched too, and get their type from the file name.
    @Test func inlineImagesWithAGenericContentTypeAreFetched() throws {
        let d = try doc("""
            <t:Message><t:Attachments>
            <t:FileAttachment><t:AttachmentId Id="A1"/><t:Name>image001.png</t:Name>\
            <t:ContentType>application/octet-stream</t:ContentType><t:ContentId>image001.png@01D</t:ContentId></t:FileAttachment>
            <t:FileAttachment><t:AttachmentId Id="A2"/><t:Name>photo.JPG</t:Name><t:ContentId>photo@x</t:ContentId></t:FileAttachment>
            <t:FileAttachment><t:AttachmentId Id="A3"/><t:Name>notes.txt</t:Name><t:ContentType>text/plain</t:ContentType>\
            <t:ContentId>notes@x</t:ContentId></t:FileAttachment>
            </t:Attachments></t:Message>
            """)
        let item = try #require(d.first("Message"))
        #expect(EWSBackend.inlineAttachmentIDs(item, wanted: ["image001.png@01D", "photo@x", "notes@x"]) == ["A1", "A2"])

        let content = try doc("""
            <m:GetAttachmentResponse><m:ResponseMessages><m:GetAttachmentResponseMessage ResponseClass="Success"><m:Attachments>
            <t:FileAttachment><t:Name>image001.png</t:Name><t:ContentType>application/octet-stream</t:ContentType>\
            <t:ContentId>image001.png@01D</t:ContentId><t:Content>AQID</t:Content></t:FileAttachment>
            <t:FileAttachment><t:Name>photo.JPG</t:Name><t:ContentId>photo@x</t:ContentId><t:Content>BAU=</t:Content></t:FileAttachment>
            <t:FileAttachment><t:Name>blob</t:Name><t:ContentId>blob@x</t:ContentId><t:Content>Bg==</t:Content></t:FileAttachment>
            </m:Attachments></m:GetAttachmentResponseMessage></m:ResponseMessages></m:GetAttachmentResponse>
            """)
        let images = EWSBackend.parseInlineImages(content)
        #expect(images["image001.png@01D"] == InlineImage(contentType: "image/png", data: Data([1, 2, 3])))
        #expect(images["photo@x"] == InlineImage(contentType: "image/jpeg", data: Data([4, 5])))
        #expect(images["blob@x"] == InlineImage(contentType: "application/octet-stream", data: Data([6])))
    }

    @Test func attachmentRequestAndContent() throws {
        let req = try request(EWSBackend.attachmentRequest(["A&1", "A2"]))
        #expect(req.first("GetAttachment")?.elementChildren.map(\.localName) == ["AttachmentShape", "AttachmentIds"])
        #expect(req.first("AttachmentIds")?.children("AttachmentId").compactMap { $0.attr("Id") } == ["A&1", "A2"])
        let d = try doc("""
            <m:GetAttachmentResponse><m:ResponseMessages>
            <m:GetAttachmentResponseMessage ResponseClass="Success"><m:ResponseCode>NoError</m:ResponseCode><m:Attachments>
            <t:FileAttachment><t:AttachmentId Id="A1"/><t:Name>image001.png</t:Name><t:ContentType>image/png</t:ContentType>\
            <t:ContentId>&lt;image001.png@01DA&gt;</t:ContentId><t:Content>AQID</t:Content></t:FileAttachment>
            </m:Attachments></m:GetAttachmentResponseMessage>
            <m:GetAttachmentResponseMessage ResponseClass="Error"><m:MessageText>Gone</m:MessageText>\
            <m:ResponseCode>ErrorItemNotFound</m:ResponseCode></m:GetAttachmentResponseMessage>
            </m:ResponseMessages></m:GetAttachmentResponse>
            """)
        #expect(EWSBackend.parseInlineImages(d) == ["image001.png@01DA": InlineImage(contentType: "image/png", data: Data([1, 2, 3]))])
    }

    /// Attached files with their size and type; an attached message becomes a .eml file, as in Mail.
    @Test func bodyListsAttachmentsWithSizeTypeAndAttachedMessagesAsEml() throws {
        let d = try doc("""
            <t:Message><t:ItemId Id="ID1"/><t:Body BodyType="Text">Hi</t:Body><t:Attachments>
            <t:FileAttachment><t:AttachmentId Id="A1"/><t:Name>report.pdf</t:Name><t:ContentType>application/pdf</t:ContentType>\
            <t:Size>2048</t:Size><t:IsInline>false</t:IsInline></t:FileAttachment>
            <t:FileAttachment><t:AttachmentId Id="A2"/><t:Name>image001.png</t:Name><t:IsInline>true</t:IsInline></t:FileAttachment>
            <t:ItemAttachment><t:AttachmentId Id="A3"/><t:Name>Re: Budget</t:Name><t:Size>900</t:Size></t:ItemAttachment>
            </t:Attachments></t:Message>
            """)
        let item = try #require(d.first("Message"))
        #expect(EWSBackend.parseBody(item).attachments == [
            MailModel.Attachment(name: "report.pdf", size: 2048, contentType: "application/pdf"),
            MailModel.Attachment(name: "Re: Budget.eml", size: 900, contentType: "message/rfc822"),
        ])
        // The same list, in the same order, gives the IDs to fetch them by position.
        #expect(EWSBackend.listedAttachments(item).map(\.id) == ["A1", "A3"])
    }

    @Test func attachmentContentAsksForMimeAndReadsFilesAndMessages() throws {
        let req = try request(EWSBackend.attachmentContentRequest("A&1"))
        #expect(req.first("IncludeMimeContent")?.stringValue == "true")
        #expect(req.first("AttachmentId")?.attr("Id") == "A&1")
        let file = try doc("""
            <m:GetAttachmentResponse><m:ResponseMessages><m:GetAttachmentResponseMessage ResponseClass="Success">\
            <m:Attachments><t:FileAttachment><t:Name>a.pdf</t:Name><t:Content>AQID</t:Content></t:FileAttachment>\
            </m:Attachments></m:GetAttachmentResponseMessage></m:ResponseMessages></m:GetAttachmentResponse>
            """)
        #expect(EWSBackend.parseAttachmentContent(file) == Data([1, 2, 3]))
        let message = try doc("""
            <m:GetAttachmentResponse><m:ResponseMessages><m:GetAttachmentResponseMessage ResponseClass="Success">\
            <m:Attachments><t:ItemAttachment><t:Message><t:MimeContent CharacterSet="UTF-8">BAU=</t:MimeContent>\
            </t:Message></t:ItemAttachment></m:Attachments></m:GetAttachmentResponseMessage></m:ResponseMessages>\
            </m:GetAttachmentResponse>
            """)
        #expect(EWSBackend.parseAttachmentContent(message) == Data([4, 5]))
    }

    /// An attached message that itself carries files or messages: its own MIME source, not a nested one's content.
    @Test func attachedMessageContentIsItsOwnMimeNotANestedAttachment() throws {
        let d = try doc("""
            <m:GetAttachmentResponse><m:ResponseMessages><m:GetAttachmentResponseMessage ResponseClass="Success">
            <m:ResponseCode>NoError</m:ResponseCode><m:Attachments><t:ItemAttachment><t:AttachmentId Id="A"/><t:Name>Mail</t:Name>
            <t:Message><t:ItemId Id="X"/>
            <t:Attachments><t:FileAttachment><t:AttachmentId Id="N"/><t:Name>n.txt</t:Name><t:Content>TkVTVEVE</t:Content></t:FileAttachment>
            <t:ItemAttachment><t:Message><t:MimeContent>SU5ORVI=</t:MimeContent></t:Message></t:ItemAttachment></t:Attachments>
            <t:MimeContent CharacterSet="UTF-8">TUlNRQ==</t:MimeContent>
            </t:Message></t:ItemAttachment></m:Attachments></m:GetAttachmentResponseMessage></m:ResponseMessages></m:GetAttachmentResponse>
            """)
        #expect(EWSBackend.parseAttachmentContent(d) == Data("MIME".utf8))
    }

    @Test func archiveFolderFoundByLocalizedName() throws {
        let d = try doc("""
            <m:Folders><t:Folder><t:FolderId Id="F1"/><t:DisplayName>Posteingang</t:DisplayName></t:Folder>
            <t:Folder><t:FolderId Id="F2"/><t:DisplayName>Archiv</t:DisplayName><t:TotalCount>30</t:TotalCount></t:Folder></m:Folders>
            """)
        #expect(EWSBackend.archiveFolder(d.all("Folder")) == RemoteFolder(role: .archive, id: "F2", totalCount: 30))
    }

    @Test func folderTreeKeepsMailFoldersNestedUnderTheirParents() throws {
        func f(_ id: String, _ name: String, parent: String, cls: String? = "IPF.Note", tag: String = "Folder",
               hidden: Bool = false) -> String {
            "<t:\(tag)><t:FolderId Id=\"\(id)\"/><t:ParentFolderId Id=\"\(parent)\"/>"
                + (cls.map { "<t:FolderClass>\($0)</t:FolderClass>" } ?? "")
                + "<t:DisplayName>\(name)</t:DisplayName><t:TotalCount>3</t:TotalCount>"
                + (hidden ? #"<t:ExtendedProperty><t:ExtendedFieldURI PropertyTag="0x10f4" PropertyType="Boolean"/><t:Value>true</t:Value></t:ExtendedProperty>"# : "")
                + "</t:\(tag)>"
        }
        let d = try doc("<m:FindFolderResponse><m:RootFolder><t:Folders>"
            + f("I", "Inbox", parent: "R") + f("L", "Launch", parent: "P") + f("P", "Projects", parent: "I")
            + f("CAL", "Calendar", parent: "R", cls: "IPF.Appointment", tag: "CalendarFolder")
            + f("H", "Hidden", parent: "R", hidden: true) + f("HC", "Under hidden", parent: "H")
            + f("RSS", "RSS Feeds", parent: "R", cls: "IPF.Note.OutlookHomepage")
            + f("O", "Outbox", parent: "R") + f("C", "Clients", parent: "R", cls: nil) + f("AR", "Archive", parent: "R")
            + "</t:Folders></m:RootFolder></m:FindFolderResponse>")
        let known = [RemoteFolder(role: .inbox, id: "I"), RemoteFolder(role: .archive, id: "AR")]
        #expect(EWSBackend.folderTree(d.all("Folder"), known: known, skip: ["O"]) == [
            RemoteFolder(role: .folder("L"), id: "L", totalCount: 3, name: "Launch", parent: .folder("P")),
            RemoteFolder(role: .folder("P"), id: "P", totalCount: 3, name: "Projects", parent: .inbox),
            RemoteFolder(role: .folder("C"), id: "C", totalCount: 3, name: "Clients", parent: nil),
        ])
    }

    /// Exchange returns at most 1000 folders per FindFolder; a mailbox with more is read page by page.
    @Test func folderListContinuesUntilTheLastPage() throws {
        let more = try doc(#"<m:FindFolderResponse><m:RootFolder IndexedPagingOffset="1000" TotalItemsInView="1232" IncludesLastItemInRange="false"/></m:FindFolderResponse>"#)
        let last = try doc(#"<m:FindFolderResponse><m:RootFolder IndexedPagingOffset="1232" TotalItemsInView="1232" IncludesLastItemInRange="true"/></m:FindFolderResponse>"#)
        #expect(EWSBackend.nextFolderOffset(more) == 1000)
        #expect(EWSBackend.nextFolderOffset(last) == nil)
        #expect(EWSBackend.findFoldersRequest(offset: 1000).contains(#"<m:IndexedPageFolderView MaxEntriesReturned="1000" Offset="1000" BasePoint="Beginning"/>"#))
    }

    @Test func archiveFolderPrefersTheTopLevelOne() throws {
        let d = try doc("""
            <m:Folders><t:Folder><t:FolderId Id="SUB"/><t:ParentFolderId Id="I"/><t:DisplayName>Archive</t:DisplayName></t:Folder>
            <t:Folder><t:FolderId Id="I"/><t:ParentFolderId Id="R"/><t:DisplayName>Inbox</t:DisplayName></t:Folder>
            <t:Folder><t:FolderId Id="TOP"/><t:ParentFolderId Id="R"/><t:DisplayName>Archive</t:DisplayName></t:Folder></m:Folders>
            """)
        #expect(EWSBackend.archiveFolder(d.all("Folder"))?.id == "TOP")
    }

    @Test func getFolderSkipsMissingFolders() throws {
        let ok = #"<m:GetFolderResponseMessage ResponseClass="Success"><m:Folders><t:Folder><t:FolderId Id="X"/><t:TotalCount>7</t:TotalCount></t:Folder></m:Folders></m:GetFolderResponseMessage>"#
        let bad = #"<m:GetFolderResponseMessage ResponseClass="Error"><m:ResponseCode>ErrorFolderNotFound</m:ResponseCode></m:GetFolderResponseMessage>"#
        let d = try doc("<m:GetFolderResponse><m:ResponseMessages>" + ok + bad + ok + ok + ok + "</m:ResponseMessages></m:GetFolderResponse>")
        #expect(EWSBackend.parseGetFolder(d).map(\.role) == [.inbox, .sent, .junk, .trash])
        #expect(EWSBackend.parseGetFolder(d).allSatisfy { $0.totalCount == 7 })
    }

    @Test func serverFieldAcceptsHostOrURL() {
        #expect(ExchangeAccount(email: "", username: "", server: "mail.example.com").ewsURL?.absoluteString
                == "https://mail.example.com/EWS/Exchange.asmx")
        #expect(ExchangeAccount(email: "", username: "", server: "https://x.example.com/EWS/Exchange.asmx").ewsURL?.host
                == "x.example.com")
    }

    /// Whatever form the server is typed or pasted in, the URL is the same; http is upgraded, blank is invalid.
    @Test func serverFieldIsNormalised() {
        let url = { ExchangeAccount(email: "", username: "", server: $0).ewsURL?.absoluteString }
        let standard = "https://mail.example.com/EWS/Exchange.asmx"
        for s in ["mail.example.com", " mail.example.com\n", "mail.example.com/", "mail.example.com/EWS/Exchange.asmx",
                  "mail.example.com/ews/exchange.asmx/", "http://mail.example.com/EWS/Exchange.asmx", "HTTP://mail.example.com",
                  "https://mail.example.com/EWS/Exchange.asmx\n", "\thttps://mail.example.com/\r\n", "HTTPS://mail.example.com"] {
            #expect(url(s) == standard, "\(s.debugDescription)")
        }
        #expect(url("mail.example.com:8443") == "https://mail.example.com:8443/EWS/Exchange.asmx")
        #expect(url("https://mail.example.com/proxy/EWS/Exchange.asmx") == "https://mail.example.com/proxy/EWS/Exchange.asmx")
        #expect(url("https://mail.example.com/ews/Other.asmx") == "https://mail.example.com/ews/Other.asmx")
        for s in ["", "   ", "\n", "https://", "http:// ", "/EWS/Exchange.asmx", "mail example.com"] {
            #expect(url(s) == nil, "\(s.debugDescription)")
        }
    }

    @Test func controlCharacterReferencesDontBreakParsing() throws {
        let raw = "<a><s>x&#8;y&#x1F;z&#X0b;&#9;&#10;&#13;&#32;&amp;#8;</s></a>"
        #expect((try? XMLDocument(data: Data(raw.utf8))) == nil)
        let d = try XMLDocument(data: EWSClient.sanitize(Data(raw.utf8)))
        #expect(d.text("s") == "x\u{FFFD}y\u{FFFD}z\u{FFFD}\t\n\r &#8;")
    }

    /// U+FFFE, U+FFFF and surrogates are just as illegal in XML 1.0 as C0 controls, in hex or decimal form.
    @Test func nonCharacterReferencesDontBreakParsing() throws {
        for ref in ["&#xFFFE;", "&#xFFFF;", "&#65534;", "&#65535;", "&#xD800;", "&#xdfff;", "&#55296;", "&#57343;",
                    "&#x110000;", "&#99999999999999999999;"] {
            let raw = "<a><s>x\(ref)y</s></a>"
            let d = try? XMLDocument(data: EWSClient.sanitize(Data(raw.utf8)))
            #expect(d?.text("s") == "x\u{FFFD}y", "\(ref) fails the page")
        }
        // Valid references next to them are kept.
        let d = try XMLDocument(data: EWSClient.sanitize(Data("<a><s>&#xD7FF;&#xFFFE;&#xE000;&#xFFFD;&#x10000;</s></a>".utf8)))
        #expect(d.text("s") == "\u{D7FF}\u{FFFD}\u{E000}\u{FFFD}\u{10000}")
    }

    /// Text pasted from Word or a PDF can carry form feeds or vertical tabs, which XML 1.0 forbids: they are left
    /// out of requests, so Send, Save and invite answers still work. Tab, line feed and carriage return stay.
    @Test func charactersXMLForbidsAreLeftOutOfRequests() throws {
        let forbidden = (0...0x1F).filter { ![0x9, 0xA, 0xD].contains($0) } + [0xFFFE, 0xFFFF]
        for v in forbidden {
            let c = String(Character(Unicode.Scalar(v)!))
            let draft = Draft(accountID: UUID(), to: "a@x.com", subject: "S\(c)ubject", body: "line\(c)break\ttab\nnext")
            let xml = try #require(try? request(EWSBackend.createRequest(draft, send: true)),
                                   "U+\(String(v, radix: 16)) breaks the request")
            #expect(xml.text("Subject") == "Subject")
            #expect(xml.first("Items")?.text("Body") == "linebreak\ttab\nnext")
            #expect(xmlEscape("a\(c)\tb\r\nc") == "a\tb\r\nc")
            let files = [DraftAttachment(name: "scan\(c)1.pdf", contentType: "application/pdf", data: Data([1]))]
            #expect(try request(EWSBackend.createAttachmentRequest(parentID: "I", files)).text("Name") == "scan1.pdf")
            let reply = InviteReply(response: .decline, comment: "sorry\(c) next week")
            #expect(try request(EWSBackend.respondRequest("M", reply)).first("Items")?.text("Body") == "sorry next week")
        }
    }

    @Test func rejectedPasswordIsASignInFailureNotOffline() {
        #expect(EWSClient.mapError(URLError(.cancelled), credentialsRejected: true) is AuthenticationError)
        #expect(EWSClient.mapError(URLError(.cancelled), credentialsRejected: false) is URLError)
        #expect(EWSClient.mapError(URLError(.notConnectedToInternet), credentialsRejected: true) is URLError)
    }

    /// A cancellation ("Abgesagt: …") carries the meeting too, marked as cancelled; Outlook offers only Remove from Calendar.
    @Test func meetingCancellationIsMarkedAndRemovedWithRemoveItem() throws {
        let d = try doc("""
            <t:MeetingCancellation><t:ItemId Id="C1"/><t:Body BodyType="Text">Sorry</t:Body>
            <t:Start>2026-11-13T09:00:00Z</t:Start><t:End>2026-11-13T10:00:00Z</t:End></t:MeetingCancellation>
            """)
        let item = try #require(d.first("MeetingCancellation"))
        #expect(EWSBackend.parseBody(item).invite?.isCancellation == true)
        #expect(EWSBackend.message(item)?.isInvite == true)
        let request = try #require(try doc(summary).first("Message"))
        #expect(EWSBackend.parseBody(request).invite == nil)
        #expect(EWSBackend.removeFromCalendarRequest("C&1") == #"<m:CreateItem MessageDisposition="SaveOnly"><m:Items>"#
            + #"<t:RemoveItem><t:ReferenceItemId Id="C&amp;1"/></t:RemoveItem></m:Items></m:CreateItem>"#)
    }

    @Test func meetingRequestBodyCarriesTheInvite() throws {
        let d = try doc("""
            <t:MeetingRequest><t:ItemId Id="M1"/><t:Body BodyType="Text">Agenda</t:Body>
            <t:Start>2026-11-23T11:30:00Z</t:Start><t:End>2026-11-23T12:00:00Z</t:End><t:Location>Room 2.33</t:Location>
            <t:Organizer><t:Mailbox><t:Name>Org</t:Name><t:EmailAddress>org@x.com</t:EmailAddress></t:Mailbox></t:Organizer>
            <t:RequiredAttendees><t:Attendee><t:Mailbox><t:Name>Ann</t:Name><t:EmailAddress>ann@x.com</t:EmailAddress></t:Mailbox>
            <t:ResponseType>Unknown</t:ResponseType></t:Attendee></t:RequiredAttendees>
            <t:OptionalAttendees><t:Attendee><t:Mailbox><t:Name>Bob</t:Name><t:EmailAddress>bob@x.com</t:EmailAddress></t:Mailbox>
            </t:Attendee></t:OptionalAttendees><t:ConflictingMeetingCount>2</t:ConflictingMeetingCount></t:MeetingRequest>
            """)
        let item = try #require(d.first("MeetingRequest"))
        let invite = try #require(EWSBackend.parseBody(item).invite)
        #expect(invite.start == ISO8601DateFormatter().date(from: "2026-11-23T11:30:00Z"))
        #expect(invite.end.timeIntervalSince(invite.start) == 1800)
        #expect(invite.location == "Room 2.33")
        #expect(invite.organizer?.email == "org@x.com")
        #expect(invite.required.map(\.name) == ["Ann"])
        #expect(invite.optional.map(\.name) == ["Bob"])
        #expect(!invite.isAllDay)
        #expect(invite.isCancellation == false)
        #expect(EWSBackend.message(item)?.isInvite == true)
        let plain = try #require(try doc(summary).first("Message"))
        #expect(EWSBackend.parseBody(plain).invite == nil)
        #expect(EWSBackend.message(plain)?.isInvite == false)
    }

    @Test func calendarViewEvents() throws {
        let d = try doc("""
            <m:Items><t:CalendarItem><t:ItemId Id="C1"/><t:Subject>Standup</t:Subject><t:Start>2026-11-23T08:00:00Z</t:Start>
            <t:End>2026-11-23T08:15:00Z</t:End><t:IsAllDayEvent>false</t:IsAllDayEvent><t:LegacyFreeBusyStatus>Tentative</t:LegacyFreeBusyStatus></t:CalendarItem>
            <t:CalendarItem><t:ItemId Id="C2"/><t:Subject>Holiday</t:Subject><t:Start>2026-11-23T00:00:00Z</t:Start>
            <t:End>2026-11-24T00:00:00Z</t:End><t:IsAllDayEvent>true</t:IsAllDayEvent><t:LegacyFreeBusyStatus>Free</t:LegacyFreeBusyStatus></t:CalendarItem></m:Items>
            """)
        let e = EWSBackend.parseEvents(d)
        #expect(e.map(\.subject) == ["Standup", "Holiday"])
        #expect(e.map(\.busy) == [.tentative, .free])
        #expect(e.map(\.isAllDay) == [false, true])
    }

    /// xs:dateTime allows fractional seconds and no zone; without a zone the time is read as UTC (EWS's default).
    @Test func datesWithFractionalSecondsOrWithoutZoneAreRead() throws {
        let utc = { ISO8601DateFormatter().date(from: $0)! }
        let received = try doc("""
            <t:Message><t:ItemId Id="ID1"/><t:DateTimeReceived>2026-11-10T09:30:00.123Z</t:DateTimeReceived></t:Message>
            """)
        let m = try #require(EWSBackend.message(received.first("Message")!))
        #expect(abs(m.date.timeIntervalSince(utc("2026-11-10T09:30:00Z")) - 0.123) < 0.001)

        let invite = try doc("""
            <t:MeetingRequest><t:ItemId Id="M1"/><t:Body BodyType="Text">x</t:Body>
            <t:Start>2026-11-23T11:30:00</t:Start><t:End>2026-11-23T12:00:00.5</t:End></t:MeetingRequest>
            """)
        let i = try #require(EWSBackend.parseBody(invite.first("MeetingRequest")!).invite)
        #expect(i.start == utc("2026-11-23T11:30:00Z"))
        #expect(abs(i.end.timeIntervalSince(utc("2026-11-23T12:00:00Z")) - 0.5) < 0.001)

        let events = try doc("""
            <m:Items><t:CalendarItem><t:ItemId Id="C1"/><t:Subject>S</t:Subject><t:Start>2026-11-23T08:00:00.000Z</t:Start>
            <t:End>2026-11-23T09:15:00.000+01:00</t:End></t:CalendarItem></m:Items>
            """)
        let e = EWSBackend.parseEvents(events)
        #expect(e.count == 1)
        #expect(e.first?.end == utc("2026-11-23T08:15:00Z"))
    }

    @Test func calendarViewRequestAsksForOneDay() throws {
        let from = ISO8601DateFormatter().date(from: "2026-11-23T00:00:00Z")!
        let d = try request(EWSBackend.calendarViewRequest(from: from, to: from.addingTimeInterval(86400)))
        let view = try #require(d.first("CalendarView"))
        #expect(view.attr("StartDate") == "2026-11-23T00:00:00Z")
        #expect(view.attr("EndDate") == "2026-11-24T00:00:00Z")
        #expect(d.first("DistinguishedFolderId")?.attr("Id") == "calendar")
    }

    @Test func inviteAnswersAreSentToTheOrganizer() throws {
        for (r, tag) in [(InviteResponse.accept, "AcceptItem"), (.tentative, "TentativelyAcceptItem"), (.decline, "DeclineItem")] {
            let d = try request(EWSBackend.respondRequest("M&1", InviteReply(response: r)))
            #expect(d.first("CreateItem")?.attr("MessageDisposition") == "SendAndSaveCopy")
            #expect(d.first(tag)?.child("ReferenceItemId")?.attr("Id") == "M&1")
        }
    }

    @Test func answerOptionsInSchemaOrder() throws {
        let f = ISO8601DateFormatter()
        let reply = InviteReply(response: .decline, comment: "Clash <again>", proposedStart: f.date(from: "2026-11-23T13:00:00Z"),
                                proposedEnd: f.date(from: "2026-11-23T13:30:00Z"))
        let d = try request(EWSBackend.respondRequest("M", reply))
        let item = try #require(d.first("DeclineItem"))
        #expect(item.elementChildren.map(\.localName) == ["Body", "ReferenceItemId", "ProposedStart", "ProposedEnd"])
        #expect(item.text("Body") == "Clash <again>")
        #expect(item.text("ProposedStart") == "2026-11-23T13:00:00Z")
        #expect(d.first("CreateItem")?.attr("MessageDisposition") == "SendAndSaveCopy")
        let quiet = try request(EWSBackend.respondRequest("M", InviteReply(response: .accept, send: false)))
        #expect(quiet.first("CreateItem")?.attr("MessageDisposition") == "SaveOnly")
        #expect(quiet.first("AcceptItem")?.elementChildren.map(\.localName) == ["ReferenceItemId"])
    }

    // MARK: Write requests

    /// Parses a request as the server would, to check its structure.
    func request(_ body: String) throws -> XMLDocument { try XMLDocument(xmlString: EWSClient.envelope(body)) }

    @Test func markReadSuppressesReadReceiptsAndOverwrites() throws {
        let d = try request(EWSBackend.updateRequest(["A", "B&"], field: "message:IsRead",
                                                     value: "<t:IsRead>true</t:IsRead>"))
        let update = try #require(d.first("UpdateItem"))
        #expect(update.attr("SuppressReadReceipts") == "true")
        #expect(update.attr("ConflictResolution") == "AlwaysOverwrite")
        #expect(update.attr("MessageDisposition") == "SaveOnly")
        #expect(d.all("ItemChange").compactMap { $0.child("ItemId")?.attr("Id") } == ["A", "B&"])
        #expect(d.all("SetItemField").allSatisfy { $0.child("FieldURI")?.attr("FieldURI") == "message:IsRead" })
        #expect(d.all("IsRead").map(\.stringValue) == ["true", "true"])
    }

    @Test func flagRequestSetsFlagStatus() throws {
        let d = try request(EWSBackend.flagRequest(["A"], flagged: false))
        #expect(d.first("FieldURI")?.attr("FieldURI") == "item:Flag")
        #expect(d.text("FlagStatus") == "NotFlagged")
    }

    @Test func moveRequestAsksForNewIDsAfterItemIDs() throws {
        let d = try request(EWSBackend.moveRequest(["A"], to: "F"))
        let move = try #require(d.first("MoveItem"))
        #expect(move.elementChildren.map(\.localName) == ["ToFolderId", "ItemIds", "ReturnNewItemIds"])
        #expect(move.first("FolderId")?.attr("Id") == "F")
        #expect(d.text("ReturnNewItemIds") == "true")
    }

    @Test func moveResponseMapsOldToNewIDs() throws {
        let item = { (id: String) in
            "<m:MoveItemResponseMessage ResponseClass=\"Success\"><m:ResponseCode>NoError</m:ResponseCode><m:Items><t:Message><t:ItemId Id=\"\(id)\" ChangeKey=\"K\"/></t:Message></m:Items></m:MoveItemResponseMessage>"
        }
        let d = try doc("<m:MoveItemResponse><m:ResponseMessages>" + item("N1") + item("N2") + "</m:ResponseMessages></m:MoveItemResponse>")
        #expect(EWSBackend.parseMove(d, ids: ["A", "B"]) == ["A": "N1", "B": "N2"])
    }

    @Test func deleteIsRecoverable() throws {
        let d = try request(EWSBackend.deleteRequest(["A"]))
        #expect(d.first("DeleteItem")?.attr("DeleteType") == "SoftDelete")
    }

    @Test func createRequestSendsOrSavesInSchemaOrder() throws {
        let draft = Draft(accountID: UUID(), to: "Ann <ann@x.com>, bob@x.com", cc: "c@x.com", subject: "S <1>", body: "B & C")
        let sent = try request(EWSBackend.createRequest(draft, send: true))
        let create = try #require(sent.first("CreateItem"))
        #expect(create.attr("MessageDisposition") == "SendAndSaveCopy")
        #expect(create.first("SavedItemFolderId")?.first("DistinguishedFolderId")?.attr("Id") == "sentitems")
        let msg = try #require(sent.first("Message"))
        #expect(msg.elementChildren.map(\.localName) == ["Subject", "Body", "ToRecipients", "CcRecipients"])
        #expect(msg.text("Subject") == "S <1>")
        #expect(msg.text("Body") == "B & C")
        #expect(msg.child("ToRecipients")?.all("EmailAddress").map(\.stringValue) == ["ann@x.com", "bob@x.com"])
        let saved = try request(EWSBackend.createRequest(draft, send: false))
        #expect(saved.first("CreateItem")?.attr("MessageDisposition") == "SaveOnly")
        #expect(saved.first("DistinguishedFolderId")?.attr("Id") == "drafts")
    }

    /// The marks for files placed in the text aren't sent.
    @Test func createRequestLeavesOutTheFileMarks() throws {
        let draft = Draft(accountID: UUID(), to: "a@x.com", body: "Hi\u{FFFC} there")
        #expect(try request(EWSBackend.createRequest(draft, send: true)).first("Message")?.text("Body") == "Hi there")
    }

    /// Pictures placed in the text go out in their place: an HTML body pointing at inline attachments by content ID.
    /// Other files stay ordinary attachments.
    @Test func picturesInTheTextGoOutInline() throws {
        var draft = Draft(accountID: UUID(), to: "a@x.com", body: "Look <here>:\n\u{FFFC}\n\nand \u{FFFC} bye")
        draft.attachments = [DraftAttachment(name: "p.jpg", contentType: "image/jpeg", data: Data([1])),
                             DraftAttachment(name: "d.pdf", contentType: "application/pdf", data: Data([2]))]
        let ids = EWSBackend.contentIDs(draft)
        #expect(Array(ids.keys) == [0])
        let cid = try #require(ids[0])
        let msg = try #require(try request(EWSBackend.createRequest(draft, send: false, contentIDs: ids)).first("Message"))
        #expect(msg.child("Body")?.attr("BodyType") == "HTML")
        let html = try #require(msg.text("Body"))
        #expect(html.contains("<div>Look &lt;here&gt;:</div>"))
        #expect(html.contains("<img src=\"cid:\(cid)\""))
        #expect(html.contains("<div><br></div>"))
        #expect(html.contains("<div>and  bye</div>"))
        #expect(!html.contains("\u{FFFC}"))

        let add = try request(EWSBackend.createAttachmentRequest(parentID: "I1", draft.attachments, contentIDs: ids))
        let files = add.all("FileAttachment")
        #expect(files[0].elementChildren.map(\.localName) == ["Name", "ContentType", "ContentId", "IsInline", "Content"])
        #expect(files[0].text("ContentId") == cid)
        #expect(files[0].text("IsInline") == "true")
        #expect(files[1].elementChildren.map(\.localName) == ["Name", "ContentType", "Content"])

        // A HEIC photo few clients can draw goes as a file.
        draft.attachments[0].contentType = "image/heic"
        #expect(EWSBackend.contentIDs(draft).isEmpty)
        draft.attachments[0].contentType = "image/jpeg"

        // Without a picture in the text the body stays plain text.
        draft.attachments.swapAt(0, 1)
        draft.attachments[1].contentType = "application/zip"
        #expect(EWSBackend.contentIDs(draft).isEmpty)
        #expect(try request(EWSBackend.createRequest(draft, send: false)).first("Message")?.child("Body")?.attr("BodyType") == "Text")
    }

    /// With files, a message is created in Drafts, the files are added, and then it is sent.
    @Test func attachmentsAreAddedToTheSavedItemThenItIsSent() throws {
        let files = [DraftAttachment(name: "a & b.pdf", contentType: "application/pdf", data: Data([1, 2, 3]))]
        let add = try request(EWSBackend.createAttachmentRequest(parentID: "I&1", files))
        #expect(add.first("ParentItemId")?.attr("Id") == "I&1")
        let file = try #require(add.first("FileAttachment"))
        #expect(file.elementChildren.map(\.localName) == ["Name", "ContentType", "Content"])
        #expect(file.text("Name") == "a & b.pdf")
        #expect(file.text("Content") == "AQID")
        let created = try doc("""
            <m:CreateAttachmentResponse><m:ResponseMessages><m:CreateAttachmentResponseMessage ResponseClass="Success">\
            <m:Attachments><t:FileAttachment><t:AttachmentId Id="A1" RootItemId="I1" RootItemChangeKey="CK2"/>\
            </t:FileAttachment></m:Attachments></m:CreateAttachmentResponseMessage></m:ResponseMessages></m:CreateAttachmentResponse>
            """)
        #expect(EWSBackend.parseRootItem(created) == EWSBackend.ItemRef(id: "I1", changeKey: "CK2"))
        let saved = try doc("""
            <m:CreateItemResponse><m:ResponseMessages><m:CreateItemResponseMessage ResponseClass="Success">\
            <m:Items><t:Message><t:ItemId Id="I1" ChangeKey="CK1"/></t:Message></m:Items>\
            </m:CreateItemResponseMessage></m:ResponseMessages></m:CreateItemResponse>
            """)
        #expect(EWSBackend.parseCreatedItem(saved) == EWSBackend.ItemRef(id: "I1", changeKey: "CK1"))
        let send = try request(EWSBackend.sendItemRequest(EWSBackend.ItemRef(id: "I1", changeKey: "CK2")))
        #expect(send.first("SendItem")?.attr("SaveItemToFolder") == "true")
        #expect(send.first("ItemId")?.attr("ChangeKey") == "CK2")
        #expect(send.first("SavedItemFolderId")?.first("DistinguishedFolderId")?.attr("Id") == "sentitems")
    }

    /// Outlook's limit for the sender: MailTips' MaxMessageSize.
    @Test func maxMessageSizeFromMailTips() throws {
        let req = try request(EWSBackend.mailTipsRequest(from: "me@x.com"))
        #expect(req.first("SendingAs")?.text("EmailAddress") == "me@x.com")
        #expect(req.first("Recipients")?.first("EmailAddress")?.stringValue == "me@x.com")
        #expect(req.first("MailTipsRequested")?.stringValue == "MaxMessageSize")
        let d = try doc("""
            <m:GetMailTipsResponse ResponseClass="Success"><m:ResponseMessages><m:MailTipsResponseMessageType ResponseClass="Success">\
            <m:MailTips><t:RecipientAddress><t:EmailAddress>me@x.com</t:EmailAddress></t:RecipientAddress>\
            <t:MaxMessageSize>36700160</t:MaxMessageSize></m:MailTips></m:MailTipsResponseMessageType></m:ResponseMessages>\
            </m:GetMailTipsResponse>
            """)
        #expect(EWSBackend.parseMaxMessageSize(d) == 36_700_160)
    }
}
