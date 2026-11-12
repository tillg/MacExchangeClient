---
title: "After a failed Save Draft the status says \"Couldn't send …\"; with no subject it reads \"Couldn't send “”\""
priority: P4
area: MailStore
status: open
found: 2026-11-12
---
## Summary
`failed()` uses one status text for `.send` and `.saveDraft`, built from the raw subject. When Save Draft fails, the user reads that their message couldn't be *sent*. Without a subject, the quotes are empty, while the kept draft itself is called "(No Subject)".

## Repro
Tests: `failedSaveDraftDoesNotSayCouldntSend`, `failedSendWithEmptySubjectNamesIt` in `specs/bugs/probes/Probe_Store2Tests.swift`.

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

    /// A failed Save Draft must not tell the user that a message couldn't be *sent*.
    @Test func failedSaveDraftDoesNotSayCouldntSend() {
        let s = store([])
        s.merge([(.inbox, [])], account: work.id)
        let d = Draft(accountID: work.id, to: "bo@x.com", subject: "Plan", body: "draft text")
        s.failed(PendingChange(account: work.id, change: .saveDraft(d), previous: []), "busy")
        #expect(s.status?.contains("send") != true, "status: \(s.status ?? "nil")")
    }
    @Test func failedSendWithEmptySubjectNamesIt() {
        let s = store([])
        s.merge([(.inbox, [])], account: work.id)
        s.failed(PendingChange(account: work.id, change: .send(Draft(accountID: work.id, to: "a@x.com", body: "b")), previous: []), "busy")
        #expect(s.status?.contains("“”") != true, "status: \(s.status ?? "nil")")
    }
}
```

## Expected vs actual
Actual:
```
failedSaveDraftDoesNotSayCouldntSend(): status: Couldn't send “Plan”: busy. It's in Drafts on this Mac.
failedSendWithEmptySubjectNamesIt(): status: Couldn't send “”: busy. It's in Drafts on this Mac.
```

## Why expected
The message was never meant to be sent, so the text is wrong. The same function names the kept draft "(No Subject)" two lines above.

## Likely cause
`Sources/MailModel/MailStore.swift:737`: `status = "Couldn't send “\(d.subject)”: …"` for both cases, raw `d.subject`.

## Also seen by
Another probe hunt found the same root cause ( in `specs/bugs/probes/`).
