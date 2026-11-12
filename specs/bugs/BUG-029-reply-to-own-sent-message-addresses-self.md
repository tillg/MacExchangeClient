---
title: Reply to a message in Sent addresses the reply to myself
priority: P3
area: MailStore
status: open
found: 2026-11-12
---
## Summary
Reply always uses `m.from.email`. For a message the user sent (Sent mailbox, from = own account), Reply goes to the user's own address instead of the original recipients.

## Repro
File `specs/bugs/probes/Probe_StoreFlowsTests.swift` (run: `swift test ... --skip-build --filter Probe_StoreFlows`). Self-contained:

```swift
import Foundation
import Testing
@testable import MailModel

@MainActor
struct Probe_StoreFlowsTests {
    let work = Account(name: "Work", address: "me@work.com")
    let home = Account(name: "iCloud", address: "me@icloud.com")

    func msg(_ acct: Account, _ box: MailboxKind = .inbox, subject: String = "Hi", from: String = "Ann",
             body: String? = nil, to: [Contact]? = nil, cc: [Contact] = [], minutesAgo: Double = 0) -> Message {
        Message(accountID: acct.id, mailbox: box, from: Contact(name: from, email: "\(from.lowercased())@x.com"),
                to: to ?? [Contact(name: "Me", email: acct.address)], cc: cc, subject: subject,
                body: body ?? "Body of \(subject)", date: Date(timeIntervalSince1970: 1_000_000 - minutesAgo * 60))
    }
    func store(_ msgs: [Message]) -> MailStore { MailStore(accounts: [work, home], messages: msgs) }
    func tempDir() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("ProbeStoreFlows-\(UUID())") }

    @Test func probe_replyToOwnSentMessageGoesToRecipients() {
        let m = Message(accountID: work.id, mailbox: .sent, from: Contact(name: "Me", email: "me@work.com"),
                        to: [Contact(name: "Bo", email: "bo@x.com")], subject: "Plans", body: "x", date: .now)
        let s = store([m])
        let d = s.draft(.reply, to: m.id)
        #expect(d.to == "bo@x.com", "to: \(d.to)")
    }
}
```

## Expected vs actual
Expected `bo@x.com`. Actual:
```
Expectation failed: d.to == "bo@x.com"
  to: me@work.com
```

## Why expected
Mail.app (and Outlook): replying to your own sent message addresses the original recipients. Conversations now show sent messages next to received ones (README Conversations, WhatsNew 2026-11-12), so replying from a sent card is a normal flow. Reply All on the same message already gives the recipients (probe `probe_replyAllFromSentMessageGoesToRecipients` passes).

## Likely cause
`Sources/MailModel/MailStore.swift:1220` — `case .reply: to = m.from.email` without checking whether `from` is the account's own address.
