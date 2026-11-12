---
title: Save Draft without a server loses the Cc recipients
priority: P3
area: MailStore
status: open
found: 2026-11-12
---
## Summary
For accounts without a backend, `saveDraft` builds the Drafts message without `cc`, so the Cc field is silently dropped. `send` and `failed()` both keep it.

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

    @Test func probe_localSaveDraftKeepsCc() {
        let s = store([])
        s.saveDraft(Draft(accountID: work.id, to: "a@x.com", cc: "c@x.com", subject: "S", body: "B"))
        let d = s.messages.first { $0.mailbox == .drafts }
        #expect(d?.cc.map(\.email) == ["c@x.com"])
    }
}
```

## Expected vs actual
```
Expectation failed: d?.cc.map(\.email) == ["c@x.com"]
  d?.cc.map(\.email) → []
```

## Why expected
Saving a draft must keep what the user typed (README: Send and Save Draft; Mail's "Save this message as a draft?"). `send` (MailStore.swift:1345) and `failed` (:732) pass `cc: Contact.parseList(d.cc)`.

## Likely cause
`Sources/MailModel/MailStore.swift:1358-1360` — `Message(... to: Contact.parseList(d.to), subject: ...)` omits `cc:`.
