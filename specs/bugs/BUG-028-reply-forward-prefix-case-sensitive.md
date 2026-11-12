---
title: 'Reply/Forward stack prefixes: "RE: x" becomes "Re: RE: x", "Re:x" becomes "Re: Re:x"'
priority: P3
area: MailStore
status: open
found: 2026-11-12
---
## Summary
The existing-prefix check is an exact, case-sensitive `hasPrefix("Re: ")` / `hasPrefix("Fwd: ")`. Outlook/Exchange senders use `RE:` / `FW:`; replying to them stacks prefixes. Also `re:`, `FWD:`, `Re:x` (no space). (German `AW:`/`WG:` are not recognised either: `AW: Plans` → `Re: AW: Plans`; not filed separately since Mail.app's handling of localized prefixes is unverified.)

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

    @Test func probe_replyPrefixIsCaseInsensitive() {
        let a = msg(work, subject: "RE: Plans"), b = msg(work, subject: "re: Plans")
        let s = store([a, b])
        #expect(s.draft(.reply, to: a.id).subject == "RE: Plans")
        #expect(s.draft(.reply, to: b.id).subject == "re: Plans")
    }

    @Test func probe_forwardRecognisesFwAndFWD() {
        let a = msg(work, subject: "FWD: Plans"), b = msg(work, subject: "fwd: Plans")
        let s = store([a, b])
        #expect(s.draft(.forward, to: a.id).subject == "FWD: Plans")
        #expect(s.draft(.forward, to: b.id).subject == "fwd: Plans")
    }

    @Test func probe_reAndFwWithoutSpace() {
        let a = msg(work, subject: "Re:Plans")
        let s = store([a])
        #expect(s.draft(.reply, to: a.id).subject == "Re:Plans")
    }
}
```

## Expected vs actual
```
s.draft(.reply, to: a.id).subject → "Re: RE: Plans"
s.draft(.reply, to: b.id).subject → "Re: re: Plans"
s.draft(.forward, to: a.id).subject → "Fwd: FWD: Plans"
s.draft(.forward, to: b.id).subject → "Fwd: fwd: Plans"
s.draft(.reply, to: a.id).subject → "Re: Re:Plans"
```

## Why expected
Existing test `replyToReDoesNotStackPrefix` shows the intent (no stacking). RFC 5322 §3.6.5 describes "Re:" as the reply marker without case semantics; in practice clients (Mail.app, Outlook) treat it case-insensitively and with optional space. Target is an Exchange (Outlook-heavy) org, where `RE:` is the norm.

## Likely cause
`Sources/MailModel/MailStore.swift:1210-1211` — `m.subject.hasPrefix(prefix)` with a fixed-case, space-terminated prefix.
