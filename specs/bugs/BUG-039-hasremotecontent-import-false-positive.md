---
title: Any text mentioning "@import" shows the Load Remote Content banner
priority: P4
area: HTMLPage
status: open
found: 2026-11-12
---
## Summary
`@import` matches anywhere in the HTML, including visible text, so a newsletter or colleague mail that talks about CSS `@import` shows the remote-content banner although nothing remote is referenced.

## Repro
Swift Testing, in `specs/bugs/probes/Probe_ModelTests.swift` (`import Testing`, `@testable import MailModel`, inside `struct Probe_ModelTests`):

```swift
func html(_ h: String) -> Message {
    var m = Message(accountID: UUID(), from: Contact(name: "A", email: "a@x"), to: [], subject: "S", body: "", date: .now)
    m.html = h
    return m
}

@Test func remoteContentFalsePositiveImportInText() {
    #expect(!html("<p>Tip: write @import at the top of your stylesheet.</p>").hasRemoteContent)
}
```
Run: `swift test --package-path COPY --scratch-path COPY/.build/tests --skip-build --filter Probe_Model`

## Expected vs actual
`hasRemoteContent → true` (expected false).

## Why expected
The banner should appear only when blocked web content exists (README HTML mail line). A sibling probe confirmed plain text `&lt;img src=&quot;https…` does NOT trigger it, so `@import` is the inconsistent case.

## Likely cause
Sources/MailModel/Models.swift:191 bare `@import` alternative, not restricted to `<style>`/CSS context nor followed by a URL.
