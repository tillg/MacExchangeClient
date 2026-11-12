---
title: Reply All lists the same recipient several times
priority: P3
area: MailStore
status: open
found: 2026-11-12
---
## Summary
Reply All concatenates sender + To + Cc without de-duplication. A sender who also appears in Cc, or an address listed twice in different case, shows up two or more times in the new message's To field.

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

    @Test func probe_replyAllHasNoDuplicateRecipients() {
        let m = msg(work, from: "Ann", to: [Contact(name: "Me", email: "me@work.com"), Contact(name: "Bo", email: "bo@x.com")],
                    cc: [Contact(name: "Ann", email: "ann@x.com"), Contact(name: "Bo", email: "BO@x.com")])
        let s = store([m])
        let d = s.draft(.replyAll, to: m.id)
        let emails = Contact.parseList(d.to + "," + d.cc).map { $0.email.lowercased() }
        #expect(emails.count == Set(emails).count, "to: \(d.to) cc: \(d.cc)")
    }
}
```

## Expected vs actual
Expected: each of ann@x.com and bo@x.com once. Actual:
```
Expectation failed: emails.count == Set(emails).count
  to: ann@x.com, bo@x.com, ann@x.com, BO@x.com cc:
  emails.count → 4
  Set(emails).count → 2
```

## Why expected
Mail.app's Reply All addresses each person once. Duplicates show as repeated tokens in the compose window and may make Exchange deliver duplicates.

## Likely cause
`Sources/MailModel/MailStore.swift:1222` — `([m.from] + m.to + m.cc).map(\.email)` has no case-insensitive de-duplication.
