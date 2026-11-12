---
title: Draft.html merges CRLF lines into one, so quoted text arrives as one paragraph when a picture is placed
priority: P3
area: Models
status: open
found: 2026-11-12
---
## Summary
`Draft.html` splits the body on Character `"\n"`, but in Swift `"\r\n"` is a single Character, so CRLF-terminated text is never split: all lines end up in one `<div>` and the line breaks render as spaces. Reply/forward bodies quote the server's plain-text body (Exchange text bodies use CRLF), and the HTML path is used whenever a picture is placed in the text.

## Repro
Swift Testing, in `specs/bugs/probes/Probe_ModelTests.swift` (`import Testing`, `@testable import MailModel`, inside `struct Probe_ModelTests`):

```swift
@Test func draftHTMLSplitsCRLFLines() {
    let d = Draft(accountID: UUID(), body: "one\r\ntwo\r\nthree")
    let h = d.html { _ in nil }
    #expect(h.contains("<div>one</div>") && h.contains("<div>three</div>"), "\(h)")
}
```
Run: `swift test --package-path COPY --scratch-path COPY/.build/tests --skip-build --filter Probe_Model`

## Expected vs actual
```
h.contains("<div>one</div>") → false
```
(the whole body is one `<div>one\r\ntwo\r\nthree</div>`).

## Why expected
Doc: "A line per `<div>` … the way Mail writes its HTML". Plain-text sending keeps the breaks, so the recipient sees different text depending on whether a picture was placed. `Message.preview` (uses `isNewline`) handles CRLF correctly — probe `previewCRLF` passes.

## Likely cause
Sources/MailModel/Models.swift:286 `body.split(separator: "\n", omittingEmptySubsequences: false)`; should split on `isNewline`. (Same pattern in MailStore.draft quoting, MailStore.swift:1213 — other area.)
