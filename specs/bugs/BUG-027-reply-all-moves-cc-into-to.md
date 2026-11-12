---
title: Reply All puts the original Cc recipients into To; Cc stays empty
priority: P3
area: MailStore
status: open
found: 2026-11-12
---
## Summary
Reply All merges sender, To and Cc into the draft's To field and leaves `cc` empty, so people who were only copied become primary recipients.

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

    @Test func probe_replyAllKeepsOriginalCcInCc() {
        let m = msg(work, from: "Ann", to: [Contact(name: "Me", email: "me@work.com")],
                    cc: [Contact(name: "Carl", email: "carl@x.com")])
        let s = store([m])
        let d = s.draft(.replyAll, to: m.id)
        #expect(d.to == "ann@x.com", "to: \(d.to)")
        #expect(d.cc == "carl@x.com", "cc: \(d.cc)")
    }
}
```

## Expected vs actual
Expected: to `ann@x.com`, cc `carl@x.com`. Actual:
```
Expectation failed: d.to == "ann@x.com"   →  d.to → "ann@x.com, carl@x.com"
Expectation failed: d.cc == "carl@x.com"  →  d.cc → ""
```

## Why expected
Mail.app (and Outlook) Reply All: To = sender + original To (minus me), Cc = original Cc (minus me). `Draft` has a `cc` field the compose window shows, and README lists Reply All as a Mail-faithful action.

## Likely cause
`Sources/MailModel/MailStore.swift:1221-1222` — builds only `to`; `Draft(... to: to, ...)` at :1225 never sets `cc`.
