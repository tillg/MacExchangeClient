---
title: "A forward whose original files can't be fetched becomes sendable without them, with no message at all when the body couldn't be loaded"
priority: P3
area: MailStore
status: open
found: 2026-11-12
---
## Summary
`includeOriginalAttachments` always clears `loadingOriginal` at the end, whether or not the files arrived. Two cases:
- The original's body can't be loaded: `loadBody` returns early or fails, the attachment list stays empty, and the forward is released with no files. Offline, only a transient "Couldn't load message" status appears. For an account that is paused after a failed sign-in, or has no password (no backend), nothing is shown at all; the probe covers this case.
- One file of several can't be fetched: the forward is released with the rest. Only a transient status line says so.
In both cases Send is enabled and the recipient gets a forward without the attachments.

## Repro
Tests: `forwardWhoseFilesCannotLoadIsNotSilentlySendable`, `forwardWithOneUnavailableFileStaysBlocked` in `specs/bugs/probes/Probe_Store2Tests.swift`.

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

    /// Forward of an Exchange message whose files can't be fetched (body not loaded, account without
    /// connection): the forward must not become sendable without its files, silently.
    @Test func forwardWhoseFilesCannotLoadIsNotSilentlySendable() async {
        var m = summary(work, "A", subject: "Contract")
        m.hasAttachments = true
        let s = store([])
        s.merge([m], account: work.id, mailbox: .inbox)
        var d = s.draft(.forward, to: s.messages[0].id)
        #expect(d.loadingOriginal != nil)
        await s.includeOriginalAttachments(in: &d)
        #expect(d.loadingOriginal != nil || !d.attachments.isEmpty || s.status != nil,
                "loadingOriginal: \(String(describing: d.loadingOriginal)), files: \(d.attachments.count), status: \(s.status ?? "nil")")
    }
    /// One of two files can't be loaded: the forward is released with only the other one.
    @Test func forwardWithOneUnavailableFileStaysBlocked() async {
        var m = msg(work, subject: "Two files"); m.attachments = ["a.pdf", "b.pdf"]
        let s = store([m])
        s.downloadsFolder = tempDir()
        s.setAttachmentData([Data([1])], for: m.id)  // b.pdf's content can't be had
        var d = s.draft(.forward, to: m.id)
        await s.includeOriginalAttachments(in: &d)
        #expect(d.attachments.count == 2 || d.loadingOriginal != nil,
                "files: \(d.attachments.map(\.name)), loadingOriginal: \(String(describing: d.loadingOriginal)), status: \(s.status ?? "nil")")
    }
}
```

## Expected vs actual
Expected: the forward stays blocked (`loadingOriginal` kept) or the missing files are reported in the compose window.
Actual:
```
forwardWhoseFilesCannotLoadIsNotSilentlySendable(): Expectation failed: d.loadingOriginal != nil || !d.attachments.isEmpty || s.status != nil
  loadingOriginal: nil, files: 0, status: nil
forwardWithOneUnavailableFileStaysBlocked(): Expectation failed: d.attachments.count == 2 || d.loadingOriginal != nil
  files: ["a.pdf"], loadingOriginal: nil, status: Couldn't open “b.pdf”: its content isn't available.
```

## Why expected
README ✅: "Forward takes the original's attachments along … A forward can't be sent until the original's files have loaded." Store doc: "Mail's AttachmentsPendingMessage: a forward isn't sent or saved before its original files are in."

## Likely cause
`Sources/MailModel/MailStore.swift:1277-1287`: failures in `loadBody` / `attachmentFile` are skipped (`continue`) and `draft.loadingOriginal = nil` runs unconditionally. The `m.needsBody` branch doesn't check that the body actually arrived.
