---
title: 'A dropped or pasted Finder alias is attached as the alias file itself (about 940 bytes of bookmark data), not the file or folder it points to'
priority: P3
area: MailStore
status: open
found: 2026-11-13
---
## Summary
Dropping (on the text or the header) or pasting a Finder alias into a compose window attaches the alias file: its bookmark bytes under the name "Report.pdf alias", with no content type. The recipient gets a useless ~940-byte file instead of the report. An alias of a folder is attached the same way instead of being zipped.

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
}
```

## Expected vs actual
Expected: the target's 20 bytes (`%PDF-1.4 real report`); for the folder alias, one `application/zip`.
Actual:
```
Expectation failed: files.first?.data == Data("%PDF-1.4 real report".utf8)
attached 940 bytes named Report.pdf alias (type nil)
Expectation failed: files.map(\.contentType) == ["application/zip"]
got ["Photos alias nil 932B"]
```
(The control in the test confirms the file is a real alias: `isAliasFile == true`.)

## Why expected
README "Attaching files": drop files on the window or the text (Finder files); "A folder goes as a zip of it". An alias stands for its original everywhere in macOS (Finder, open panels). ⚠️ Mail.app resolving aliases on drop is recalled, not read from the bundle; but the recipient receiving a bookmark blob that only opens on the sender's Mac is wrong regardless.

How it's reached (read from the code; only `files()` was run): Attach / ⇧⌘A use `NSOpenPanel`, whose `resolvesAliases` defaults to true per Apple's documentation (⚠️ not run here), so that path is probably fine. The drop and paste paths hand the pasteboard's file URLs straight to `files()`: `ComposeTextView.attachFiles(from:at:)` (ComposeTextView.swift:329-347, used by paste at :235 and drop at :274) and `ComposeView.drop` (ComposeView.swift:131-139).

Not BUG-051: that one is a *symlink* to a folder (POSIX link, resolved by the file system, failing in the zip step). A Finder alias is a regular file holding bookmark data. Reading it follows nothing, and `.isDirectoryKey` is false for it. It needs `URL(resolvingAliasFileAt:)`.

## Likely cause
`MailStore.files(_:)` (Sources/MailModel/MailStore.swift:1380-1395) never checks `.isAliasFileKey` or calls `URL(resolvingAliasFileAt:)`. `isDirectory` is false for the alias file, so `Data(contentsOf:)` reads the bookmark bytes, and the name is `url.lastPathComponent` of the alias.
