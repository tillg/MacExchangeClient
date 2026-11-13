---
title: 'After an opened attachment is edited (e.g. a form filled in Preview), Forward sends the edited copy and Save Attachment saves it instead of the file in the mail'
priority: P2
area: MailStore
status: open
found: 2026-11-13
---
## Summary
Opening an attachment writes it to Mail Downloads. Apps edit that file in place: Preview autosaves form fields and annotations, Word and Pages save back. From then on the app treats the edited copy as the attachment. Forward (and Reply with attachments) puts the edited bytes into the outgoing mail, and Save Attachment / Save All / Save to Downloads write the edited bytes too. Nothing tells the user. Private edits, such as bank details typed into a form or review notes, go to the forward's recipients, and the original as received can't be got back.

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
}
```

## Expected vs actual
Expected: the forward and the saved copy both hold `%PDF original form`.
Actual:
```
Expectation failed: d.attachments.first?.data == original
forward carries: %PDF filled in with my bank details
Expectation failed: saved.flatMap { try? Data(contentsOf: $0) } == original
saved: %PDF filled in with my bank details
```

## Why expected
README: "Forward takes the original's attachments along", and Save Attachment saves the attachment. What's attached is the message's content, as on the server. Mail.app builds a forward and a save from the message itself, not from the Mail Downloads copy (⚠️ recalled, not read from the bundle; no loctable string covers it). Nothing in specs/system/functional.md or DECISIONS.md says forward or save should read the opened copy (functional.md: "Files are fetched on first open into a temporary Mail Downloads folder"). Exchange still holds the unedited file, so the app has it and only uses the wrong source.

## Likely cause
`MailStore.attachmentFile` (Sources/MailModel/MailStore.swift:1062-1068) returns the Mail Downloads path as soon as a file exists there (`if FileManager.default.fileExists(atPath: url.path) { return url }`). That one path serves opening (where reusing it is fine), `saveAttachment`/`saveAllAttachments` (:1095-1113, `copyItem` from it), and `includeOriginalAttachments` (:1408-1418, `Data(contentsOf: url)`). Save and Forward should read the content itself (local data or the server), or use a copy the user can't edit.

The same early return also keeps a stale file when the attachment at that position later changes on the server under the same name (e.g. a draft edited elsewhere). That case is not probed separately here, because it needs BUG-103 fixed first.
