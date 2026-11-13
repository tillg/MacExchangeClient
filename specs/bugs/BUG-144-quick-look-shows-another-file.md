---
title: 'Space on an attachment that cannot be loaded opens Quick Look on a different attachment of the message'
priority: P4
area: MailStore
status: open
found: 2026-11-13
---
## Summary
When the file the user pressed Space on (or chose Quick Look Attachment for) can't be fetched, Quick Look still opens, on the message's first file that loaded. The user sees a different document than the one selected, and the status bar says the selected one couldn't be opened.

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

    /// Space on the second file, which can't be had: Quick Look must not show another file instead.
    @Test func probeQuickLookOnUnavailableFileDoesNotShowAnother() async throws {
        let (s, id) = local(["a.pdf", "b.pdf"], data: [Data([1])])
        await s.quickLookAttachments(of: id, at: 1)
        #expect(s.previewItem?.lastPathComponent != "a.pdf", "front \(s.previewItem?.lastPathComponent ?? "nil"), status \(s.status ?? "")")
    }
}
```

## Expected vs actual
Expected: no Quick Look panel (or the panel without a front item), next to the status "Couldn't open “b.pdf”…".
Actual:
```
Expectation failed: s.previewItem?.lastPathComponent != "a.pdf"
front a.pdf, status Couldn't open “b.pdf”: its content isn't available.
```

## Why expected
README: "Space shows Quick Look" for the selected attachment, and "Quick Look over all of the message's attachments, starting at `index`" is the function's own contract. The existing test `quickLookOpensAllAttachmentsAtTheChosenOne` (MailStoreTests.swift:1296) pins the front item to the chosen index, and no spec asks for the fallback. Showing another file as if it were the selected one is misleading. The fallback is only right when no index was asked for (the paperclip menu's Quick Look N Attachments, ⌘Y).

## Likely cause
`MailStore.quickLookAttachments(of:at:)` (Sources/MailModel/MailStore.swift:1118-1127) ends with `previewItem = front ?? files.first`. When the requested index failed, `front` is nil and the first loaded file becomes the front item.
