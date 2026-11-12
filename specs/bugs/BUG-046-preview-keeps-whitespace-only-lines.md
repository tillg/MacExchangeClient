---
title: Message.preview keeps whitespace-only lines and tabs, leaving gaps in the list preview
priority: P4
area: Models
status: open
found: 2026-11-12
---
## Summary
Blank lines that contain spaces/tabs (very common in plain-text versions of HTML mail) are not dropped, so the 2-line preview shows long runs of spaces/tabs between words.

## Repro
Swift Testing, in `specs/bugs/probes/Probe_ModelTests.swift` (`import Testing`, `@testable import MailModel`, inside `struct Probe_ModelTests`):

```swift
@Test func previewCollapsesBlankWhitespaceLines() {
    let m = Message(accountID: UUID(), from: Contact(name: "A", email: "a@x"), to: [], subject: "S",
                    body: "Hello\n   \n\tWorld", date: .now)
    #expect(m.preview == "Hello World")
}
```
Run: `swift test --package-path COPY --scratch-path COPY/.build/tests --skip-build --filter Probe_Model`

## Expected vs actual
```
m.preview → "Hello     \tWorld"
```

## Why expected
Mail's list preview collapses whitespace; empty lines are already dropped (`split` omits empty subsequences), so whitespace-only lines are meant to be dropped too.

## Likely cause
Sources/MailModel/Models.swift:198-199 lines aren't trimmed before filtering/joining; whitespace inside isn't collapsed.
