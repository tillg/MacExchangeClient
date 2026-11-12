---
title: Contact.initials can return 3+ letters (ß, ǆ, ﬀ expand when uppercased)
priority: P4
area: Models
status: open
found: 2026-11-12
---
## Summary
Initials are uppercased after taking the first Character of two words. Characters whose uppercase is two letters (`ß`→`SS`, `ﬀ`→`FF`) give 3-letter initials that overflow the round avatar.

## Repro
Swift Testing, in `specs/bugs/probes/Probe_ModelTests.swift` (`import Testing`, `@testable import MailModel`, inside `struct Probe_ModelTests`):

```swift
@Test func initialsAtMostTwoLetters() {
    for name in ["ßtefan Müller", "ǆenan Kovač", "ﬀoo Bar"] {
        let i = Contact(name: name, email: "x@x.com").initials
        #expect(i.count <= 2, "\(name) -> \(i)")
    }
}
```
Run: `swift test --package-path COPY --scratch-path COPY/.build/tests --skip-build --filter Probe_Model`

## Expected vs actual
Two of three names fail:
```
i.count → 3
i.count → 3
```
(`ßtefan Müller` → `SSM`, `ﬀoo Bar` → `FFB`).

## Why expected
Initials are at most two letters (the avatar is drawn for two; MessageListView.swift:194).

## Likely cause
Sources/MailModel/Models.swift:108 `.joined().uppercased()` after selecting characters; should uppercase per initial and keep one Character each (e.g. `String(c).uppercased().prefix(1)` or titlecase).
