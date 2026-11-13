import Foundation
import Testing
import UniformTypeIdentifiers
@testable import EWS
@testable import MailModel

/// Round 4 probes: attachments end to end. Real temp files; EWS through the real client pointed at a plain
/// `file://` response file (no network, no fake classes).
@MainActor
@Suite(.serialized)
struct Probe_Attach4Tests {
    let work = Account(name: "Work", address: "me@work.com")
    let acct = Account(name: "Exchange", address: "me@work.com")

    func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("ProbeAttach4-\(UUID().uuidString)")
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

    func env(_ body: String) -> String {
        """
        <?xml version="1.0" encoding="utf-8"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>\
        <m:GetItemResponse xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages" \
        xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types"><m:ResponseMessages>\
        <m:GetItemResponseMessage ResponseClass="Success"><m:ResponseCode>NoError</m:ResponseCode><m:Items>\(body)</m:Items>\
        </m:GetItemResponseMessage></m:ResponseMessages></m:GetItemResponse></s:Body></s:Envelope>
        """
    }

    /// A store with one Exchange account whose "server" is a plain response file (file:// fixture). Every request
    /// gets the same answer, so the file holds a GetItem answer whose Attachments also serve as GetAttachment's.
    func fileStore(_ response: String) throws -> (MailStore, URL) {
        let url = tempDir().appendingPathComponent("ews.xml")
        try Data(response.utf8).write(to: url)
        let s = MailStore(accounts: [], messages: [])
        s.add(acct, backend: EWSBackend(client: EWSClient(url: url, username: "u", password: "p")))  // file:// fixture
        s.setRemoteFolders([RemoteFolder(role: .inbox, id: "INBOX"), RemoteFolder(role: .drafts, id: "DRAFTS"),
                            RemoteFolder(role: .trash, id: "DEL")], account: acct.id)
        s.downloadsFolder = tempDir().appendingPathComponent("Mail Downloads")
        return (s, url)
    }

    func serverMessage(_ rid: String) -> Message {
        Message(accountID: acct.id, mailbox: .inbox, from: Contact(name: "Ann", email: "ann@x.com"),
                to: [Contact(name: "Me", email: "me@work.com")], subject: "S \(rid)", body: "",
                date: Date(timeIntervalSince1970: 1_000_000), remoteID: rid, hasAttachments: true)
    }

    func local(_ names: [MailModel.Attachment], data: [Data]) -> (MailStore, Message.ID) {
        var m = Message(accountID: work.id, mailbox: .inbox, from: Contact(name: "Ann", email: "ann@x.com"),
                        to: [Contact(name: "Me", email: work.address)], subject: "Files", body: "Body",
                        date: Date(timeIntervalSince1970: 1_000_000))
        m.attachments = names
        let s = MailStore(accounts: [work], messages: [m])
        s.setAttachmentData(data, for: m.id)
        s.downloadsFolder = tempDir().appendingPathComponent("Mail Downloads")
        return (s, m.id)
    }

    func zipEntries(_ data: Data) throws -> [String] {
        let f = tempDir().appendingPathComponent("x.zip")
        try data.write(to: f)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zipinfo")
        p.arguments = ["-1", f.path]
        let pipe = Pipe(); p.standardOutput = pipe
        try p.run(); p.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n").map(String.init)
    }

    // MARK: Attaching files

    /// A Finder alias (not a symlink) dropped or chosen: the file it points to is attached, not the alias's
    /// bookmark bytes.
    @Test func probeFinderAliasToFileAttachesTheOriginal() throws {
        let dir = tempDir()
        let target = dir.appendingPathComponent("Report.pdf")
        try Data("%PDF-1.4 real report".utf8).write(to: target)
        let alias = dir.appendingPathComponent("Report.pdf alias")
        let bm = try target.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
        try URL.writeBookmarkData(bm, to: alias)
        #expect(try alias.resourceValues(forKeys: [.isAliasFileKey]).isAliasFile == true)  // control: a real alias
        let s = MailStore(accounts: [work], messages: [])
        let files = s.files([alias])
        #expect(files.count == 1)
        #expect(files.first?.data == Data("%PDF-1.4 real report".utf8),
                "attached \(files.first?.data.count ?? -1) bytes named \(files.first?.name ?? "-") (type \(files.first?.contentType ?? "nil"))")
    }

    /// A Finder alias of a folder: the folder is zipped, as a folder itself would be.
    @Test func probeFinderAliasToFolderAttachesZip() throws {
        let dir = tempDir()
        let folder = dir.appendingPathComponent("Photos")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("a".utf8).write(to: folder.appendingPathComponent("a.txt"))
        let alias = dir.appendingPathComponent("Photos alias")
        let bm = try folder.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
        try URL.writeBookmarkData(bm, to: alias)
        let s = MailStore(accounts: [work], messages: [])
        let files = s.files([alias])
        #expect(files.map(\.contentType) == ["application/zip"], "got \(files.map { "\($0.name) \($0.contentType ?? "nil") \($0.data.count)B" })")
    }

    /// Zero-byte file: attached as an empty file (control).
    @Test func controlZeroByteFileAttaches() throws {
        let dir = tempDir()
        let f = dir.appendingPathComponent("empty.txt")
        try Data().write(to: f)
        let s = MailStore(accounts: [work], messages: [])
        let files = s.files([f])
        #expect(files.map(\.data) == [Data()] && s.status == nil)
    }

    /// Photos from a camera or Windows are named IMG_0001.JPG: still a JPEG, placed inline.
    @Test func probeUppercaseExtensionGetsItsType() throws {
        let dir = tempDir()
        let f = dir.appendingPathComponent("IMG_0001.JPG")
        try Data([0xFF, 0xD8, 0xFF, 0xE0]).write(to: f)
        let s = MailStore(accounts: [work], messages: [])
        var d = Draft(accountID: work.id, body: "\u{FFFC}")
        s.attach([f], to: &d)
        #expect(d.attachments.first?.contentType == "image/jpeg")
        #expect(d.placedPictures == [0])
    }

    /// A folder with a file the user can't read: the zip must not silently leave it out.
    @Test func probeFolderWithUnreadableFileIsNotSilentlyIncomplete() throws {
        let dir = tempDir()
        let folder = dir.appendingPathComponent("Project")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("public".utf8).write(to: folder.appendingPathComponent("a.txt"))
        let secret = folder.appendingPathComponent("secret.txt")
        try Data("secret".utf8).write(to: secret)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: secret.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: secret.path) }
        let s = MailStore(accounts: [work], messages: [])
        let files = s.files([folder])
        let entries = try files.first.map { try zipEntries($0.data) } ?? []
        #expect(entries.contains { $0.hasSuffix("secret.txt") } || s.status != nil,
                "zip holds \(entries), status \(s.status ?? "nil")")
    }

    /// A folder the user can't read at all: reported, not attached as an empty zip.
    @Test func probeUnreadableFolderIsReported() throws {
        let dir = tempDir()
        let folder = dir.appendingPathComponent("Locked")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: folder.appendingPathComponent("x.txt"))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        let s = MailStore(accounts: [work], messages: [])
        let files = s.files([folder])
        let entries = try files.first.map { try zipEntries($0.data) } ?? []
        #expect(files.isEmpty || entries.contains { $0.hasSuffix("x.txt") },
                "attached \(files.map(\.name)) holding \(entries); status \(s.status ?? "nil")")
        #expect(files.isEmpty == (s.status != nil))
    }

    // MARK: EWS attachment metadata and content

    /// A zero-byte file from Exchange: `<t:Content/>` (or no Content at all, as for an empty file) is empty data.
    @Test(arguments: ["<t:Content/>", "<t:Content></t:Content>", ""])
    func probeZeroByteAttachmentContent(content: String) throws {
        let d = try doc("""
            <m:GetAttachmentResponse><m:ResponseMessages><m:GetAttachmentResponseMessage ResponseClass="Success">\
            <m:ResponseCode>NoError</m:ResponseCode><m:Attachments><t:FileAttachment><t:AttachmentId Id="A"/>\
            <t:Name>empty.txt</t:Name><t:ContentType>text/plain</t:ContentType><t:Size>0</t:Size>\(content)\
            </t:FileAttachment></m:Attachments></m:GetAttachmentResponseMessage></m:ResponseMessages></m:GetAttachmentResponse>
            """)
        #expect(EWSBackend.parseAttachmentContent(d) == Data())
    }

    /// An attached message without a subject (`<t:Name/>`): Save to Downloads must give a file the Finder shows.
    @Test func probeAttachedMessageWithoutSubjectIsNotHidden() async throws {
        let d = try doc("""
            <t:Message><t:ItemId Id="ID1"/><t:Body BodyType="Text">Hi</t:Body><t:Attachments>\
            <t:ItemAttachment><t:AttachmentId Id="A3"/><t:Name/><t:Size>900</t:Size></t:ItemAttachment>\
            </t:Attachments></t:Message>
            """)
        let item = try #require(d.first("Message"))
        let a = try #require(EWSBackend.parseBody(item).attachments.first)
        let (s, id) = local([a], data: [Data("From: a@x.com\r\n\r\nHi".utf8)])
        var saved = try #require(await s.saveAttachment(0, of: id, to: tempDir()))
        saved.removeAllCachedResourceValues()
        let hidden = try saved.resourceValues(forKeys: [.isHiddenKey]).isHidden
        #expect(hidden == false, "listed as \(a.name.debugDescription); saved as \(saved.lastPathComponent.debugDescription), hidden \(String(describing: hidden))")
    }

    /// base64 with CRLF line breaks every 76 characters and blanks (as MIME tools write it).
    @Test func controlBase64WithLineBreaks() throws {
        let raw = Data((0..<3000).map { UInt8($0 % 251) })
        let b64 = raw.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
        let d = try doc("""
            <m:GetAttachmentResponse><m:ResponseMessages><m:GetAttachmentResponseMessage ResponseClass="Success">\
            <m:Attachments><t:FileAttachment><t:Name>a.bin</t:Name><t:Content>
             \(b64.replacingOccurrences(of: "\r", with: "&#13;"))
            </t:Content></t:FileAttachment></m:Attachments></m:GetAttachmentResponseMessage></m:ResponseMessages></m:GetAttachmentResponse>
            """)
        #expect(EWSBackend.parseAttachmentContent(d) == raw)
    }

    /// file:// fixture: a zero-byte attachment opens end to end.
    @Test func probeZeroByteAttachmentOpensFromExchange() async throws {
        let item = """
            <t:Message><t:ItemId Id="M" ChangeKey="CK"/><t:Body BodyType="Text">Hi</t:Body><t:Attachments>\
            <t:FileAttachment><t:AttachmentId Id="AT1"/><t:Name>empty.txt</t:Name><t:ContentType>text/plain</t:ContentType>\
            <t:Size>0</t:Size><t:IsInline>false</t:IsInline><t:Content/></t:FileAttachment></t:Attachments></t:Message>
            """
        let (s, _) = try fileStore(env(item))
        s.merge([serverMessage("M")], account: acct.id, mailbox: .inbox)
        let id = s.messages[0].id
        await s.loadBody(id)
        #expect(s.message(id)?.attachments.map(\.name) == ["empty.txt"], "status \(s.status ?? "")")
        let url = await s.attachmentFile(0, of: id)
        #expect(url != nil, "status \(s.status ?? "")")
    }

    /// file:// fixture: control, an ordinary file opens end to end through a plain response file.
    @Test func controlAttachmentOpensFromExchange() async throws {
        let item = """
            <t:Message><t:ItemId Id="M" ChangeKey="CK"/><t:Body BodyType="Text">Hi</t:Body><t:Attachments>\
            <t:FileAttachment><t:AttachmentId Id="AT1"/><t:Name>a.txt</t:Name><t:ContentType>text/plain</t:ContentType>\
            <t:Size>3</t:Size><t:IsInline>false</t:IsInline><t:Content>AQID</t:Content></t:FileAttachment></t:Attachments></t:Message>
            """
        let (s, _) = try fileStore(env(item))
        s.merge([serverMessage("M")], account: acct.id, mailbox: .inbox)
        let id = s.messages[0].id
        await s.loadBody(id)
        let url = await s.attachmentFile(0, of: id)
        #expect(url.flatMap { try? Data(contentsOf: $0) } == Data([1, 2, 3]), "status \(s.status ?? "")")
    }

    /// file:// fixture: a cloud attachment (ReferenceAttachment, a OneDrive/SharePoint link) is listed like a file;
    /// opening it must not fail with "no content".
    @Test func probeReferenceAttachmentOpens() async throws {
        let item = """
            <t:Message><t:ItemId Id="M" ChangeKey="CK"/><t:Body BodyType="Text">Hi</t:Body><t:Attachments>\
            <t:ReferenceAttachment><t:AttachmentId Id="AT1"/><t:Name>Budget.xlsx</t:Name><t:Size>0</t:Size>\
            <t:IsInline>false</t:IsInline><t:AttachLongPathName>https://contoso.sharepoint.com/Budget.xlsx</t:AttachLongPathName>\
            <t:ProviderType>OneDrivePro</t:ProviderType></t:ReferenceAttachment></t:Attachments></t:Message>
            """
        let (s, _) = try fileStore(env(item))
        s.merge([serverMessage("M")], account: acct.id, mailbox: .inbox)
        let id = s.messages[0].id
        await s.loadBody(id)
        let listed = s.message(id)?.attachments.map(\.name) ?? []
        let url = listed.isEmpty ? nil : await s.attachmentFile(0, of: id)
        #expect(listed.isEmpty || url != nil, "listed \(listed); open: \(s.status ?? "")")
    }

    // MARK: Quick Look

    /// Space on the second file, which can't be had: Quick Look must not show another file instead.
    @Test func probeQuickLookOnUnavailableFileDoesNotShowAnother() async throws {
        let (s, id) = local(["a.pdf", "b.pdf"], data: [Data([1])])
        await s.quickLookAttachments(of: id, at: 1)
        #expect(s.previewItem?.lastPathComponent != "a.pdf", "front \(s.previewItem?.lastPathComponent ?? "nil"), status \(s.status ?? "")")
    }

    // MARK: Saving

    /// Saving into a folder that is read-only: nothing saved, a status.
    @Test func controlSaveIntoReadOnlyFolder() async throws {
        let (s, id) = local(["a.pdf"], data: [Data([1])])
        let folder = tempDir()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        let r = await s.saveAttachment(0, of: id, to: folder)
        #expect(r == nil && s.status?.contains("Couldn't save") == true)
    }

    /// The downloads folder can't be created (its parent is read-only): open fails with a status.
    @Test func controlDownloadsFolderNotWritable() async throws {
        let (s, id) = local(["a.pdf"], data: [Data([1])])
        let parent = tempDir()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: parent.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path) }
        s.downloadsFolder = parent.appendingPathComponent("Mail Downloads")
        let r = await s.attachmentFile(0, of: id)
        #expect(r == nil && s.status?.contains("Couldn't open") == true)
    }

    // MARK: Saving copies ("name 2")

    /// A file without an extension whose name has a dot ("Version 2.5 notes", "Mr. Smith"): the second copy is
    /// "Version 2.5 notes 2", as in the Finder, not a number put inside the name.
    @Test(arguments: [("Version 2.5 notes", "Version 2.5 notes 2"), ("Mr. Smith CV", "Mr. Smith CV 2"),
                      ("Minutes 12.11. Board meeting", "Minutes 12.11. Board meeting 2")])
    func probeSecondCopyOfNameWithDotButNoExtension(name: String, expected: String) async throws {
        let (s, id) = local([MailModel.Attachment(name: name)], data: [Data([1])])
        let folder = tempDir()
        let first = await s.saveAttachment(0, of: id, to: folder)
        let second = await s.saveAttachment(0, of: id, to: folder)
        #expect(first?.lastPathComponent == name)
        #expect(second?.lastPathComponent == expected, "second copy: \(second?.lastPathComponent ?? "nil"), status \(s.status ?? "")")
    }

    /// A long name with a dot early and no extension (a subject used as file name): the first copy saves (the name
    /// is shortened to 255 bytes); the second copy must save too.
    @Test func probeSecondCopyOfLongNameWithEarlyDot() async throws {
        let name = "Re. " + String(repeating: "Quarterly planning notes and action items ", count: 8)
        let (s, id) = local([MailModel.Attachment(name: name)], data: [Data([1])])
        let folder = tempDir()
        let first = await s.saveAttachment(0, of: id, to: folder)
        #expect(first != nil, "first: \(s.status ?? "")")
        let second = await s.saveAttachment(0, of: id, to: folder)
        #expect(second != nil, "second: \(s.status ?? "")")
    }

    /// Controls: a package goes as a zip; a double extension keeps its type; an unreadable file is reported.
    @Test func controlPackageDoubleExtensionUnreadable() throws {
        let dir = tempDir()
        let pkg = dir.appendingPathComponent("Notes.rtfd")
        try FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
        try Data("{\\rtf1}".utf8).write(to: pkg.appendingPathComponent("TXT.rtf"))
        let tgz = dir.appendingPathComponent("backup.tar.gz")
        try Data([0x1F, 0x8B]).write(to: tgz)
        let locked = dir.appendingPathComponent("locked.txt")
        try Data("x".utf8).write(to: locked)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        let s = MailStore(accounts: [work], messages: [])
        let files = s.files([pkg, tgz, locked])
        #expect(files.map(\.name) == ["Notes.rtfd.zip", "backup.tar.gz"], "\(files.map(\.name))")
        #expect(files.last?.contentType?.contains("gzip") == true, "\(files.map(\.contentType))")
        #expect(s.status?.contains("locked.txt") == true)
    }

    // MARK: Big files

    /// file:// fixture: a 12 MB file (16 MB of base64, over libxml2's 10 MB text-node limit) opens end to end.
    @Test(arguments: [3_000_000, 12_000_000, 40_000_000])
    func probeBigAttachmentOpensFromExchange(bytes: Int) async throws {
        var raw = Data(count: bytes)
        raw.withUnsafeMutableBytes { p in for i in stride(from: 0, to: bytes, by: 4096) { p[i] = UInt8(i / 4096 % 251) } }
        let item = """
            <t:Message><t:ItemId Id="M" ChangeKey="CK"/><t:Body BodyType="Text">Hi</t:Body><t:Attachments>\
            <t:FileAttachment><t:AttachmentId Id="AT1"/><t:Name>big.bin</t:Name><t:ContentType>application/octet-stream</t:ContentType>\
            <t:Size>\(bytes)</t:Size><t:IsInline>false</t:IsInline><t:Content>\(raw.base64EncodedString())</t:Content></t:FileAttachment>\
            </t:Attachments></t:Message>
            """
        let (s, _) = try fileStore(env(item))
        s.merge([serverMessage("M")], account: acct.id, mailbox: .inbox)
        let id = s.messages[0].id
        await s.loadBody(id)
        #expect(s.message(id)?.attachments.first?.size == bytes, "body: \(s.status ?? "")")
        let clock = ContinuousClock.now
        let url = await s.attachmentFile(0, of: id)
        let took = ContinuousClock.now - clock
        #expect(url.flatMap { try? Data(contentsOf: $0) } == raw, "open: \(s.status ?? "nil") after \(took)")
    }

    /// file:// fixture: an attachment Exchange sends without a Name element (an unnamed calendar part, an attached
    /// message without subject): it must still be listed, so it can be seen and saved.
    @Test func probeAttachmentWithoutNameElementIsListed() async throws {
        let item = """
            <t:Message><t:ItemId Id="M" ChangeKey="CK"/><t:Body BodyType="Text">Hi</t:Body><t:Attachments>\
            <t:FileAttachment><t:AttachmentId Id="A1"/><t:ContentType>text/calendar</t:ContentType><t:Size>5</t:Size>\
            <t:IsInline>false</t:IsInline><t:Content>QkVHSU4=</t:Content></t:FileAttachment></t:Attachments></t:Message>
            """
        let (s, _) = try fileStore(env(item))
        s.merge([serverMessage("M")], account: acct.id, mailbox: .inbox)
        let id = s.messages[0].id
        #expect(s.message(id)?.hasAttachments == true)  // control: the paperclip from the list
        await s.loadBody(id)
        let m = try #require(s.message(id))
        #expect(m.attachments.count == 1 && m.hasAttachments, "attachments \(m.attachments), paperclip \(m.hasAttachments), status \(s.status ?? "nil")")
    }

    // MARK: The opened copy

    /// The user opens a file (it goes to Mail Downloads) and edits it there, e.g. fills in a form in Preview. A forward,
    /// and Save Attachment, must still carry the attachment as it came in the mail, not the edited copy.
    @Test func probeEditedOpenedCopyIsNotForwardedOrSaved() async throws {
        let original = Data("%PDF original form".utf8)
        let (s, id) = local(["form.pdf"], data: [original])
        let opened = try #require(await s.attachmentFile(0, of: id))
        try Data("%PDF filled in with my bank details".utf8).write(to: opened)  // the user's edit in Preview
        var d = s.draft(.forward, to: id)
        await s.includeOriginalAttachments(in: &d)
        #expect(d.attachments.first?.data == original, "forward carries: \(String(decoding: d.attachments.first?.data ?? Data(), as: UTF8.self))")
        let saved = await s.saveAttachment(0, of: id, to: tempDir())
        #expect(saved.flatMap { try? Data(contentsOf: $0) } == original, "saved: \(saved.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "nil")")
    }

    /// file:// fixture: control, forwarding a message with an attached message takes its MIME source as a .eml.
    @Test func controlForwardTakesAttachedMessageAsEml() async throws {
        let mime = Data("From: a@x.com\r\nSubject: Budget\r\n\r\nNumbers".utf8)
        let item = """
            <t:Message><t:ItemId Id="M" ChangeKey="CK"/><t:Body BodyType="Text">Hi</t:Body><t:Attachments>\
            <t:ItemAttachment><t:AttachmentId Id="AT1"/><t:Name>Budget</t:Name><t:Size>40</t:Size><t:IsInline>false</t:IsInline>\
            <t:Message><t:MimeContent CharacterSet="UTF-8">\(mime.base64EncodedString())</t:MimeContent></t:Message></t:ItemAttachment>\
            </t:Attachments></t:Message>
            """
        let (s, _) = try fileStore(env(item))
        s.merge([serverMessage("M")], account: acct.id, mailbox: .inbox)
        let id = s.messages[0].id
        var d = s.draft(.forward, to: id)
        await s.includeOriginalAttachments(in: &d)
        #expect(d.attachments.map(\.name) == ["Budget.eml"] && d.attachments.first?.data == mime, "status \(s.status ?? "")")
    }
}
