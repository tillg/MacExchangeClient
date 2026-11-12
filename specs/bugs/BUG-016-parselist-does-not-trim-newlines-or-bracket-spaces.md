---
title: Contact.parseList leaves newlines and spaces inside <> in the address
priority: P3
area: Models
status: open
found: 2026-11-12
---
## Summary
Entries are trimmed with `.whitespaces` only, so a pasted list ending in a newline yields `b@y.com\n`; spaces inside angle brackets (`Jane < jane@x.com >`) stay in the address. These addresses go to Exchange as-is.

## Repro
Swift Testing, in `specs/bugs/probes/Probe_ModelTests.swift` (`import Testing`, `@testable import MailModel`, inside `struct Probe_ModelTests`):

```swift
@Test func parseListTrailingNewline() {
    let c = Contact.parseList("a@x.com, b@y.com\n")
    #expect(c.map(\.email) == ["a@x.com", "b@y.com"])
}

@Test func parseListSpacesInsideAngleBrackets() {
    let c = Contact.parseList("Jane < jane@x.com >")
    #expect(c.first?.email == "jane@x.com")
}
```
Run: `swift test --package-path COPY --scratch-path COPY/.build/tests --skip-build --filter Probe_Model`

## Expected vs actual
```
c.map(\.email) → ["a@x.com", "b@y.com\n"]
c.first?.email → " jane@x.com "
```

## Why expected
An address never contains leading/trailing whitespace or line breaks (RFC 5322 addr-spec); Mail strips them. Also `addsNewRecipient` compares lowercased emails, so `b@y.com\n` counts as a new recipient.

## Likely cause
Sources/MailModel/Models.swift:113 `trimmingCharacters(in: .whitespaces)` (no newlines); :116 email substring between `<` and `>` is not trimmed.
