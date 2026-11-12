---
title: 'Message Size: the estimate walks the whole body by character on every render (about 40 ms per keystroke in a 400 KB reply with a file)'
priority: P4
area: Models
status: open
found: 2026-11-13
---
## Summary
With a file attached, the compose header shows the Message Size. `estimatedSize` rebuilds `text` (a grapheme-by-grapheme filter of the whole body) on every call, and on an Exchange account with a size limit the view calls it three times per render: once through `isOverSizeLimit` and once directly in `sizeText`, and once more through `isOverSizeLimit` for the red colour. That every keystroke re-renders the header was read from the code (`textDidChange` writes `draft.body`), not measured in the app.

## Repro
```swift
import Foundation
import Testing
@testable import EWS
@testable import MailModel

@MainActor
struct Probe_ComposeTests {
    let work = Account(name: "Work", address: "me@work.com")
    let home = Account(name: "iCloud", address: "me@icloud.com")
    let mark = String(Draft.fileMark)

    func msg(_ acct: Account, _ box: MailboxKind = .inbox, subject: String = "Hi", from: Contact? = nil,
             to: [Contact]? = nil, cc: [Contact] = [], body: String = "Body") -> Message {
        Message(accountID: acct.id, mailbox: box, from: from ?? Contact(name: "Ann", email: "ann@x.com"),
                to: to ?? [Contact(name: "Me", email: acct.address)], cc: cc, subject: subject, body: body,
                date: Date(timeIntervalSince1970: 1_000_000))
    }

    func store(_ msgs: [Message]) -> MailStore { MailStore(accounts: [work, home], messages: msgs) }

    func png(_ name: String, _ bytes: Int = 4) -> DraftAttachment {
        DraftAttachment(name: name, contentType: "image/png", data: Data(repeating: 7, count: bytes))
    }

    /// Every render of the compose window computes the size 2-3 times (sizeText, red colour); typing in a long reply
    /// re-renders on every key. The estimate should not walk the whole body by grapheme each time.
    @Test func estimatedSizeIsCheapForALongReply() {
        let line = "> Thanks, that works for me. Let's keep Friday at 10 as planned, ok?\n"
        var d = Draft(accountID: work.id, body: String(repeating: line, count: 6_000))  // ~420 KB quoted thread
        d.attachments = [png("p.png", 1_000_000)]
        let clock = ContinuousClock()
        var total = 0
        let t = clock.measure { for _ in 0..<3 { total &+= d.estimatedSize } }
        print("estimatedSize x3 on \(d.body.utf8.count) bytes: \(t)")
        #expect(t < .milliseconds(16), "three size estimates (one keystroke's render) took \(t)")
    }

}
```

## Expected vs actual
Run alone (debug build, which is what `./run.sh` builds), body 414,000 bytes, one 1 MB file:
```
estimatedSize x3 on 414000 bytes: 0.040150334 seconds
Expectation failed: t < .milliseconds(16)
```
Expected: under one frame (16 ms).

## Why expected
Same class as the known BUG-017 (preview recomputed over the whole body), on a different code path. The README shows Message Size whenever files are attached, so the cost is paid on every keystroke while writing.

## Likely cause
`Models.swift` `Draft.estimatedSize`: `text.utf8.count`, where `text` is `body.filter { $0 != Self.fileMark }` (Character iteration and a copy). `body.utf8.count - 3 * marks` (U+FFFC is 3 UTF-8 bytes) would do the same in one byte scan. Call sites: `ComposeView.swift:165-171`.
