---
title: Contact.parseList breaks quoted display names (comma inside quotes splits the contact; quotes kept in name)
priority: P2
area: Models
status: open
found: 2026-11-12
---
## Summary
A recipient written the RFC 5322 way, `"Doe, John" <john.doe@x.com>` (how Outlook/Exchange and many address books write "Last, First" names), is split at the comma into a bogus recipient `"Doe` plus a second one. Even without a comma, the surrounding quotes stay in the display name.

## Repro
Swift Testing, in `specs/bugs/probes/Probe_ModelTests.swift` (`import Testing`, `@testable import MailModel`, inside `struct Probe_ModelTests`):

```swift
@Test func parseListQuotedNameWithComma() {
    let c = Contact.parseList(#""Doe, John" <john.doe@x.com>, ann@y.com"#)
    #expect(c.map(\.email) == ["john.doe@x.com", "ann@y.com"])
    #expect(c.first?.name == "Doe, John")
}

@Test func parseListStripsQuotesAroundName() {
    let c = Contact.parseList(#""John Doe" <john@x.com>"#)
    #expect(c.first?.name == "John Doe")
}
```
Run: `swift test --package-path COPY --scratch-path COPY/.build/tests --skip-build --filter Probe_Model`

## Expected vs actual
Expected 2 contacts `john.doe@x.com`, `ann@y.com`, first named `Doe, John`. Actual:
```
c.map(\.email) → ["\"Doe", "john.doe@x.com", "ann@y.com"]
c.first?.name → ""Doe"
c.first?.name → ""John Doe""   (expected "John Doe")
```

## Why expected
RFC 5322 §3.4 (display-name may be a quoted-string; commas inside quotes are not separators). `EWSBackend.createRequest` builds `<t:Mailbox>` from `Contact.parseList(d.to)`, so `"Doe` is sent to Exchange as an EmailAddress -> the send fails or bounces (wrong mail sent).

## Likely cause
Sources/MailModel/Models.swift:112 `s.split(separator: ",")` ignores quotes; :117 the name is taken verbatim (quotes not removed).

## Also seen by
The EWS probe hunt found the same root cause from the request side: `probeQuotedDisplayNameWithComma`, `probeUnquotedLastFirstName` and `probeSemicolonSeparatedRecipients` in `Probe_EWSTests.swift` (`Gartner, Till <x>` becomes the extra recipient "Gartner"). The semicolon case is filed separately (parseList semicolon separator).
