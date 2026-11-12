---
title: 'Closing a forward while its original files are still loading: Save in the sheet throws the message away'
priority: P2
area: MailStore
status: open
found: 2026-11-13
---
## Summary
While a forward (or a reply that includes the attachments) is still downloading the original's files, closing the window shows "Save this message as a draft?". Save calls `store.saveDraft`, which refuses while files are loading (it only sets a status line), and then the sheet closes the window anyway. The text the user typed and the recipients are lost: there is nothing in Drafts and nothing in the outbox.

## Repro
```swift
import Foundation
import Testing
@testable import EWS
@testable import MailModel

@MainActor
struct Probe_ComposeTests {
    let work = Account(name: "Work", address: "me@work.com")
    let home = Account(name: "iCloud", address: "me@icloud.com")
    let mark = String(Draft.fileMark)

    func msg(_ acct: Account, _ box: MailboxKind = .inbox, subject: String = "Hi", from: Contact? = nil,
             to: [Contact]? = nil, cc: [Contact] = [], body: String = "Body") -> Message {
        Message(accountID: acct.id, mailbox: box, from: from ?? Contact(name: "Ann", email: "ann@x.com"),
                to: to ?? [Contact(name: "Me", email: acct.address)], cc: cc, subject: subject, body: body,
                date: Date(timeIntervalSince1970: 1_000_000))
    }

    func store(_ msgs: [Message]) -> MailStore { MailStore(accounts: [work, home], messages: msgs) }

    func png(_ name: String, _ bytes: Int = 4) -> DraftAttachment {
        DraftAttachment(name: name, contentType: "image/png", data: Data(repeating: 7, count: bytes))
    }

    /// Closing a forward whose original files are still downloading: the window's sheet offers Save, which calls
    /// `saveDraft` and closes the window. `saveDraft` refuses while files load, so the text typed is lost.
    @Test func saveDraftWhileOriginalFilesLoadKeepsTheText() {
        let original = msg(home, subject: "Contract")
        let s = store([original])
        var d = s.draft(.forward, to: original.id)
        d.loadingOriginal = original.id  // still downloading
        d.to = "bo@x.com"
        d.body = "Please sign by Friday." + d.body
        s.saveDraft(d)
        #expect(s.messages.contains { $0.mailbox == .drafts && $0.body.contains("Please sign") },
                "drafts: \(s.messages.filter { $0.mailbox == .drafts }.map(\.subject)), status: \(s.status ?? "nil")")
        // Same on Exchange: nothing is queued either.
        let x = store([])
        x.merge([(.inbox, [msg(work, subject: "Contract")])], account: work.id)
        var e = x.draft(.forward, to: x.messages[0].id)
        e.loadingOriginal = x.messages[0].id
        e.to = "bo@x.com"; e.body = "Please sign by Friday." + e.body
        x.saveDraft(e)
        #expect(!x.outbox.isEmpty || x.messages.contains { $0.mailbox == .drafts },
                "Exchange: outbox \(x.outbox.count), drafts \(x.messages.filter { $0.mailbox == .drafts }.count), status: \(x.status ?? "nil")")
    }

}
```

## Expected vs actual
Expected: Save keeps the message, in Drafts or queued for Exchange, or the window stays open. Actual (local account and Exchange account):
```
Expectation failed: s.messages.contains { $0.mailbox == .drafts && $0.body.contains("Please sign") }
  drafts: [], status: This message contains attachments that are still being loaded.
Expectation failed: !x.outbox.isEmpty || x.messages.contains { $0.mailbox == .drafts }
  Exchange: outbox 0, drafts 0, status: This message contains attachments that are still being loaded.
```
The probe shows the store side: `saveDraft` keeps nothing. The window-close side is `ComposeView.shouldClose`, which calls `window.close()` straight after `store.saveDraft(draft)` without checking that it saved. That part was read from the code; the app wasn't run.

## Why expected
README (feature list): "Closing a message you changed without sending it asks first, with Mail's sheet: 'Save this message as a draft?' (Save / Don't Save / Cancel)". Save must not discard. Mail's AttachmentsPendingMessage blocks Send and Save while files load, but it doesn't close the window. The toolbar's Save Draft is disabled while files load (`ComposeView.swift:98`); the close sheet's Save isn't. Downloading the files of a large Exchange forward takes seconds, so a user can hit this.

## Likely cause
`ComposeView.swift:210`: `case .alertFirstButtonReturn: store.saveDraft(draft); window.close()` closes whatever happened. `MailStore.saveDraft` (`MailStore.swift:~1394`) returns early through `attachmentsPending(d)` (`MailStore.swift:~1376`) when `d.loadingOriginal != nil`, and `saveDraft` returns no result the sheet could check.
