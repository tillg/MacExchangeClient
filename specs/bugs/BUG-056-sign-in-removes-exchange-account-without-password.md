---
title: "Signing in (e.g. to re-enter a missing password) removes an Exchange account that has no Keychain password; its mail stays in All Inboxes without an account"
priority: P2
area: MailStore
status: open
found: 2026-11-12
---
## Summary
`removeLocalAccounts()` treats every account without a backend as sample data. An Exchange account whose password is missing from the Keychain is connected without a backend (`AppSetup.connect`, else-branch: "No password in the Keychain for …"). The obvious fix for the user is Settings ▸ Accounts ▸ Sign In again, and that sign-in calls `removeLocalAccounts()`. The old account leaves `accounts` (and the sidebar), but its server messages (`remoteID != nil`) stay. They show in All Inboxes with no account behind them. Its local-only messages (drafts kept after failed sends) are removed from memory without `forget`: they are not in `takeChanges().removed`, so they stay in Mail.sqlite (second probe). Not shown by a probe, but read from `AccountsSettings.signIn`: it creates a new `ExchangeAccount` with a new UUID, so the re-added account then downloads all of the same mail again.

## Repro
Tests: `removeLocalAccountsKeepsExchangeAccountWithoutPassword`, `removeLocalAccountsDoesNotDropStoredDraftsOnlyFromMemory` in `specs/bugs/probes/Probe_Store2Tests.swift`.

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

    /// An Exchange account whose password is missing (connected without a backend) is not sample data: signing in
    /// a second account must not remove it while its mail stays in All Inboxes.
    @Test func removeLocalAccountsKeepsExchangeAccountWithoutPassword() {
        var r = msg(work); r.remoteID = "R1"
        let sample = msg(home, subject: "sample")
        let s = MailStore(accounts: [work, home], messages: [sample])
        s.merge([r], account: work.id, mailbox: .inbox)  // work's mail came from the server (or the database)
        s.removeLocalAccounts()
        let orphans = s.messages.filter { m in !s.accounts.contains { $0.id == m.accountID } }
        #expect(orphans.isEmpty, "messages without account: \(orphans.count); accounts: \(s.accounts.map(\.name))")
    }
    /// The same account's draft kept after a failed send (local, stored) is dropped from memory but not from disk.
    @Test func removeLocalAccountsDoesNotDropStoredDraftsOnlyFromMemory() {
        let s = MailStore(accounts: [work, home], messages: [])
        s.merge([(.inbox, [])], account: work.id)  // work: Exchange account (here without password/backend)
        s.failed(PendingChange(account: work.id, change: .send(Draft(accountID: work.id, to: "a@x.com", subject: "S")),
                               previous: []), "busy")
        let kept = s.messages[0].id
        _ = s.takeChanges()
        s.removeLocalAccounts()
        let removed = s.takeChanges().removed
        #expect(s.message(kept) != nil || removed.contains(kept),
                "in memory: \(s.message(kept) != nil), removed from disk: \(removed.contains(kept))")
    }
}
```

## Expected vs actual
Expected: only accounts without server mail (sample data) are removed, and no message is left without an account.
Actual:
```
removeLocalAccountsKeepsExchangeAccountWithoutPassword(): Expectation failed: orphans.isEmpty
  messages without account: 1; accounts: []
```
```
removeLocalAccountsDoesNotDropStoredDraftsOnlyFromMemory(): Expectation failed: s.message(kept) != nil || removed.contains(kept)
  in memory: false, removed from disk: false
```

## Why expected
The doc comment says "Drops accounts without a server (the sample data) and their local messages". An Exchange account without a password is not sample data. The store already tracks server accounts in `serverAccounts`, and `isStored` uses that set for exactly this distinction.

## Likely cause
`Sources/MailModel/MailStore.swift:467-473`: `let local = Set(accounts.filter { backends[$0.id] == nil }.map(\.id))` should exclude `serverAccounts`. The removal at line 470 also skips `forget(...)`. Caller: `Sources/MailReplica/AccountsSettings.swift:169`, and `AccountsSettings.swift:101-105` for the no-backend connect.

## Also seen by
Another probe hunt found the same root cause ( in `specs/bugs/probes/`).
