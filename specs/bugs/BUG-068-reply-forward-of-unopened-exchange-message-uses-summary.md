---
title: "Reply / Reply All / Forward on an Exchange message that hasn't been opened yet: empty To, 'Ann Lee <>' attribution, nothing quoted, wrong When-Adding-Recipients answer"
priority: P3
area: MailStore
status: open
found: 2026-11-12
---
## Summary
`draft(_:to:)` builds the reply from whatever is in memory. For an Exchange message whose body has not been loaded, that is only the list summary: names without addresses (EWS FindItem/SyncFolderItems) and an empty `body`. The reply then has an empty To field, the attribution line reads `Ann Lee <> wrote:`, and the quote is empty. A forward has an empty forwarded text. Reply All gives a To list of empty addresses. The same summary data feeds `addsNewRecipient`: until the body is loaded, the original's known addresses are empty, so writing to the original sender counts as a new recipient. Include Attachments With Replies ▸ When Adding Recipients then adds the files.

## Repro
Tests: `replyToUnopenedServerMessageHasAddressAndQuote`, `forwardOfUnopenedServerMessageQuotesIt`, `replyToSenderOfUnopenedMessageIsNotANewRecipient` in `specs/bugs/probes/Probe_Store2Tests.swift`.

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

    /// Reply from the list's context menu on a server message that was never opened: only the summary is there.
    @Test func replyToUnopenedServerMessageHasAddressAndQuote() {
        let s = store([])
        s.merge([summary(work, "A")], account: work.id, mailbox: .inbox)
        let id = s.messages[0].id
        let d = s.draft(.reply, to: id)
        #expect(d.to.contains("@"), "to: '\(d.to)'")
        #expect(d.body.contains("Friday"), "body: \(d.body)")
    }
    @Test func forwardOfUnopenedServerMessageQuotesIt() {
        let s = store([])
        s.merge([summary(work, "A")], account: work.id, mailbox: .inbox)
        let d = s.draft(.forward, to: s.messages[0].id)
        #expect(d.body.contains("Friday"), "body: \(d.body)")
    }
    /// Include Attachments With Replies ▸ When Adding Recipients: replying to the original sender of an unopened
    /// message is not "adding a recipient".
    @Test func replyToSenderOfUnopenedMessageIsNotANewRecipient() {
        var m = summary(work, "A"); m.hasAttachments = true
        let s = store([])
        s.merge([m], account: work.id, mailbox: .inbox)
        var d = s.draft(.reply, to: s.messages[0].id)
        d.to = "Ann Lee <ann@x.com>"  // the sender, typed by hand because To was empty
        s.setBody(MessageBody(text: "Hi", attachments: ["a.pdf"], from: Contact(name: "Ann Lee", email: "ann@x.com")),
                  for: s.messages[0].id)  // what the server really has
        let afterLoad = s.addsNewRecipient(d)
        // Same question before the body was loaded:
        let s2 = store([])
        s2.merge([m], account: work.id, mailbox: .inbox)
        var d2 = s2.draft(.reply, to: s2.messages[0].id); d2.to = "Ann Lee <ann@x.com>"
        #expect(afterLoad == false)
        #expect(s2.addsNewRecipient(d2) == false)
    }
}
```

## Expected vs actual
Expected: the reply goes to the sender's address and quotes the message, as it does after the message has been opened.
Actual:
```
replyToUnopenedServerMessageHasAddressAndQuote(): Expectation failed: d.to.contains("@")
  to: ''
replyToUnopenedServerMessageHasAddressAndQuote(): Expectation failed: d.body.contains("Friday")
  body:
   On 12. Jan 1970 at 14:46, Ann Lee <> wrote:
forwardOfUnopenedServerMessageQuotesIt(): Expectation failed: d.body.contains("Friday")
  body:
   Begin forwarded message:
```
```
replyToSenderOfUnopenedMessageIsNotANewRecipient(): Expectation failed: s2.addsNewRecipient(d2) == false
    s2.addsNewRecipient(d2) → true
```
(The same question after `setBody` with the real From gives `false`, which is correct.)

## Why expected
Reachable: the list's context menu (`Sources/MailReplica/MessageListView.swift:166-168`) offers Reply / Reply All / Forward on any row and calls `store.draft` with no `loadBody`. ⌘R straight after selecting a message, before its body arrives, does the same. `EWSBackend.summaryProps` documents that "FindItem and SyncFolderItems return names only for From/To, no addresses" (`Sources/EWS/EWSBackend.swift:10`). In Mail, replying to a message that was never opened still addresses and quotes it. The summary fixture in `EWSParsingTests.swift:21` (`<t:From><t:Mailbox><t:Name>Carol</t:Name></t:Mailbox></t:From>`) and `EWSBackend.names()` (`EWSBackend.swift:536-539`, `email: ""`) confirm that a summary has no addresses. specs/system/limitations.md lists "Bodies are fetched only when a message is shown, so most stored mail has no body to … quote offline". This bug is the online case: the store never fetches the body before building a reply, and the missing addresses are not covered by that limitation.

## Likely cause
`Sources/MailModel/MailStore.swift:1207-1225`: `draft()` reads `m.from.email`, `m.to`/`m.cc` and `m.body` without checking `m.needsBody`. It has no async path that loads the body first, as `includeOriginalAttachments` does for attachments (`MailStore.swift:1279`). `addsNewRecipient` (`MailStore.swift:1236-1242`) likewise trusts `m.from/m.to/m.cc` of an unloaded summary.
