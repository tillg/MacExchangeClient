---
title: 'A cloud attachment (ReferenceAttachment, OneDrive/SharePoint link) is listed like a file but every open, save or Quick Look fails with "The server sent no content"'
priority: P4
area: EWS
status: open
found: 2026-11-13
---
## Summary
`listedAttachments` lists every child of `Attachments`, including `t:ReferenceAttachment`. Such an attachment has no `Content`, only `AttachLongPathName` (the link). It shows with a file icon and name. Double-click, Save, Quick Look and drag all fail with "Couldn't open “Budget.xlsx”: The server sent no content for the attachment (ErrorAttachmentEmpty)", and the link is never offered.

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
}
```

## Expected vs actual
Expected: either it isn't listed as a file, or opening it does something useful (opens the link).
Actual:
```
Expectation failed: listed.isEmpty || url != nil
listed ["Budget.xlsx"]; open: Couldn't open “Budget.xlsx”: The server sent no content for the attachment (ErrorAttachmentEmpty)
```

## Why expected
README: "Double-click opens a file." An entry that looks like a file but can never be opened is a dead end.

Caveats (⚠️), which is why this is P4:
- `EWSClient` sends `RequestServerVersion Exchange2013_SP1`. `ReferenceAttachment` is believed to belong to a later schema version (Exchange 2016; ⚠️ not checked this session), so an on-prem server may never return it to this client.
- Handling cloud links properly borders on a missing feature.

Same root as the parse side: `parseAttachmentContent` returns nil when there is no `Content` element. A `FileAttachment` without `<t:Content>` gives the same error (probe `probeZeroByteAttachmentContent` with the `""` case). It is not filed separately, because a zero-byte file with `<t:Content/>` opens fine, and the forward side of this is BUG-071.

## Likely cause
Sources/EWS/EWSBackend.swift:128-136 (`listedAttachments` treats any element child of `Attachments` as a file) and :147-153 (`parseAttachmentContent` reads only `Content` / `MimeContent`, so a `ReferenceAttachment` gives nil, which becomes `ErrorAttachmentEmpty` at :120-122).
