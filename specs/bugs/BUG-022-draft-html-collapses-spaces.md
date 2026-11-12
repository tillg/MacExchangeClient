---
title: Draft.html collapses runs of spaces and tabs (indented text/tables lose their layout)
priority: P3
area: Models
status: open
found: 2026-11-12
---
## Summary
Multiple spaces and tabs are emitted as-is inside `<div>`; HTML collapses them, so aligned columns, indentation and code lose their layout when the mail is sent as HTML (whenever a picture is placed in the text). Mail writes `&nbsp;` alternation / `Apple-tab-span white-space:pre` for this.

## Repro
Swift Testing, in `specs/bugs/probes/Probe_ModelTests.swift` (`import Testing`, `@testable import MailModel`, inside `struct Probe_ModelTests`):

```swift
@Test func draftHTMLKeepsRunsOfSpaces() {
    let d = Draft(accountID: UUID(), body: "Name    Qty\nApple      3")
    let h = d.html { _ in nil }
    // Multiple spaces must survive in HTML: &nbsp; or a white-space: pre-wrap style.
    #expect(h.contains("&nbsp;") || h.contains("pre-wrap"), "\(h)")
}
```
Run: `swift test --package-path COPY --scratch-path COPY/.build/tests --skip-build --filter Probe_Model`

## Expected vs actual
```
h.contains("&nbsp;") → false
h.contains("pre-wrap") → false
```
Body style is only `overflow-wrap: break-word; -webkit-nbsp-mode: space; line-break: after-white-space;`.

## Why expected
Doc claims the HTML is written "the way Mail writes its HTML"; Mail preserves consecutive spaces with `&nbsp;`. The text-only send path keeps them, so the content differs depending on whether a picture is placed.

## Likely cause
Sources/MailModel/Models.swift:278-282 `escape` doesn't convert repeated spaces/tabs; :298 body style has no `white-space: pre-wrap`.
