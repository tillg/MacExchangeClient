---
title: 'Senders without a display name appear as "a@x.com <a@x.com>" in the forward header, the reply attribution and an invite answer''s To'
priority: P4
area: MailStore
status: open
found: 2026-11-13
---
## Summary
When Exchange gives a mailbox without a Name, `EWSBackend` uses the address as the name. Notification and no-reply mail is often like this. The compose texts then repeat the address: "From: noreply@shop.com <noreply@shop.com>", "On …, noreply@shop.com <noreply@shop.com> wrote:", and an invite answer's To shows "org@x.com <org@x.com>".

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

    /// Exchange gives a sender without a display name the address as name (EWSBackend contact()). The forward
    /// header and the reply attribution then show the address twice.
    @Test func forwardHeaderShowsAddressOnceWhenThereIsNoName() {
        let m = msg(work, from: Contact(name: "noreply@shop.com", email: "noreply@shop.com"))
        let s = store([m])
        let f = s.draft(.forward, to: m.id).body
        let r = s.draft(.reply, to: m.id).body
        #expect(!f.contains("noreply@shop.com <noreply@shop.com>"), "forward: \(f.debugDescription)")
        #expect(!r.contains("noreply@shop.com <noreply@shop.com>"), "reply: \(r.debugDescription)")
        // A sender with no name at all: no empty name before the address.
        let n = msg(work, subject: "N", from: Contact(name: "", email: "bot@shop.com"))
        let s2 = store([n])
        let f2 = s2.draft(.forward, to: n.id).body
        #expect(!f2.contains("From:  <"), "forward, empty name: \(f2.debugDescription)")
    }

    @Test func answerDraftShowsOrganizerAddressOnce() {
        var m = msg(work, subject: "Sync")
        m.invite = Invite(start: Date(timeIntervalSince1970: 2_000_000), end: Date(timeIntervalSince1970: 2_003_600),
                          organizer: Contact(name: "org@x.com", email: "org@x.com"))
        let s = store([m])
        let d = s.answerDraft(.accept, to: m.id)
        #expect(d.to != "org@x.com <org@x.com>", "To: \(d.to)")
    }

}
```

## Expected vs actual
Expected: the address once. Actual:
```
Expectation failed: !f.contains("noreply@shop.com <noreply@shop.com>")
Expectation failed: !r.contains("noreply@shop.com <noreply@shop.com>")
Expectation failed: d.to != "org@x.com <org@x.com>"   d.to → "org@x.com <org@x.com>"
forward, empty name: "\n\nBegin forwarded message:\n\nFrom:  <bot@shop.com>\nSubject: N\n…"
```

## Why expected
`EWSBackend.swift:544`: `Contact(name: name.isEmpty ? mail : name, email: mail)`, so name == email is the normal form of a nameless sender. Mail writes such a sender's address once (⚠️ from memory of Mail). `Contact.parseList` also sets name = email for a bare address.

## Likely cause
`MailStore.swift` `draft(_:to:)`: `"From: \(m.from.name) <\(m.from.email)>"` and `"…, \(m.from.name) <\(m.from.email)> wrote:"`; `answerDraft`: `"\(name) <\(email)>"`. None checks `name == email` or an empty name. An empty name gives "From:  <bot@shop.com>" (probed too).
