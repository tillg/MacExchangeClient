---
title: Attaching a symbolic link to a folder fails with "Couldn't attach" instead of zipping the folder
priority: P4
area: MailStore
status: open
found: 2026-11-12
---
## Summary
`files(_:)` decides "folder or file" from `isDirectoryKey`, which doesn't follow symlinks. A symlink to a folder (dragged from the Finder or picked in the open panel) is treated as a file, `Data(contentsOf:)` fails on the folder, and the user sees "Couldn't attach “Photos alias”."

## Repro
File `specs/bugs/probes/Probe_LeadTests.swift`:
```swift
@Test func probe_symlinkToFolderAttachesAsZip() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LeadLink-\(UUID())")
    let folder = dir.appendingPathComponent("Photos"), link = dir.appendingPathComponent("Photos alias")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("x".utf8).write(to: folder.appendingPathComponent("a.txt"))
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
    let s = MailStore(accounts: [Account(name: "W", address: "me@w.com")], messages: [])
    let files = s.files([link])
    #expect(files.count == 1 && files.first?.contentType == "application/zip", "files: \(files.map(\.name)) status: \(s.status ?? "nil")")
}
```

## Expected vs actual
Expected: one `application/zip` attachment, as for the folder itself.
Actual:
```
files: [] status: Couldn't attach “Photos alias”.
files.count == 1 → false
```

## Why expected
README: a folder goes as a zip archive "made the way the Finder compresses". The Finder follows a symlink to a folder when compressing or attaching it.

## Likely cause
`Sources/MailModel/MailStore.swift:1249`: `url.resourceValues(forKeys: [.isDirectoryKey])` on the unresolved URL. Use `url.resolvingSymlinksInPath()` first.
