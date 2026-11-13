---
title: 'Attachments without a name: an attached message with no subject saves as a hidden ".eml", and an attachment Exchange sends without Name is not listed at all'
priority: P3
area: EWS
status: open
found: 2026-11-13
---
## Summary
`listedAttachments` uses Exchange's `Name` as is. When an attached message has no subject (`<t:Name/>`), it is listed as ".eml". Save to Downloads / Save Attachment then writes a dot file, which the Finder hides: the user saves it and can't find it. When an attachment comes without a `Name` element, it is dropped from the list: the message shows no attachment, the paperclip goes away after the body loads, and it can't be opened, saved or forwarded.

## Repro
```swift
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
}
```

## Expected vs actual
Expected: the attached message gets a visible name (for example "Attachment.eml"), and the unnamed file is listed with a fallback name.
Actual:
```
Expectation failed: hidden == false
listed as ".eml"; saved as ".eml", hidden Optional(true)
Expectation failed: m.attachments.count == 1 && m.hasAttachments
attachments [], paperclip false, status nil
```

## Why expected
README: "An attached message opens as a `.eml` file", and the paperclip shows the count. The app already has a fallback for names that can't be used: `Attachment.fileName` turns an empty name, "." and ".." into "Attachment" (Models.swift). The listing should do the same instead of producing ".eml" or skipping the entry.

Caveat (⚠️): which shape Exchange 2016/2019 actually sends for a subjectless attached message or an unnamed MIME part (`<t:Name/>`, or no Name element) wasn't checked on the live server. Both shapes are believed to be schema-valid: `Name` is `minOccurs="0"` in `AttachmentType` (⚠️ recalled from types.xsd, not checked this session).

## Likely cause
Sources/EWS/EWSBackend.swift:128-136 (`listedAttachments`):
`guard a.text("IsInline") != "true", let name = a.child("Name")?.stringValue else { return nil }` drops entries without Name. Then `let file = isMessage && !name.lowercased().hasSuffix(".eml") ? name + ".eml" : name` turns an empty name into ".eml". `attachment(remoteID:index:)` uses the same function, so a fallback name keeps the positions consistent.
