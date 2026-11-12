---
title: A later list summary of an opened message replaces its sender/recipient addresses with names only (Reply/Reply All go to empty addresses) and brings back the paperclip
priority: P2
area: MailStore
status: open
found: 2026-11-12
---
## Summary
EWS list summaries carry From/To/Cc as display names only. When a message whose body was loaded (which filled in real addresses) is upserted again by a sync or by the newest-50 lookup, `merge` keeps the body but takes `from`/`to`/`cc`/`hasAttachments` from the summary. The body is never fetched again (`needsBody` stays false), so Reply goes to "" and Reply All to ", , ". (⚠️ recalled, not checked against a live server: Exchange can report HasAttachments for mail whose only files are inline, which the attachment list leaves out – then the paperclip comes back too.) For a folder still syncing, the quick check re-merges the newest 50 every 15 seconds and the summary always differs from the loaded message, so every opened recent message loses its addresses within 15 s.

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

    /// After the body is loaded the recipients carry addresses; a later summary upsert (e.g. read on the phone)
    /// must not replace them with display names only, since the body is never fetched again.
    @Test func laterSummaryKeepsTheRecipientAddressesOfALoadedBody() {
        // EWS summaries: From/To/Cc as names only (EWSBackend.summaryProps comment).
        func summary(read: Bool) -> Message { var m = remote("A", read: read); m.from = Contact(name: "Ann", email: ""); return m }
        let s = store()
        s.apply(page([summary(read: false)], token: "t0"), account: work.id, mailbox: .inbox)
        let a = id(s, "A")
        let from = Contact(name: "Ann", email: "ann@x.com")
        let to = [Contact(name: "Me", email: "me@work.com")], cc = [Contact(name: "Bob", email: "bob@y.com")]
        s.setBody(MessageBody(text: "Full", attachments: [], from: from, to: to, cc: cc), for: a)
        s.apply(page([summary(read: true)], token: "t1"), account: work.id, mailbox: .inbox)
        #expect(s.message(a)?.isRead == true)
        #expect(s.message(a)?.needsBody == false, "body is not fetched again")
        #expect(s.message(a)?.from == from)
        #expect(s.message(a)?.to == to)
        #expect(s.message(a)?.cc == cc)
        #expect(s.draft(.reply, to: a).to == "ann@x.com", "Reply after the sync: \(s.draft(.reply, to: a).to)")
        let d = s.draft(.replyAll, to: a)
        #expect(d.to.contains("bob@y.com"), "Reply All after the sync: \(d.to)")
    }

    /// The same through the newest-N lookup, which re-merges the newest 50 on every check of a folder whose
    /// full sync hasn't finished.
    @Test func newestLookupKeepsTheRecipientAddressesOfALoadedBody() {
        var sum = remote("A"); sum.from = Contact(name: "Ann", email: "")
        let s = store()
        s.merge([sum], account: work.id, mailbox: .inbox)
        let a = id(s, "A")
        s.setBody(MessageBody(text: "Full", attachments: [], from: Contact(name: "Ann", email: "ann@x.com"),
                              to: [Contact(name: "Me", email: "me@work.com")], cc: []), for: a)
        s.merge([sum], account: work.id, mailbox: .inbox)  // the next 15-second check: the same summary again
        #expect(s.draft(.reply, to: a).to == "ann@x.com", "Reply goes to: '\(s.draft(.reply, to: a).to)'")
    }

    /// Exchange can report HasAttachments for a message whose only files are inline (left out of the list):
    /// once the body showed there are no attachments, the next summary must not bring the paperclip back.
    @Test func laterSummaryKeepsWhatTheBodySaidAboutAttachments() {
        var sum = remote("A"); sum.hasAttachments = true
        let s = store()
        s.apply(page([sum], token: "t0"), account: work.id, mailbox: .inbox)
        let a = id(s, "A")
        s.setBody(MessageBody(text: "Full", attachments: []), for: a)
        #expect(s.message(a)?.hasAttachments == false)
        sum.isRead = true
        s.apply(page([sum], token: "t1"), account: work.id, mailbox: .inbox)
        #expect(s.message(a)?.hasAttachments == false, "paperclip back on a message without attachments")
    }
}
```

## Expected vs actual
Expected: after the second summary the message keeps the addresses from the body (`ann@x.com`, `me@work.com`, `bob@y.com`) and `hasAttachments == false`; Reply goes to `ann@x.com`. Actual: from/to/cc are the names-only summary values, Reply goes to "" and Reply All to ", , "; hasAttachments flips back to true.

Actual (`swift test --filter Probe_SyncTests`, run 2026-11-12):
```
Test laterSummaryKeepsWhatTheBodySaidAboutAttachments() recorded an issue at Probe_SyncTests.swift:373:9: Expectation failed: s.message(a)?.hasAttachments == false
    paperclip back on a message without attachments
    s.message(a)?.hasAttachments == false → false
      s.message(a)?.hasAttachments → true
        some → true
        some → false
Test laterSummaryKeepsTheRecipientAddressesOfALoadedBody() recorded an issue at Probe_SyncTests.swift:53:9: Expectation failed: s.message(a)?.from == from
    s.message(a)?.from == from → false
      s.message(a)?.from → Contact(name: "Ann", email: "")
        some → Contact(name: "Ann", email: "")
          name → "Ann"
          email → ""
      from → Contact(name: "Ann", email: "ann@x.com")
        name → "Ann"
        email → "ann@x.com"
Test laterSummaryKeepsTheRecipientAddressesOfALoadedBody() recorded an issue at Probe_SyncTests.swift:54:9: Expectation failed: s.message(a)?.to == to
    s.message(a)?.to == to → false
      s.message(a)?.to → [MailModel.Contact(name: "Me", email: "")]
        some → [MailModel.Contact(name: "Me", email: "")]
      to → [MailModel.Contact(name: "Me", email: "me@work.com")]
Test laterSummaryKeepsTheRecipientAddressesOfALoadedBody() recorded an issue at Probe_SyncTests.swift:55:9: Expectation failed: s.message(a)?.cc == cc
    s.message(a)?.cc == cc → false
      s.message(a)?.cc → [MailModel.Contact(name: "Bob", email: "")]
        some → [MailModel.Contact(name: "Bob", email: "")]
      cc → [MailModel.Contact(name: "Bob", email: "bob@y.com")]
Test laterSummaryKeepsTheRecipientAddressesOfALoadedBody() recorded an issue at Probe_SyncTests.swift:56:9: Expectation failed: s.draft(.reply, to: a).to == "ann@x.com"
    Reply after the sync: 
    s.draft(.reply, to: a).to == "ann@x.com" → false
      s.draft(.reply, to: a).to → ""
Test laterSummaryKeepsTheRecipientAddressesOfALoadedBody() recorded an issue at Probe_SyncTests.swift:58:9: Expectation failed: d.to.contains("bob@y.com")
    Reply All after the sync: , , 
    d.to.contains("bob@y.com") → false
      d.to → ", , "
Test newestLookupKeepsTheRecipientAddressesOfALoadedBody() recorded an issue at Probe_SyncTests.swift:71:9: Expectation failed: s.draft(.reply, to: a).to == "ann@x.com"
    Reply goes to: ''
    s.draft(.reply, to: a).to == "ann@x.com" → false
      s.draft(.reply, to: a).to → ""
Test laterSummaryKeepsTheRecipientAddressesOfALoadedBody() failed after 3.760 seconds with 5 issues.
Test newestLookupKeepsTheRecipientAddressesOfALoadedBody() failed after 3.760 seconds with 1 issue.
Test laterSummaryKeepsWhatTheBodySaidAboutAttachments() failed after 3.760 seconds with 1 issue.
```

## Why expected
- `MessageBody` doc (MailBackend.swift): "Sender and recipients are included because list summaries may lack email addresses." `EWSBackend.summaryProps`: "FindItem and SyncFolderItems return names only for From/To, no addresses." The body fetch exists precisely to get them.
- `merge`'s doc: "Known messages keep their local ID, selection and loaded body" – the body-derived fields are part of the loaded body.
- README "How mail is fetched": quick check every 15 s; a folder still syncing gets its newest 50 each time.
- Existing test `applyReadFlagChangesAndBodyRecipients` checks setBody fills the addresses.

## Likely cause
`Sources/MailModel/MailStore.swift:563-566` (`merge`): when `old.bodyLoaded && !m.bodyLoaded` only body, attachments, invite, html, htmlChecked are copied from `old`; `from`, `to`, `cc` (set by `setBody`, :840-842) and `hasAttachments` (:836) are taken from the summary.

## Also seen by
Another probe hunt found the same root cause (`probeResyncKeepsAddressesLoadedWithTheBody` in `specs/bugs/probes/`).
