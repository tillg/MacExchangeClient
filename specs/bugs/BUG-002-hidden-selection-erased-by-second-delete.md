---
title: Delete keeps a selection that is no longer in the list; a second Delete erases the message from Trash unseen
priority: P1
area: MailStore
status: open
found: 2026-11-12
---
## Summary
When the selected message is not in the visible list (hidden by the unread filter or a search, or deleted by swipe/context menu, which call `delete(ids)` directly), `deleteSelection()` moves it to Trash but leaves it selected. The viewer keeps showing it, so a second ⌘⌫ erases it permanently from Trash without the user ever seeing it there.

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

    @Test func deletingTwiceAHiddenSelectionDoesNotEraseIt() {
        let a = msg(work, subject: "a", read: true, minutesAgo: 1), b = msg(work, subject: "b", minutesAgo: 2)
        let s = store([a, b])
        s.selectedMailbox = .account(work.id, .inbox)
        s.selection = [a.id]
        s.filterUnread = true  // a is read: hidden now, still selected
        s.deleteSelection()
        #expect(s.message(a.id)?.mailbox == .trash)
        #expect(!s.selection.contains(a.id))
        s.deleteSelection()
        #expect(s.message(a.id) != nil, "second ⌘⌫ erased a message the user never saw in Trash")
    }

    @Test func swipeDeleteThenDeleteKeyDoesNotEraseIt() {
        let a = msg(work, subject: "a", minutesAgo: 1), b = msg(work, subject: "b", minutesAgo: 2)
        let s = store([a, b])
        s.selectedMailbox = .account(work.id, .inbox)
        s.selection = [a.id]
        s.delete([a.id])          // swipe ▸ Trash / context menu Delete on the selected row
        s.deleteSelection()       // ⌘⌫
        #expect(s.message(a.id) != nil, "erased from Trash without ever being shown there")
    }

    @Test func searchHidingTheSelectionThenDeleteTwiceDoesNotEraseIt() {
        let a = msg(work, subject: "alpha", minutesAgo: 1), b = msg(work, subject: "beta", minutesAgo: 2)
        let s = store([a, b])
        s.selectedMailbox = .account(work.id, .inbox)
        s.selection = [a.id]
        s.searchText = "beta"
        s.deleteSelection()
        s.deleteSelection()
        #expect(s.message(a.id) != nil)
    }
}
```

## Expected vs actual
Expected: after the first Delete the trashed message is no longer selected (or the selection moves on), so the second Delete can't erase it. Actual:
```
Test deletingTwiceAHiddenSelectionDoesNotEraseIt() recorded an issue at Probe_StoreCoreTests.swift:53:9: Expectation failed: !s.selection.contains(a.id)
Test deletingTwiceAHiddenSelectionDoesNotEraseIt() recorded an issue at Probe_StoreCoreTests.swift:55:9: Expectation failed: s.message(a.id) != nil
  second ⌘⌫ erased a message the user never saw in Trash
  s.message(a.id) → nil
Test swipeDeleteThenDeleteKeyDoesNotEraseIt() ... Expectation failed: s.message(a.id) != nil  → s.message(a.id) → nil
Test searchHidingTheSelectionThenDeleteTwiceDoesNotEraseIt() ... Expectation failed: s.message(a.id) != nil  → s.message(a.id) → nil
```

## Why expected
README Behaviour: "Delete goes to the account's Trash and deleting from Trash erases; … next message selected after an action". In Mail a deleted message never stays selected; erasing needs the user to be looking at Trash. Here Delete twice on the same (still displayed) message silently erases it — local mail is gone for good, Exchange mail goes to Recoverable Items.

## Likely cause
`Sources/MailModel/MailStore.swift:403-414` (`actOnSelection`): when no selected ID is in the visible list, `lastIdx` is nil and `selection` is left untouched, still holding the acted-on IDs. `delete(_:)` (line 372, used by swipe and the context menu) never removes the deleted/erased IDs from `selection` either. `delete` then erases whatever selected message is in Trash (line 373). Contrast: `merge` does `selection.subtract(ids)` for messages it removes (pinned by `applyDeletesByRemoteIDAndDropsFromSelection`), and `MessageViewer` clears the selection by hand on a mailbox switch – `delete`/`actOnSelection` do neither.

Caveat (not observed in the running app): the probes prove the model state only. Whether SwiftUI's `List(selection:)` prunes a selected ID whose row disappeared was not checked; the P1 rating assumes it does not (the viewer shows `selectedMessage`, which still resolves).
