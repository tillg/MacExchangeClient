---
title: 'A second New Message (or a second Reply to the same message) brings the first compose window forward instead of opening a new one'
priority: P4
area: Models
status: open
found: 2026-11-13
---
## Summary
Compose windows are `WindowGroup("New Message", id: "compose", for: Draft.self)` opened with `openWindow(id:value:)`. SwiftUI reuses a window that already presents an equal value. Two New Message drafts for the same account, or two replies to the same message, are equal `Draft` values, so the second command focuses the first window, which may hold a half-written message, instead of opening a second one as Mail does.

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

    /// The compose WindowGroup is `WindowGroup(for: Draft.self)` and is opened with `openWindow(id:value:)`; SwiftUI
    /// brings an existing window to the front when one already presents an equal value. Two New Message
    /// commands (or Reply twice to the same message) must produce different values to open two windows.
    @Test func twoNewMessagesAreDistinctWindowValues() {
        let s = store([msg(work)])
        let a = Draft(accountID: s.accounts[0].id), b = Draft(accountID: s.accounts[0].id)
        #expect(a != b, "two New Message drafts are equal values")
        let id = s.messages[0].id
        #expect(s.draft(.reply, to: id) != s.draft(.reply, to: id), "two replies to one message are equal values")
    }

}
```

## Expected vs actual
The probe shows the precondition: the values are equal.
```
Expectation failed: a != b   (two New Message drafts are equal values)
Expectation failed: s.draft(.reply, to: id) != s.draft(.reply, to: id)
```
The single-window result is inferred from SwiftUI's documented `openWindow(id:value:)`/`WindowGroup(for:)` behaviour (an existing window presenting the value is brought to the front). It was not checked by running the app, because the snapshot hook can't drive menu commands.

## Why expected
In Mail, ⌘N always opens a fresh message, and replying twice gives two windows. `ComposeView` keeps its own `@State draft`, so the window's presented value stays the initial one even after typing, and every later ⌘N for that account matches it.

## Likely cause
`MailReplicaApp.swift:33` (`WindowGroup(... for: Draft.self)`) together with `MailCommands.swift:15`, `MessageViewer.swift:59` and the reply call sites passing a `Draft` with no per-window identity. `Draft` (`Models.swift`) has no unique ID field, so equal content means the same window.
