import Foundation
import Testing
import UniformTypeIdentifiers
@testable import EWS
@testable import MailModel

/// Round 5, hunter K: attachments end to end (model and EWS). EWS flows run the real client against the loopback
/// `ScriptedServer` of EWSFlowTests; no mocks.
@MainActor
@Suite(.serialized)
struct Probe_R5K_Attachments {
    let acct = Account(name: "Exchange", address: "me@work.com")
    let work = Account(name: "Work", address: "me@work.com")

    func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("ProbeR5K-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func store(_ server: ScriptedServer) -> MailStore {
        let s = MailStore(accounts: [], messages: [])
        s.add(acct, backend: EWSBackend(client: EWSClient(url: server.url, username: "u", password: "p")))
        s.setRemoteFolders([RemoteFolder(role: .inbox, id: "INBOX"), RemoteFolder(role: .drafts, id: "DRAFTS"),
                            RemoteFolder(role: .sent, id: "SENT"), RemoteFolder(role: .trash, id: "DEL")], account: acct.id)
        s.downloadsFolder = tempDir().appendingPathComponent("Mail Downloads")
        return s
    }

    func getItem(_ item: String) -> String {
        EWSReply.resp("GetItem", EWSReply.ok("GetItem", "<m:Items>\(item)</m:Items>"))
    }

    func item(_ attachments: String, body: String = "<t:Body BodyType=\"Text\">Hi</t:Body>") -> String {
        "<t:Message><t:ItemId Id=\"M\" ChangeKey=\"CK\"/>\(body)<t:Attachments>\(attachments)</t:Attachments></t:Message>"
    }

    func parsed(_ item: String) throws -> MessageBody {
        let doc = try XMLDocument(xmlString: """
            <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" \
            xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages" \
            xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types"><s:Body><m:Items>\(item)</m:Items></s:Body></s:Envelope>
            """)
        return EWSBackend.parseBody(try #require(doc.first("Items")?.elementChildren.first))
    }

    func serverMessage(_ rid: String, preview: String = "Preview", hasAttachments: Bool = true) -> Message {
        Message(accountID: acct.id, mailbox: .inbox, from: Contact(name: "Ann", email: "ann@x.com"),
                to: [Contact(name: "Me", email: "me@work.com")], subject: "S \(rid)", body: "",
                date: Date(timeIntervalSince1970: 1_000_000), remoteID: rid, hasAttachments: hasAttachments,
                serverPreview: preview, bodyLoaded: false)
    }

    func waitFor(_ timeout: Duration = .seconds(5), _ cond: () -> Bool) async throws {
        var left = timeout
        while !cond() && left > .zero {
            let start = ContinuousClock.now
            try await Task.sleep(for: .milliseconds(10))
            left -= min(start.duration(to: .now), .milliseconds(100))
        }
    }

    // MARK: R5K-01

    /// R5K-01: a message with a cloud attachment (OneDrive/SharePoint link, EWS ReferenceAttachment) is listed with no
    /// size, and `needsBody` treats any attachment without a size as "loaded by an old version": its body is fetched
    /// again every time it is shown (and before every reply/forward).
    @Test func cloudAttachmentBodyIsFetchedOnce() async throws {
        let ref = "<t:ReferenceAttachment><t:AttachmentId Id=\"AT1\"/><t:Name>Budget.xlsx</t:Name><t:IsInline>false</t:IsInline>"
            + "<t:AttachLongPathName>https://contoso-my.sharepoint.com/personal/ann/Budget.xlsx</t:AttachLongPathName></t:ReferenceAttachment>"
        let server = ScriptedServer([getItem(item(ref)), getItem(item(ref)), getItem(item(ref))])
        defer { server.stop() }
        let s = store(server)
        s.merge([serverMessage("M")], account: acct.id, mailbox: .inbox)
        let id = s.messages[0].id
        await s.loadBody(id)
        #expect(s.message(id)?.attachments.map(\.name) == ["Budget.xlsx.webloc"], "\(s.status ?? "")")
        await s.loadBody(id)  // shown again
        _ = await s.loadedDraft(.reply, to: id)
        #expect(s.message(id)?.needsBody == false, "needsBody stays true after the body loaded")
        #expect(server.served == 1, "body fetched \(server.served) times for one message")
    }

    // MARK: R5K-02

    /// R5K-02: a later summary keeps the loaded body (and its attachment list and paperclip) unless names or preview
    /// changed. A file added to or removed from a draft elsewhere (Outlook, OWA) changes only HasAttachments: the old
    /// list stays for good, and opening by position fetches whatever file is now at that place.
    @Test func attachmentChangeOnServerRefreshesTheList() {
        let s = MailStore(accounts: [], messages: [])
        s.add(acct, backend: nil)
        s.merge([serverMessage("D", hasAttachments: false)], account: acct.id, mailbox: .drafts)
        let id = s.messages[0].id
        s.setBody(MessageBody(text: "Preview", attachments: [], from: Contact(name: "Ann", email: "ann@x.com"),
                              to: [Contact(name: "Me", email: "me@work.com")], cc: []), for: id)
        // The draft got a file in Outlook: same text, same people, HasAttachments now true.
        s.merge([serverMessage("D", hasAttachments: true)], account: acct.id, mailbox: .drafts)
        let m = s.message(id)
        #expect(m?.hasAttachments == true || m?.needsBody == true,
                "hasAttachments \(String(describing: m?.hasAttachments)), needsBody \(String(describing: m?.needsBody))")
    }

    // MARK: R5K-03

    /// R5K-03: a forward whose original is gone by the time its files are fetched (erased, or deleted on the server
    /// while the window opens; or at Try Again) silently drops the files: `loadingOriginal` is cleared, Send is
    /// enabled, nothing says the attachments are missing ("All or none … Try Again or Continue Without Them").
    @Test func forwardOfVanishedOriginalDoesNotSilentlyDropFiles() async {
        let s = MailStore(accounts: [], messages: [])
        s.add(acct, backend: nil)
        var m = serverMessage("M")
        m.bodyLoaded = true; m.htmlChecked = true; m.body = "See attached"
        m.attachments = [Attachment(name: "contract.pdf", size: 500, contentType: "application/pdf")]
        s.merge([m], account: acct.id, mailbox: .inbox)
        let id = s.messages[0].id
        var d = s.draft(.forward, to: id)
        #expect(d.loadingOriginal == id)
        s.merge([], deleted: ["M"], account: acct.id, mailbox: .inbox)  // deleted on the server meanwhile
        await s.includeOriginalAttachments(in: &d)
        #expect(d.loadingOriginal != nil || !d.attachments.isEmpty,
                "forward can be sent without its files; status: \(s.status ?? "nil")")
    }

    // MARK: R5K-04

    /// R5K-04: Include Attachments With Replies ▸ When Adding Recipients. A reply to a message with Reply-To (a
    /// mailing list, a ticket system) goes to the Reply-To address, which `addsNewRecipient` doesn't count as "on the
    /// original": leaving To unchanged pulls in the original's files.
    @Test func replyToAddressIsNotANewRecipient() {
        var m = Message(accountID: work.id, mailbox: .inbox, from: Contact(name: "Ann", email: "ann@x.com"),
                        to: [Contact(name: "Team", email: "team@lists.x.com")], subject: "Specs", body: "See attached",
                        date: Date(timeIntervalSince1970: 1_000_000), attachments: [Attachment(name: "spec.pdf", size: 10)])
        m.replyTo = [Contact(name: "Team", email: "team@lists.x.com"), Contact(name: "Tickets", email: "tickets@x.com")]
        let s = MailStore(accounts: [work], messages: [m])
        let d = s.draft(.reply, to: m.id, includeAttachments: .whenAddingRecipients)
        #expect(d.to.contains("tickets@x.com"))
        #expect(!s.addsNewRecipient(d), "the untouched reply counts as adding a recipient: To = \(d.to)")
    }

    // MARK: R5K-05

    func attachmentContent(_ data: Data) -> String {
        EWSReply.resp("GetAttachment", EWSReply.ok("GetAttachment", "<m:Attachments><t:FileAttachment><t:AttachmentId Id=\"AT1\"/>"
            + "<t:Name>contract.pdf</t:Name><t:Content>\(data.base64EncodedString())</t:Content></t:FileAttachment></m:Attachments>"))
    }

    /// R5K-05: opened files are kept by position and name ("Mail Downloads/<message>/<index>/<name>") and reused as
    /// they are. When the message's body is fetched again because it changed on the server (a draft edited elsewhere:
    /// new text, the file replaced by a new version of the same name), Open, Quick Look and Save still give the old
    /// file: the copy is never checked against the list that came with the new body.
    @Test func openedCopyIsNotReusedAfterTheMessageChanged() async throws {
        let file = "<t:FileAttachment><t:AttachmentId Id=\"AT1\"/><t:Name>contract.pdf</t:Name><t:ContentType>application/pdf</t:ContentType>"
            + "<t:Size>2</t:Size><t:IsInline>false</t:IsInline></t:FileAttachment>"
        let v1 = Data("v1".utf8), v2 = Data("v2".utf8)
        let server = ScriptedServer([getItem(item(file, body: "<t:Body BodyType=\"Text\">First version</t:Body>")),
                                     getItem(item(file)), attachmentContent(v1),
                                     getItem(item(file, body: "<t:Body BodyType=\"Text\">Second version</t:Body>")),
                                     getItem(item(file)), attachmentContent(v2), getItem(item(file)), attachmentContent(v2)])
        defer { server.stop() }
        let s = store(server)
        s.merge([serverMessage("D", preview: "First version")], account: acct.id, mailbox: .drafts)
        let id = s.messages[0].id
        await s.loadBody(id)
        let first = await s.attachmentFile(0, of: id)
        #expect(first.flatMap { try? Data(contentsOf: $0) } == v1)
        // Edited in Outlook: new text, contract.pdf replaced by its new version.
        s.merge([serverMessage("D", preview: "Second version")], account: acct.id, mailbox: .drafts)
        await s.loadBody(id)
        #expect(s.message(id)?.body == "Second version")
        let opened = await s.attachmentFile(0, of: id)
        let saved = await s.saveAttachment(0, of: id, to: tempDir())
        #expect(opened.flatMap { try? Data(contentsOf: $0) } == v2, "Open gives the old version")
        #expect(saved.flatMap { try? Data(contentsOf: $0) } == v2, "Save gives the old version")
    }

    // MARK: R5K-06

    /// R5K-06: a symbolic link to a Finder alias (e.g. a link in ~/Desktop to an alias kept in a project folder) is
    /// attached as the alias's bookmark bytes under the link's name: the recipient gets a file nothing can open.
    /// functional.md: "A Finder alias … is resolved first: its original file … goes under the original's name".
    @Test func symlinkToAliasAttachesTheOriginal() throws {
        let dir = tempDir()
        let original = dir.appendingPathComponent("report.pdf")
        let content = Data("%PDF-1.4 report".utf8)
        try content.write(to: original)
        let alias = dir.appendingPathComponent("report alias")
        try URL.writeBookmarkData(try original.bookmarkData(options: .suitableForBookmarkFile), to: alias)
        let link = dir.appendingPathComponent("report link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: alias)
        let s = MailStore(accounts: [work], messages: [])
        #expect(s.files([alias]).map(\.data) == [content])  // control: the alias itself resolves
        let files = s.files([link])
        #expect(files.map(\.data) == [content], "attached \(files.map(\.name)) with \(files.first?.data.count ?? 0) bytes of bookmark data")
    }
}
