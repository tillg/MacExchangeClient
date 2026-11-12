---
title: Reply All keeps my own address when the original lists it in different case
priority: P2
area: MailStore
status: open
found: 2026-11-12
---
## Summary
Reply All removes the account's own address only on an exact, case-sensitive string match. When the original lists `Me@Work.COM` (common with Exchange/Outlook display of SMTP addresses) the user's own address stays in To, so the reply is also sent to themselves.

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

    @Test func probe_replyAllExcludesOwnAddressCaseInsensitively() {
        let m = msg(work, to: [Contact(name: "Me", email: "Me@Work.COM"), Contact(name: "Bo", email: "bo@x.com")])
        let s = store([m])
        let d = s.draft(.replyAll, to: m.id)
        let emails = Contact.parseList(d.to + "," + d.cc).map { $0.email.lowercased() }
        #expect(!emails.contains("me@work.com"), "to: \(d.to) cc: \(d.cc)")
    }
}
```

## Expected vs actual
Expected: To = `ann@x.com, bo@x.com`. Actual:
```
Expectation failed: !emails.contains("me@work.com")
  to: ann@x.com, Me@Work.COM, bo@x.com cc:
```

## Why expected
Email addresses' domain is case-insensitive and Exchange treats the local part case-insensitively; Mail.app never puts the user's own account address in a Reply All. The same file already compares addresses lowercased in `addsNewRecipient` (MailStore.swift:1238-1239), so the intent is case-insensitive.

## Likely cause
`Sources/MailModel/MailStore.swift:1222` — `.filter { $0 != me }` compares raw strings; needs `lowercased()` on both sides.
