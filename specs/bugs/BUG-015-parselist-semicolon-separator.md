---
title: Contact.parseList treats "a@x.com; b@y.com" as one recipient
priority: P3
area: Models
status: open
found: 2026-11-12
---
## Summary
Semicolon-separated recipient lists (Outlook's separator, what users paste from Outlook/Exchange) become a single contact whose address is `a@x.com; b@y.com`.

## Repro
Swift Testing, in `specs/bugs/probes/Probe_ModelTests.swift` (`import Testing`, `@testable import MailModel`, inside `struct Probe_ModelTests`):

```swift
@Test func parseListSemicolonSeparated() {
    let c = Contact.parseList("a@x.com; b@y.com")
    #expect(c.map(\.email) == ["a@x.com", "b@y.com"])
}
```
Run: `swift test --package-path COPY --scratch-path COPY/.build/tests --skip-build --filter Probe_Model`

## Expected vs actual
```
c.map(\.email) → ["a@x.com; b@y.com"]
```

## Why expected
The app is an Exchange client (target: on-prem Exchange); Outlook's address lists use `;`. Sending puts the whole string into one `<t:EmailAddress>`, which Exchange rejects or bounces.

## Likely cause
Sources/MailModel/Models.swift:112 splits only on `,`.
