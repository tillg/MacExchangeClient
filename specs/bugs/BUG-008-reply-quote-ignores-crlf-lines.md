---
title: Reply/forward quoting marks only the first line of a CRLF body
priority: P2
area: MailStore
status: open
found: 2026-11-12
---
## Summary
Quoting splits the body on `"\n"`, but in Swift `"\r\n"` is a single `Character`, so a CRLF body is never split: only the first line gets `> `, all following lines appear unquoted in the reply.

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

    @Test func probe_replyQuotesEveryLineOfCRLFBody() {
        let m = msg(work, body: "first\r\nsecond\r\nthird")
        let s = store([m])
        let d = s.draft(.reply, to: m.id)
        #expect(d.body.contains("> second"), "body: \(d.body.debugDescription)")
        #expect(d.body.contains("> third"), "body: \(d.body.debugDescription)")
    }
}
```

## Expected vs actual
```
Expectation failed: d.body.contains("> second")
  body: "\n\nOn 12. Jan 1970 at 14:46, Ann <ann@x.com> wrote:\n\n> first\r\nsecond\r\nthird"
```

## Why expected
README: "Compose window with reply quoting"; existing test `replyDraftQuotesOriginal` expects every body line quoted. Exchange text bodies (and MIME text in general, RFC 5322 line endings) use CRLF; `Sources/EWS` does no `\r` normalisation (grep finds none), so real Exchange replies hit this.

## Likely cause
`Sources/MailModel/MailStore.swift:1213` — `m.body.split(separator: "\n", omittingEmptySubsequences: false)`; should split on `\.isNewline` / normalise `\r\n`.
