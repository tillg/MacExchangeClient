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
