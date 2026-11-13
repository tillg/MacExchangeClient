---
title: "A symbolic link to a Finder alias is attached as the alias's bookmark bytes, not the file it points to"
priority: P4
area: compose / attaching files
status: open
found: 2026-11-13
---

## Summary
`MailStore.files` resolves a Finder alias only when the URL itself is an alias and not a symbolic link; it then follows symbolic links only to test for a folder. A symbolic link whose target is an alias file (a link on the Desktop to an alias kept in a project folder) is read as is: the alias's ~1 KB of bookmark data is sent under the link's name, a file the recipient can't open.

## Expected
functional.md: "A Finder alias (bookmark file, not a symbolic link) is resolved first: its original file, or its folder as a zip, goes under the original's name"; a symbolic link is followed to what it points to. The Finder resolves the chain.

## Repro
Probe `Probe_R5K_Attachments/symlinkToAliasAttachesTheOriginal` in `Tests/MailModelTests/Probe_R5KTests.swift` (real temp files):
```sh
swift test --package-path . --scratch-path .build/tests --skip-build --filter Probe_R5K_Attachments/symlinkToAliasAttachesTheOriginal
```

## Failure output
```
Expectation failed: files.map(\.data) == [content]
  attached ["report link"] with 936 bytes of bookmark data
```

## Fix idea
In `MailStore.files`, resolve symbolic links first (`resolvingSymlinksInPath`), then check the target for `isAliasFile` and resolve it.
