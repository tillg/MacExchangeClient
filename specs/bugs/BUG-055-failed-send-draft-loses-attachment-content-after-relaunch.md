---
title: "A message that failed to send is kept \"in Drafts on this Mac\", but after a relaunch its attached files can no longer be opened"
priority: P2
area: MailStore
status: open
found: 2026-11-12
---
## Summary
When Exchange refuses a send, `failed()` keeps the message in Drafts on this Mac. The draft row (with attachment names) is written to Mail.sqlite, but the file contents go only into the in-memory `localAttachments`. After a relaunch the draft still lists `report.pdf`, but opening or saving it fails with "its content isn't available". The user's only copy of the files is gone. The control test (same session, no relaunch) passes.

## Repro
Tests: `failedSendKeepsAttachmentContentAcrossRelaunch`, `failedSendDraftAttachmentOpensBeforeRelaunch` in `specs/bugs/probes/Probe_Store2Tests.swift`.

```swift
import Foundation
import Testing
@testable import EWS
@testable import MailModel

@MainActor
struct Probe_Store2Tests {
    let work = Account(name: "Work", address: "me@work.com")
    let home = Account(name: "iCloud", address: "me@icloud.com")

    func msg(_ acct: Account, _ box: MailboxKind = .inbox, subject: String = "Hi", from: String = "Ann",
             read: Bool = false, minutesAgo: Double = 0, flag: FlagColor? = nil) -> Message {
        Message(accountID: acct.id, mailbox: box, from: Contact(name: from, email: "\(from.lowercased())@x.com"),
                to: [Contact(name: "Me", email: acct.address)], subject: subject, body: "Body of \(subject)",
                date: Date(timeIntervalSince1970: 1_000_000 - minutesAgo * 60), isRead: read, flag: flag)
    }

    /// Like a server summary (EWS FindItem/SyncFolderItems): no body, names only for From/To.
    func summary(_ acct: Account, _ rid: String, subject: String = "Hi", minutesAgo: Double = 0) -> Message {
        var m = Message(accountID: acct.id, from: Contact(name: "Ann Lee", email: ""), to: [Contact(name: "Me", email: "")],
                        subject: subject, body: "", date: Date(timeIntervalSince1970: 1_000_000 - minutesAgo * 60),
                        remoteID: rid, serverPreview: "Can we meet on Friday?", bodyLoaded: false)
        m.conversationID = nil
        return m
    }

    func store(_ msgs: [Message]) -> MailStore { MailStore(accounts: [work, home], messages: msgs) }

    func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("ProbeStore2-\(UUID())")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func invite(organizer: Contact? = Contact(name: "Org", email: "org@x.com")) -> Invite {
        Invite(start: Date(timeIntervalSince1970: 2_000_000), end: Date(timeIntervalSince1970: 2_003_600),
               organizer: organizer)
    }

    /// A send that Exchange refused is kept "in Drafts on this Mac". Its files must still open after a relaunch.
    @Test func failedSendKeepsAttachmentContentAcrossRelaunch() async throws {
        let dir = tempDir()
        let url = dir.appendingPathComponent("Mail.sqlite")
        let s = store([])
        s.merge([(.inbox, [])], account: work.id)  // work is a server account
        var d = Draft(accountID: work.id, to: "bo@x.com", subject: "Report", body: "See attached")
        d.attachments = [DraftAttachment(name: "report.pdf", contentType: "application/pdf", data: Data("PDFDATA".utf8))]
        s.failed(PendingChange(account: work.id, change: .send(d), previous: []), "The server is busy")
        let draftID = try #require(s.messages.first { $0.mailbox == .drafts }?.id)
        let db = try MailDatabase(url: url)
        try db.write(s.takeChanges().resolved())

        // Relaunch.
        let db2 = try MailDatabase(url: url)
        let s2 = MailStore(accounts: [work, home], messages: [])
        s2.restore(try db2.meta())
        s2.finishLoading(try db2.messages())
        s2.downloadsFolder = dir.appendingPathComponent("Mail Downloads")
        #expect(s2.message(draftID)?.attachments.map(\.name) == ["report.pdf"])
        let file = await s2.attachmentFile(0, of: draftID)
        #expect(file != nil, "status: \(s2.status ?? "nil")")
    }
    /// Same, without relaunch: the draft kept after a failed send shows its file, and it opens.
    @Test func failedSendDraftAttachmentOpensBeforeRelaunch() async throws {
        let s = store([])
        s.merge([(.inbox, [])], account: work.id)
        s.downloadsFolder = tempDir()
        var d = Draft(accountID: work.id, to: "bo@x.com", subject: "Report", body: "See attached")
        d.attachments = [DraftAttachment(name: "report.pdf", contentType: "application/pdf", data: Data("PDFDATA".utf8))]
        s.failed(PendingChange(account: work.id, change: .send(d), previous: []), "busy")
        let id = try #require(s.messages.first { $0.mailbox == .drafts }?.id)
        let file = await s.attachmentFile(0, of: id)
        #expect(file.flatMap { try? Data(contentsOf: $0) } == Data("PDFDATA".utf8))
    }
}
```

## Expected vs actual
Expected: after a relaunch the kept draft's attachment opens (as it does before the relaunch).
Actual:
```
failedSendKeepsAttachmentContentAcrossRelaunch() recorded an issue at Probe_Store2Tests.swift:63:9: Expectation failed: file != nil
  status: Couldn't open “report.pdf”: its content isn't available.
```
`failedSendDraftAttachmentOpensBeforeRelaunch` passes.

## Why expected
README ✅: "A message that fails to send is never resent automatically. It is kept in Drafts on this Mac instead." The status line says "It's in Drafts on this Mac". A kept message whose files are silently lost at the next launch is data loss: those files may exist nowhere else, because they were dragged from Photos as file promises.

## Likely cause
`Sources/MailModel/MailStore.swift:735-736`: `failed()` calls `add(m)` (persisted, because the account is a server account) and `setAttachmentData(...)`, which is the in-memory `localAttachments` dictionary (`MailStore.swift:933`, "For sample data and tests"). Nothing writes the data to the database. `attachmentFile` (`MailStore.swift:951-957`) then has no local data and no `remoteID`, and fails.

## Also seen by
Another probe hunt found the same root cause (`probeFailedSendDraftKeepsItsAttachmentsAfterRelaunch` in `specs/bugs/probes/`).
