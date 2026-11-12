import Foundation
import Testing
@testable import EWS
@testable import MailModel

/// Write-back against a real Exchange server, confined to the folder `MailReplica-Test` (and its subfolder
/// `Moved`). It only touches a message it creates there itself, and never sends mail.
/// Runs only with `EWS_WRITE_TEST=1` in addition to the settings of `EWSLiveTests`.
struct EWSLiveWriteTests {
    static let backend = ProcessInfo.processInfo.environment["EWS_WRITE_TEST"] == "1" ? EWSLiveTests.backend : nil

    @Test(.enabled(if: EWSLiveWriteTests.backend != nil)) func readFlagMoveDeleteInTestFolder() async throws {
        let b = try #require(Self.backend)
        let test = try await folder("MailReplica-Test", in: #"<t:DistinguishedFolderId Id="msgfolderroot"/>"#, b)
        let moved = try await folder("Moved", in: #"<t:FolderId Id="\#(xmlEscape(test.id))"/>"#, b)
        let rid = try await createMessage(in: test, b)

        func state(_ id: String, in f: RemoteFolder) async throws -> Message? {
            try await b.newest(in: f, limit: 50).first { $0.remoteID == id }
        }

        try await b.setRead([rid], true)
        #expect(try await state(rid, in: test)?.isRead == true)
        try await b.setRead([rid], false)
        #expect(try await state(rid, in: test)?.isRead == false)

        try await b.setFlagged([rid], true)
        #expect(try await state(rid, in: test)?.flag != nil)
        try await b.setFlagged([rid], false)
        #expect(try await state(rid, in: test)?.flag == nil)

        let map = try await b.move([rid], to: moved)
        let newID = try #require(map[rid])
        #expect(try await state(newID, in: moved) != nil)
        #expect(try await state(rid, in: test) == nil)

        try await b.delete([newID])
        #expect(try await state(newID, in: moved) == nil)
    }

    /// Adds a file to a saved message the way sending with attachments does, and reads it back. Doesn't send.
    @Test(.enabled(if: EWSLiveWriteTests.backend != nil)) func attachmentAddedToASavedMessageReadsBack() async throws {
        let b = try #require(Self.backend)
        let test = try await folder("MailReplica-Test", in: #"<t:DistinguishedFolderId Id="msgfolderroot"/>"#, b)
        let rid = try await createMessage(in: test, b)
        let file = DraftAttachment(name: "Test & Co.txt", contentType: "text/plain", data: Data("MailReplica".utf8))
        let root = EWSBackend.parseRootItem(try await b.client.call(EWSBackend.createAttachmentRequest(parentID: rid, [file])))
        #expect(root?.id == rid)
        #expect(root?.changeKey.isEmpty == false)
        let body = try await b.body(remoteID: rid)
        #expect(body.attachments == [MailModel.Attachment(name: "Test & Co.txt", size: body.attachments.first?.size,
                                                          contentType: "text/plain")])
        #expect(try await b.attachment(remoteID: rid, index: 0) == file.data)
        try await b.delete([rid])
    }

    /// A picture placed in the text is saved the way sending does it: HTML body with a `cid:` reference and an inline
    /// attachment. Saved in the test folder (the request's Drafts swapped for it), read back, deleted. Doesn't send.
    @Test(.enabled(if: EWSLiveWriteTests.backend != nil)) func pictureInTheTextReadsBackInline() async throws {
        let b = try #require(Self.backend)
        let test = try await folder("MailReplica-Test", in: #"<t:DistinguishedFolderId Id="msgfolderroot"/>"#, b)
        let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="))
        var draft = Draft(accountID: UUID(), subject: "MailReplica live test", body: "Before\n\u{FFFC}\nAfter \u{FFFC}")
        draft.attachments = [DraftAttachment(name: "dot.png", contentType: "image/png", data: png),
                             DraftAttachment(name: "note.txt", contentType: "text/plain", data: Data("x".utf8))]
        let ids = EWSBackend.contentIDs(draft)
        let cid = try #require(ids[0])
        let create = EWSBackend.createRequest(draft, send: false, contentIDs: ids)
            .replacingOccurrences(of: #"<t:DistinguishedFolderId Id="drafts"/>"#, with: #"<t:FolderId Id="\#(xmlEscape(test.id))"/>"#)
        let item = try #require(EWSBackend.parseCreatedItem(try await b.client.call(create)))
        _ = try await b.client.call(EWSBackend.createAttachmentRequest(parentID: item.id, draft.attachments, contentIDs: ids))
        let body = try await b.body(remoteID: item.id)
        #expect(body.html?.contains("cid:\(cid)") == true)
        #expect(body.html?.contains("Before") == true && body.html?.contains("After") == true)
        #expect(body.attachments.map(\.name) == ["note.txt"])  // the picture is in the text, not the list
        let doc = try await b.client.call(EWSBackend.bodyRequest(item.id))
        let pic = try #require(doc.all("FileAttachment").first { $0.text("Name") == "dot.png" })
        #expect(pic.text("IsInline") == "true")
        #expect(pic.text("ContentId").map(EWSBackend.contentID) == cid)
        try await b.delete([item.id])
    }

    /// Finds or creates a folder by name under `parent`.
    func folder(_ name: String, in parent: String, _ b: EWSBackend) async throws -> RemoteFolder {
        let found = try await b.client.call("""
            <m:FindFolder Traversal="Shallow"><m:FolderShape><t:BaseShape>IdOnly</t:BaseShape>\
            <t:AdditionalProperties><t:FieldURI FieldURI="folder:DisplayName"/></t:AdditionalProperties></m:FolderShape>\
            <m:ParentFolderIds>\(parent)</m:ParentFolderIds></m:FindFolder>
            """)
        let existing = found.all("Folder").first { $0.text("DisplayName") == name }?.child("FolderId")?.attr("Id")
        if let existing { return RemoteFolder(role: .archive, id: existing) }
        let created = try await b.client.call("""
            <m:CreateFolder><m:ParentFolderId>\(parent)</m:ParentFolderId>\
            <m:Folders><t:Folder><t:DisplayName>\(name)</t:DisplayName></t:Folder></m:Folders></m:CreateFolder>
            """)
        return RemoteFolder(role: .archive, id: try #require(created.first("FolderId")?.attr("Id")))
    }

    /// Saves (doesn't send) an unread message in the folder.
    func createMessage(in f: RemoteFolder, _ b: EWSBackend) async throws -> String {
        let doc = try await b.client.call("""
            <m:CreateItem MessageDisposition="SaveOnly"><m:SavedItemFolderId><t:FolderId Id="\(xmlEscape(f.id))"/>\
            </m:SavedItemFolderId><m:Items><t:Message><t:Subject>MailReplica live test</t:Subject>\
            <t:Body BodyType="Text">Created by the MailReplica test suite. Safe to delete.</t:Body>\
            <t:IsRead>false</t:IsRead></t:Message></m:Items></m:CreateItem>
            """)
        return try #require(doc.first("ItemId")?.attr("Id"))
    }
}
