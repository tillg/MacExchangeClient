import Foundation
import Testing
@testable import EWS
@testable import MailModel

/// Attachments of Exchange messages end to end: listed, opened and saved. Real temp files; EWS through the real
/// client pointed at a plain `file://` response file (no network, no fake classes).
@MainActor
@Suite(.serialized)
struct EWSAttachmentTests {
    let work = Account(name: "Work", address: "me@work.com")
    let acct = Account(name: "Exchange", address: "me@work.com")

    func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("EWSAttachmentTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func doc(_ body: String) throws -> XMLDocument {
        try XMLDocument(xmlString: """
            <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" \
            xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages" \
            xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types"><s:Body>\(body)</s:Body></s:Envelope>
            """)
    }

    /// A GetItem answer holding `body`.
    func getItem(_ body: String) -> String {
        """
        <?xml version="1.0" encoding="utf-8"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>\
        <m:GetItemResponse xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages" \
        xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types"><m:ResponseMessages>\
        <m:GetItemResponseMessage ResponseClass="Success"><m:ResponseCode>NoError</m:ResponseCode><m:Items>\(body)</m:Items>\
        </m:GetItemResponseMessage></m:ResponseMessages></m:GetItemResponse></s:Body></s:Envelope>
        """
    }

    /// A store with one Exchange account whose "server" answers every request with `response` (file:// fixture).
    func fileStore(_ response: String) throws -> MailStore {
        let url = tempDir().appendingPathComponent("ews.xml")
        try Data(response.utf8).write(to: url)
        let s = MailStore(accounts: [], messages: [])
        s.add(acct, backend: EWSBackend(client: EWSClient(url: url, username: "u", password: "p")))  // file:// fixture
        s.setRemoteFolders([RemoteFolder(role: .inbox, id: "INBOX"), RemoteFolder(role: .drafts, id: "DRAFTS"),
                            RemoteFolder(role: .trash, id: "DEL")], account: acct.id)
        s.downloadsFolder = tempDir().appendingPathComponent("Mail Downloads")
        return s
    }

    /// An attached message without a subject (`<t:Name/>`): Save gives a file the Finder shows.
    @Test func attachedMessageWithoutSubjectIsNotHidden() async throws {
        let d = try doc("""
            <t:Message><t:ItemId Id="ID1"/><t:Body BodyType="Text">Hi</t:Body><t:Attachments>\
            <t:ItemAttachment><t:AttachmentId Id="A3"/><t:Name/><t:Size>900</t:Size></t:ItemAttachment>\
            </t:Attachments></t:Message>
            """)
        let item = try #require(d.first("Message"))
        let a = try #require(EWSBackend.parseBody(item).attachments.first)
        #expect(a.name == "Attachment.eml")
        var m = Message(accountID: work.id, mailbox: .inbox, from: Contact(name: "Ann", email: "ann@x.com"),
                        to: [Contact(name: "Me", email: work.address)], subject: "Files", body: "Body",
                        date: Date(timeIntervalSince1970: 1_000_000))
        m.attachments = [a]
        let s = MailStore(accounts: [work], messages: [m])
        s.setAttachmentData([Data("From: a@x.com\r\n\r\nHi".utf8)], for: m.id)
        s.downloadsFolder = tempDir().appendingPathComponent("Mail Downloads")
        var saved = try #require(await s.saveAttachment(0, of: m.id, to: tempDir()))
        saved.removeAllCachedResourceValues()
        #expect(try saved.resourceValues(forKeys: [.isHiddenKey]).isHidden == false, "saved as \(saved.lastPathComponent)")
    }

    /// An attachment Exchange sends without a Name element is listed, named after its type, and keeps the paperclip.
    @Test func attachmentWithoutNameElementIsListed() async throws {
        let item = """
            <t:Message><t:ItemId Id="M" ChangeKey="CK"/><t:Body BodyType="Text">Hi</t:Body><t:Attachments>\
            <t:FileAttachment><t:AttachmentId Id="A1"/><t:ContentType>text/calendar</t:ContentType><t:Size>5</t:Size>\
            <t:IsInline>false</t:IsInline><t:Content>QkVHSU4=</t:Content></t:FileAttachment></t:Attachments></t:Message>
            """
        let s = try fileStore(getItem(item))
        s.merge([Message(accountID: acct.id, mailbox: .inbox, from: Contact(name: "Ann", email: "ann@x.com"),
                         to: [Contact(name: "Me", email: "me@work.com")], subject: "S M", body: "",
                         date: Date(timeIntervalSince1970: 1_000_000), remoteID: "M", hasAttachments: true)],
                account: acct.id, mailbox: .inbox)
        let id = s.messages[0].id
        await s.loadBody(id)
        let m = try #require(s.message(id))
        #expect(m.attachments.map(\.name) == ["Attachment.ics"], "status \(s.status ?? "nil")")
        #expect(m.hasAttachments)
    }

    /// A cloud attachment (ReferenceAttachment, a OneDrive/SharePoint link) opens as an Internet location file,
    /// which takes the user to the link, instead of failing with "no content".
    @Test func referenceAttachmentOpensItsLink() async throws {
        func item(_ link: String) -> String {
            """
            <t:Message><t:ItemId Id="M" ChangeKey="CK"/><t:Body BodyType="Text">Hi</t:Body><t:Attachments>\
            <t:ReferenceAttachment><t:AttachmentId Id="AT1"/><t:Name>Budget.xlsx</t:Name><t:Size>0</t:Size>\
            <t:IsInline>false</t:IsInline><t:AttachLongPathName>\(link)</t:AttachLongPathName>\
            <t:ProviderType>OneDrivePro</t:ProviderType></t:ReferenceAttachment></t:Attachments></t:Message>
            """
        }
        let s = try fileStore(getItem(item("https://contoso.sharepoint.com/Budget.xlsx")))
        s.merge([Message(accountID: acct.id, mailbox: .inbox, from: Contact(name: "Ann", email: "ann@x.com"),
                         to: [Contact(name: "Me", email: "me@work.com")], subject: "S M", body: "",
                         date: Date(timeIntervalSince1970: 1_000_000), remoteID: "M", hasAttachments: true)],
                account: acct.id, mailbox: .inbox)
        let id = s.messages[0].id
        await s.loadBody(id)
        #expect(s.message(id)?.attachments.map(\.name) == ["Budget.xlsx.webloc"])
        let url = try #require(await s.attachmentFile(0, of: id), "open: \(s.status ?? "")")
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: String]
        #expect(plist?["URL"] == "https://contoso.sharepoint.com/Budget.xlsx")

        // Only web links: anything else (a file:// or app link) is not made into something that opens.
        func content(_ link: String) throws -> Data? {
            EWSBackend.parseAttachmentContent(try doc("<m:Attachments><t:ReferenceAttachment><t:AttachLongPathName>"
                + link + "</t:AttachLongPathName></t:ReferenceAttachment></m:Attachments>"))
        }
        #expect(try content("https://x.example/a") != nil)
        #expect(try content("file:///Applications/Calculator.app") == nil)
    }

    /// Files listed only now (inline non-pictures, unnamed ones) come after the others, so the positions stored
    /// with earlier bodies still fetch the same files.
    @Test func newlyListedFilesComeLast() throws {
        let d = try doc("""
            <t:Message><t:ItemId Id="A"/><t:Attachments>
            <t:FileAttachment><t:AttachmentId Id="U"/><t:ContentType>application/pdf</t:ContentType></t:FileAttachment>
            <t:FileAttachment><t:AttachmentId Id="F"/><t:Name>a.txt</t:Name></t:FileAttachment>
            </t:Attachments></t:Message>
            """)
        let item = try #require(d.first("Message"))
        let listed = EWSBackend.listedAttachments(item)
        #expect(listed.map(\.id) == ["F", "U"])
        #expect(listed.map(\.attachment.name) == ["a.txt", "Attachment.pdf"])
    }
}
