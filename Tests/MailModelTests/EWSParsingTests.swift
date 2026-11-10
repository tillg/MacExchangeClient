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
        <t:From><t:Mailbox><t:Name>Carol</t:Name></t:Mailbox></t:From></t:Message>
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

    @Test func archiveFolderFoundByLocalizedName() throws {
        let d = try doc("""
            <m:Folders><t:Folder><t:FolderId Id="F1"/><t:DisplayName>Posteingang</t:DisplayName></t:Folder>
            <t:Folder><t:FolderId Id="F2"/><t:DisplayName>Archiv</t:DisplayName></t:Folder></m:Folders>
            """)
        #expect(EWSBackend.archiveFolderID(d) == "F2")
    }

    @Test func getFolderSkipsMissingFolders() throws {
        let ok = #"<m:GetFolderResponseMessage ResponseClass="Success"><m:Folders><t:Folder><t:FolderId Id="X"/></t:Folder></m:Folders></m:GetFolderResponseMessage>"#
        let bad = #"<m:GetFolderResponseMessage ResponseClass="Error"><m:ResponseCode>ErrorFolderNotFound</m:ResponseCode></m:GetFolderResponseMessage>"#
        let d = try doc("<m:GetFolderResponse><m:ResponseMessages>" + ok + bad + ok + ok + ok + "</m:ResponseMessages></m:GetFolderResponse>")
        #expect(EWSBackend.parseGetFolder(d).map(\.role) == [.inbox, .sent, .junk, .trash])
    }

    @Test func serverFieldAcceptsHostOrURL() {
        #expect(ExchangeAccount(email: "", username: "", server: "mail.example.com").ewsURL?.absoluteString
                == "https://mail.example.com/EWS/Exchange.asmx")
        #expect(ExchangeAccount(email: "", username: "", server: "https://x.example.com/EWS/Exchange.asmx").ewsURL?.host
                == "x.example.com")
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
}
