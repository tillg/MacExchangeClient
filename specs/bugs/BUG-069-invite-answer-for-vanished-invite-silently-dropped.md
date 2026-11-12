---
title: "Respond with Comments: if the invite is gone by the time you press Send, the answer and comment vanish without a word"
priority: P3
area: Invite
status: open
found: 2026-11-12
---
## Summary
The compose window for an invite answer holds only the invite's local message ID. If the message leaves memory before Send (a sync reports it deleted, for example because it was answered in Outlook or on the phone, or it is erased from Trash), `send()` → `respond()` → `answer()` returns at its guard. Nothing is queued, no status is shown, and the compose window closes as if the answer had gone out.

## Repro
Tests: `answerDraftForVanishedInviteIsNotSilentlyDropped` in `specs/bugs/probes/Probe_Store2Tests.swift`.

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

    /// Respond with Comments, then the invite is gone (sync deleted it / erased) before Send: the comment and
    /// the answer silently vanish.
    @Test func answerDraftForVanishedInviteIsNotSilentlyDropped() {
        var m = msg(work); m.remoteID = "INV"; m.invite = invite(); m.isInvite = true
        let s = store([m])
        s.merge([(.inbox, [])], account: work.id)
        var d = s.answerDraft(.decline, to: m.id)
        d.body = "Sorry, I am out that week."
        s.merge([], deleted: ["INV"], account: work.id, mailbox: .inbox)  // removed elsewhere meanwhile
        s.send(d)
        #expect(!s.outbox.isEmpty || s.status != nil, "outbox: \(s.outbox.count), status: \(s.status ?? "nil")")
    }
}
```

## Expected vs actual
Expected: the answer is still sent, or the user is told it couldn't be.
Actual:
```
answerDraftForVanishedInviteIsNotSilentlyDropped(): Expectation failed: !s.outbox.isEmpty || s.status != nil
  outbox: 0, status: nil
```

## Why expected
Every other failure path in the store reports in `status` ("Couldn't send …", "Exchange refused a change", "The proposed meeting must end after it starts."). The user typed a comment for the organizer, and losing it silently means the organizer is never told.

## Likely cause
`Sources/MailModel/MailStore.swift:885`: `guard let old = message(id), old.invite != nil else { return }` with no status. `send()` (`MailStore.swift:1334-1337`) hands over only `a.messageID`, so the remote ID isn't kept in the draft either.
