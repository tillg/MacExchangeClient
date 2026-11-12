---
title: Contact.initials ignores names separated by tab or no-break space
priority: P4
area: Models
status: open
found: 2026-11-12
---
## Summary
`initials` splits on U+0020 only. Names from Exchange/vCards with a no-break space or tab (`Jane\u{00A0}Doe`) give a single initial `J` instead of `JD`.

## Repro
Swift Testing, in `specs/bugs/probes/Probe_ModelTests.swift` (`import Testing`, `@testable import MailModel`, inside `struct Probe_ModelTests`):

```swift
@Test func initialsWeirdNames() {
    #expect(Contact(name: "👨‍👩‍👧 Family Group", email: "f@x").initials == "👨‍👩‍👧F")   // passes
    #expect(Contact(name: "", email: "f@x").initials == "")                         // passes
    #expect(Contact(name: "Jane\u{00A0}Doe", email: "j@x").initials == "JD")
    #expect(Contact(name: "Jane\tDoe", email: "j@x").initials == "JD")
    #expect(Contact(name: "محمد علي", email: "m@x").initials == "مع")                // passes
}
```
Run: `swift test --package-path COPY --scratch-path COPY/.build/tests --skip-build --filter Probe_Model`

## Expected vs actual
```
Contact(name: "Jane\u{00A0}Doe", email: "j@x").initials → "J"
Contact(name: "Jane\tDoe", email: "j@x").initials → "J"
```

## Why expected
README list row: optional contact photo/initials as in Mail; Mail derives initials from given+family name, independent of the whitespace kind.

## Likely cause
Sources/MailModel/Models.swift:107 `name.split(separator: " ")` instead of splitting on `isWhitespace`.
