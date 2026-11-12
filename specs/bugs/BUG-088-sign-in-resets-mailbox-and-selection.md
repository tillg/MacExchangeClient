---
title: "Signing in another account always jumps to All Inboxes and clears the selection, even when no sample account was removed"
priority: P4
area: MailStore
status: open
found: 2026-11-12
---
## Summary
`removeLocalAccounts()` sets `selection = []` and `selectedMailbox = .smart(.allInboxes)` unconditionally. When the user adds a second Exchange account (no sample data left), the mailbox and message they were reading are thrown away although nothing was removed.

## Repro
Tests: `removeLocalAccountsWithNothingLocalKeepsTheView` in `specs/bugs/probes/Probe_Store2Tests.swift`.

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

    /// Signing in a further account resets what the user is looking at although nothing was removed.
    @Test func removeLocalAccountsWithNothingLocalKeepsTheView() {
        let s = MailStore(accounts: [], messages: [])
        let backend = EWSBackend(client: EWSClient(url: URL(string: "https://example.invalid/EWS/Exchange.asmx")!,
                                                   username: "u", password: "p"))
        s.add(work, backend: backend)
        var r = msg(work, .sent); r.remoteID = "R1"
        s.merge([r], account: work.id, mailbox: .sent)
        s.selectedMailbox = .account(work.id, .sent)
        s.selection = [s.messages[0].id]
        s.removeLocalAccounts()
        #expect(s.selectedMailbox == .account(work.id, .sent))
        #expect(s.selection == [s.messages[0].id])
    }
}
```

## Expected vs actual
Expected: with nothing removed, mailbox and selection stay.
Actual:
```
removeLocalAccountsWithNothingLocalKeepsTheView(): Expectation failed: s.selectedMailbox == .account(work.id, .sent)
  s.selectedMailbox → .smart(MailModel.SmartMailbox.allInboxes)
Expectation failed: s.selection == [s.messages[0].id]
  s.selection → []
```
(The store has a real `EWSBackend` attached so the account counts as a server account. No request is made: the probe never enqueues, refreshes or loads.)

## Why expected
The function's job (doc comment) is to drop sample accounts and their messages. Resetting the view only makes sense when the selected mailbox or messages belonged to them.

## Likely cause
`Sources/MailModel/MailStore.swift:471-472`: unconditional reset. It should only reset when `local` is non-empty and the selection or mailbox referred to a removed account.
