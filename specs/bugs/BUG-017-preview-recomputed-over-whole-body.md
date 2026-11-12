---
title: Message.preview processes the entire body on every access (80-300 ms for a 1 MB body)
priority: P3
area: Models
status: open
found: 2026-11-12
---
## Summary
`preview` splits, filters and joins the whole body each time it is read. The list row (`MessageListView.swift:135`) reads it on every render, but only shows 2 lines. A 1 MB body costs 80-300 ms per access, so a long mail in the list stalls scrolling/selection.

## Repro
Swift Testing, in `specs/bugs/probes/Probe_ModelTests.swift` (`import Testing`, `@testable import MailModel`, inside `struct Probe_ModelTests`):

```swift
@Test func previewOfHugeBodyIsFast() {
    let body = String(repeating: "Lorem ipsum dolor sit amet\n", count: 40_000)  // ~1 MB
    let m = Message(accountID: UUID(), from: Contact(name: "A", email: "a@x"), to: [], subject: "S",
                    body: body, date: .now)
    let t = Date()
    for _ in 0..<10 { _ = m.preview }
    let per = Date().timeIntervalSince(t) / 10
    #expect(per < 0.005, "preview took \(per * 1000) ms per call")
}
```
Run: `swift test --package-path COPY --scratch-path COPY/.build/tests --skip-build --filter Probe_Model`

## Expected vs actual
Expected < 5 ms. Actual (two runs, debug build):
```
preview took 295.4578995704651 ms per call
preview took 79.48850393295288 ms per call
```

## Why expected
README List row: "2-line preview". Only the first ~200 characters are needed; the list must stay smooth with large mailboxes (README benchmarks 180,000 messages).

## Likely cause
Sources/MailModel/Models.swift:198-199 `body.split(whereSeparator:).filter{}.joined()` over the full body, uncached, no prefix limit.
