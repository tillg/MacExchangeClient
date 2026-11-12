---
title: Saving an attachment fails when a broken alias/symlink with the same name is in the target folder
priority: P4
area: MailStore
status: open
found: 2026-11-12
---
## Summary
`MailStore.freeURL(for:in:)` picks the "name 2.pdf" name only when `FileManager.fileExists(atPath:)` says the name is taken. That call follows symbolic links, so a dangling symlink reads as "not there". `saveAttachment` then calls `copyItem` to that name, which fails with "an item with the same name already exists". Save Attachment, Save to Downloads Folder and Save All report "Couldn't save" instead of making "report 2.pdf".

## Repro
```swift
import Foundation
import Testing
@testable import MailModel

@MainActor
struct Probe_Model2Tests {
    @Test func saveNextToADanglingSymlinkDoesNotPickItsName() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createSymbolicLink(atPath: dir.appendingPathComponent("report.pdf").path,
                                                   withDestinationPath: "/nonexistent/old-report.pdf")
        let source = dir.appendingPathComponent("download.pdf")
        try Data([1, 2, 3]).write(to: source)
        let url = MailStore.freeURL(for: "report.pdf", in: dir)
        // saveAttachment copies to this URL; it must not fail.
        #expect(throws: Never.self) { try FileManager.default.copyItem(at: source, to: url) }
        #expect(url.lastPathComponent == "report 2.pdf", "\(url.lastPathComponent)")
    }
}
```

## Expected vs actual
```
Expectation failed: an error was thrown when none was expected: "Error Domain=NSCocoaErrorDomain Code=516 "“download.pdf” couldn’t be copied to “probe-…” because an item with the same name already exists." …
Expectation failed: url.lastPathComponent == "report 2.pdf"
  url.lastPathComponent → "report.pdf"
```

## Why expected
README: "Saving never replaces a file: a second copy becomes 'name 2.pdf'." The Finder also treats a broken symlink as an existing item and numbers the copy.

## Likely cause
`Sources/MailModel/MailStore.swift:1012`: `FileManager.default.fileExists(atPath:)` follows the link. Checking the link itself (for example `attributesOfItem`, or `(try? url.checkResourceIsReachable())` together with `lstat`) would see it. The copy happens at `MailStore.swift:980`.
