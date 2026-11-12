---
title: Attachments whose name exceeds 255 bytes cannot be opened/saved (File name too long)
priority: P3
area: Models
status: open
found: 2026-11-12
---
## Summary
`Attachment.fileName` only replaces `/` and NUL; it does not shorten names. A name over 255 UTF-8 bytes (easily reached with umlauts/CJK, e.g. bank/insurance PDFs) fails to write in `MailStore.attachmentFile`, so Quick Look/open fails.

## Repro
Swift Testing, in `specs/bugs/probes/Probe_ModelTests.swift` (`import Testing`, `@testable import MailModel`, inside `struct Probe_ModelTests`):

```swift
@Test func longAttachmentNameCanBeWritten() throws {
    let name = String(repeating: "Überweisungsbestätigung ", count: 12) + ".pdf"  // ~300 UTF-8 bytes
    let a = Attachment(name: name)
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("probe-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try Data([1]).write(to: dir.appendingPathComponent(a.fileName), options: .atomic)
}
```
Run: `swift test --package-path COPY --scratch-path COPY/.build/tests --skip-build --filter Probe_Model`

## Expected vs actual
```
Caught error: Error Domain=NSCocoaErrorDomain Code=514 "The item couldn’t be saved because the file name “Überweisungsbestätigung … .pdf” is invalid." … NSUnderlyingError {Error Domain=NSPOSIXErrorDomain Code=63 "File name too long"}
```

## Why expected
`fileName`'s purpose (Models.swift:339) is to turn any sender-supplied name into a usable file name; README: attachments can be previewed with Quick Look and saved. APFS limits a name component to 255 UTF-8 bytes.

## Likely cause
Sources/MailModel/Models.swift:340-343 no length cap (keep extension, truncate the stem); used at MailStore.swift:947.

## Also seen by
The store-flows probe `probe_attachmentWithVeryLongNameOpens` hits the same root cause from `MailStore` (open, save and forward all fail).
