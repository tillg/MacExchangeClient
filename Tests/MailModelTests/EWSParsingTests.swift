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
}
