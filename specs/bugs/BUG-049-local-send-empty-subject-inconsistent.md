---
title: Sending without a server stores an empty subject; Drafts and failed sends use "(No Subject)"
priority: P4
area: MailStore
status: open
found: 2026-11-12
---
## Summary
Local `send` stores `d.subject` as is, so a message sent with no subject shows a blank subject in Sent, while `saveDraft` and `failed()` store "(No Subject)".

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

    @Test func probe_localSendEmptySubjectShowsNoSubject() {
        let s = store([])
        s.send(Draft(accountID: work.id, to: "a@x.com", subject: "", body: "B"))
        let m = s.messages.first { $0.mailbox == .sent }
        #expect(m?.subject == "(No Subject)", "subject: \(String(describing: m?.subject))")
    }
}
```

## Expected vs actual
```
Expectation failed: m?.subject == "(No Subject)"
  subject: Optional("")
```

## Why expected
Same file uses "(No Subject)" for local drafts (MailStore.swift:1359) and for failed sends (:733); no view in `Sources/MailReplica` substitutes a placeholder for an empty subject (grep "No Subject" finds only MailStore.swift), so the Sent row is blank. Mail.app shows "(No Subject)".

## Likely cause
`Sources/MailModel/MailStore.swift:1345` — `subject: d.subject` without the empty-subject fallback used at :1359.
