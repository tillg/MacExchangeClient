---
title: Subfolders of Trash (deleted folders) are treated as live mail – shown in conversations and in Flagged
priority: P3
area: MailStore
status: open
found: 2026-11-12
---
## Summary
Exchange moves a deleted folder into Deleted Items, so its mail sits in a subfolder of Trash (EWS parsing gives it `parent: .trash`). Conversations, the Flagged smart mailbox (and its count) only exclude `.trash` itself, so mail in deleted folders appears in the thread ("Found in Old") and in Flagged.

## Repro
```swift
import Foundation
import Testing
@testable import MailModel

@MainActor
struct Probe_StoreCoreTests {
    let work = Account(name: "Work", address: "me@work.com")
    let home = Account(name: "iCloud", address: "me@icloud.com")

    func msg(_ acct: Account, _ box: MailboxKind = .inbox, subject: String = "Hi", from: String = "Ann",
             read: Bool = false, minutesAgo: Double = 0, flag: FlagColor? = nil, rid: String? = nil,
             conv: String? = nil) -> Message {
        var m = Message(accountID: acct.id, mailbox: box, from: Contact(name: from, email: "\(from.lowercased())@x.com"),
                        to: [Contact(name: "Me", email: acct.address)], subject: subject, body: "Body of \(subject)",
                        date: Date(timeIntervalSince1970: 1_000_000 - minutesAgo * 60), isRead: read, flag: flag,
                        remoteID: rid)
        m.conversationID = conv
        return m
    }

    func store(_ msgs: [Message]) -> MailStore { MailStore(accounts: [work, home], messages: msgs) }

    @Test func conversationLeavesOutTrashSubfolders() {
        let deleted = MailboxKind.folder("D")
        let a = msg(work, subject: "a", minutesAgo: 1, rid: "1", conv: "C"),
            b = msg(work, deleted, subject: "b", minutesAgo: 2, rid: "2", conv: "C")
        let s = store([a, b])
        s.setFolders([Folder(box: deleted, name: "Old", parent: .trash)], account: work.id)
        #expect(s.conversation(of: a.id).map(\.id) == [a.id])
    }

    @Test func flaggedLeavesOutTrashSubfolders() {
        let deleted = MailboxKind.folder("D")
        let a = msg(work, deleted, flag: .red)
        let s = store([a])
        s.setFolders([Folder(box: deleted, name: "Old", parent: .trash)], account: work.id)
        #expect(s.count(.smart(.flagged)) == 0)
    }
}
```

## Expected vs actual
```
Test conversationLeavesOutTrashSubfolders() recorded an issue at Probe_StoreCoreTests.swift:106:9: Expectation failed: s.conversation(of: a.id).map(\.id) == [a.id]
  s.conversation(of: a.id).map(\.id) → [03197C04-…, FE856C31-…]
Test flaggedLeavesOutTrashSubfolders() recorded an issue at Probe_StoreCoreTests.swift:258:9: Expectation failed: s.count(.smart(.flagged)) == 0
  s.count(.smart(.flagged)) → 1
```

## Why expected
README Conversations: "from every mailbox of the account except Trash, Junk and Drafts"; Flagged excludes Trash (`contains`). Mail inside Trash's subfolders is deleted mail just the same (⚠️ from memory: Outlook also hides it from these views). Reachable: `EWSBackend.folderTree` only skips Outbox, so subfolders of Deleted Items arrive with `parent: .trash` (`EWSBackend.swift:41, 443-467`).

## Likely cause
`Sources/MailModel/MailStore.swift:296` (`skip: Set<MailboxKind> = [.trash, .junk, .drafts]`) and `:116` / `:149` (`m.mailbox != .trash`) compare the mailbox only, never walking the folder's `parent` chain in `folders[account]`.
