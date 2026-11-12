---
title: "A message written for an account that no longer exists is silently sent (or saved) from the first other account"
priority: P3
area: MailStore
status: open
found: 2026-11-12
---
## Summary
`send()` and `saveDraft()` use `account(d.accountID) ?? accounts[0]`. If a compose window was opened for a sample account and the user then signs in to Exchange (which removes the sample accounts), pressing Send queues the message on the Exchange account. It goes out to real recipients from the real mailbox, while the draft still names the vanished account.

## Repro
Tests: `draftOfRemovedSampleAccountIsNotSentFromExchange` in `specs/bugs/probes/Probe_Store2Tests.swift`.

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

    /// Sending from an account that is no longer there (sample account removed by signing in) must not
    /// silently send from the remaining Exchange account.
    @Test func draftOfRemovedSampleAccountIsNotSentFromExchange() {
        let s = store([msg(home, subject: "sample")])
        let d = Draft(accountID: home.id, to: "bo@x.com", subject: "Test", body: "written in sample mode")
        let exchange = Account(name: "Exchange", address: "me@corp.com")
        s.removeLocalAccounts()  // sign-in: sample accounts go
        s.accounts.append(exchange)
        s.merge([(.inbox, [])], account: exchange.id)  // the Exchange account (server mail)
        s.send(d)
        let queued = s.outbox.filter { if case .send = $0.change { return true }; return false }
        #expect(queued.isEmpty, "queued sends: \(queued.map { s.account($0.account)?.name ?? "?" })")
    }
}
```

## Expected vs actual
Expected: no send is queued on another account; the user is told the account is gone.
Actual:
```
draftOfRemovedSampleAccountIsNotSentFromExchange(): Expectation failed: queued.isEmpty
  queued sends: ["Exchange"]
```

## Why expected
Silently changing the sending account sends mail the user wrote as a test from their real identity (P1 class "wrong mail sent"). The trigger is uncommon, so this is rated P3. Mail never switches the From account behind the user's back.

## Likely cause
`Sources/MailModel/MailStore.swift:1339` and `:1353`: `let acct = account(d.accountID) ?? accounts[0]`.
