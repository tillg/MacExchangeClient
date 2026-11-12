---
title: 'Mail of a folder removed on the server stays: shown in Flagged and search, and a selected removed folder has a blank title'
priority: P3
area: MailStore
status: open
found: 2026-11-12
---
## Summary
`setRemoteFolders` (run once per session, i.e. at the next launch after the folder was deleted on the server) drops the folder from the tree but leaves its messages, sync token and completion flag. The messages are unreachable in the sidebar yet still count in Flagged, appear in search results and conversations, and stay in the database forever. If the removed folder was the selected mailbox, the window title becomes empty.

## Repro
```swift
import Foundation
import Testing
@testable import MailModel

@MainActor
struct Probe_SyncTests {
    let work = Account(name: "Work", address: "me@work.com")
    let home = Account(name: "iCloud", address: "me@icloud.com")

    func store(_ msgs: [Message] = []) -> MailStore { MailStore(accounts: [work, home], messages: msgs) }

    /// Like an EWS list summary: no body, recipients as display names only (EWSBackend.message).
    func remote(_ rid: String, subject: String = "Hi", read: Bool = false, minutesAgo: Double = 0,
                flag: FlagColor? = nil) -> Message {
        var m = Message(accountID: work.id, from: Contact(name: "Ann", email: "ann@x.com"),
                        to: [Contact(name: "Me", email: "")], cc: [Contact(name: "Bob", email: "")],
                        subject: subject, body: "", date: Date(timeIntervalSince1970: 1_000_000 - minutesAgo * 60),
                        isRead: read, flag: flag, remoteID: rid, bodyLoaded: false)
        m.serverPreview = "preview"
        return m
    }

    func page(_ ups: [Message] = [], del: [String] = [], reads: [String: Bool] = [:], token: String = "t",
              more: Bool = false) -> SyncResult {
        SyncResult(upserts: ups, deletedRemoteIDs: del, readChanges: reads, token: token, more: more)
    }

    func synced(_ rids: [String], in box: MailboxKind = .inbox) -> MailStore {
        let s = store()
        s.apply(page(rids.map { remote($0) }, token: "t0"), account: work.id, mailbox: box)
        return s
    }

    func id(_ s: MailStore, _ rid: String) -> Message.ID { s.messages.first { $0.remoteID == rid }!.id }

    /// A folder removed on the server: its mail must not linger in Flagged / search.
    @Test func mailOfARemovedServerFolderIsDropped() {
        let s = store()
        let x = MailboxKind.folder("X")
        s.setRemoteFolders([RemoteFolder(role: .inbox, id: "i"), RemoteFolder(role: x, id: "X", name: "Projects")],
                           account: work.id)
        s.apply(page([remote("A", subject: "Quarterly plan", flag: .red)], token: "x1"), account: work.id, mailbox: x)
        #expect(s.count(.smart(.flagged)) == 1)
        s.setRemoteFolders([RemoteFolder(role: .inbox, id: "i")], account: work.id)
        #expect(s.children(of: nil, account: work.id).isEmpty)
        #expect(s.count(.smart(.flagged)) == 0, "flagged mail of a deleted folder")
        s.searchText = "quarterly"
        #expect(s.visibleMessages.isEmpty, "search finds mail of a deleted folder")
    }

    /// Folder removed on the server while it is the selected mailbox: the title goes blank.
    @Test func selectedRemovedFolderKeepsATitle() {
        let s = store()
        let x = MailboxKind.folder("X")
        s.setRemoteFolders([RemoteFolder(role: .inbox, id: "i"), RemoteFolder(role: x, id: "X", name: "Projects")], account: work.id)
        s.selectedMailbox = .account(work.id, x)
        #expect(s.title == "Projects")
        s.setRemoteFolders([RemoteFolder(role: .inbox, id: "i")], account: work.id)  // next launch: folder gone
        #expect(s.title != "", "blank title, selection \(s.selectedMailbox)")
    }
}
```

## Expected vs actual
Expected: after the folder is gone, Flagged count 0, search for its mail finds nothing; the selection moves off the removed folder (non-empty title). Actual: "flagged mail of a deleted folder", "search finds mail of a deleted folder", "blank title, selection .account(…, folder:X)".

Actual (`swift test --filter Probe_SyncTests`, run 2026-11-12):
```
Test selectedRemovedFolderKeepsATitle() recorded an issue at Probe_SyncTests.swift:247:9: Expectation failed: s.title != ""
    blank title, selection .account(A9D6773E-D6B2-49DA-85F6-C3E779AF88FD, MailModel.MailboxKind(rawValue: "folder:X"))
    s.title != "" → false
      s.title → ""
Test selectedRemovedFolderKeepsATitle() failed after 3.576 seconds with 1 issue.
Test mailOfARemovedServerFolderIsDropped() recorded an issue at Probe_SyncTests.swift:161:9: Expectation failed: s.count(.smart(.flagged)) == 0
    flagged mail of a deleted folder
    s.count(.smart(.flagged)) == 0 → false
      s.count(.smart(.flagged)) → 1
Test mailOfARemovedServerFolderIsDropped() recorded an issue at Probe_SyncTests.swift:163:9: Expectation failed: s.visibleMessages.isEmpty
    search finds mail of a deleted folder
    s.visibleMessages.isEmpty → false
      s.visibleMessages → [MailModel.Message(id: DF6659DD-AE44-4725-A0B5-D31F0B2D9EEB, accountID: 86FA64BA-F5EA-4493-B23F-ADB6F025B6E7, mailbox: MailModel.MailboxKind(rawValue: "folder:X"), from: MailModel.Contact(name: "Ann", email: "ann@x.com"), to: [MailModel.Contact(name: "Me", email: "")], cc: [MailModel.Contact(name: "Bob", email: "")], subject: "Quarterly plan", body: "", date: 1970-01-12 13:46:40 +0000, isRead: false, flag: Optional(MailModel.FlagColor.red), category: MailModel.MailCategory.primary, isVIP: false, attachments: [], remoteID: Optional("A"), hasAttachments: false, serverPreview: Optional("preview"), bodyLoaded: false, isInvite: nil, invite: nil, html: nil, htmlChecked: nil, conversationID: nil)]
      isEmpty → false
Test mailOfARemovedServerFolderIsDropped() failed after 3.760 seconds with 2 issues.
```

## Why expected
- README: "your own mail folders and subfolders" are synced; a folder gone from the server has no mail on it. ⚠️ (recalled) Mail removes a mailbox and its messages when it is deleted on the server.
- Distinct from BUG-025 (folders moved into Trash still exist on the server and keep their ID); here the folder no longer exists at all.

## Likely cause
`Sources/MailModel/MailStore.swift:107-110` (`setRemoteFolders`) replaces `remoteFolders`/`folders` only; nothing removes messages, tokens (`syncTokens`, `complete`) or the selection for folders that disappeared.

## Also seen by
Another probe hunt found the same root cause (`probeMailOfFolderDeletedOnServerGoesAway` in `specs/bugs/probes/`).
