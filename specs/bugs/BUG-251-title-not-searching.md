---
title: 'While searching, the window title and subtitle describe the mailbox, not the search results'
priority: P4
area: MailStore / MessageViewer
status: open
found: 2026-11-13
---

## Summary
During a search the list shows results from the whole account (or all accounts), but the title stays the mailbox's ("Inbox – Work") and the subtitle keeps the mailbox's counts ("120 messages, 3 unread"), which have nothing to do with the list. Nothing in the window says the list is search results, or how many.

## Expected
Mail.app `Localizable.loctable`: `SearchingWindowTitleFormat` = "Searching “%1$@”" and `SearchResultsFound` = "Found %lu result(s)" (`/System/Applications/Mail.app/Contents/Resources`). ⚠️ the exact placement (title vs subtitle) is not read from the nib.

## Repro
Probe `Probe_R5MStore/titleSaysSearchingWhileSearching` in `Tests/MailModelTests/Probe_R5MTests.swift`.

```
swift build --package-path W --scratch-path W/.build/tests --target MailModelTests -Xswiftc -load-plugin-library -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
swift test --package-path W --scratch-path W/.build/tests --skip-build --filter Probe_R5MStore/titleSaysSearchingWhileSearching
```

## Failure output
```
Expectation failed: s.title.hasPrefix("Searching")
title while searching: Inbox – Work; list: ["Report 2", "Report"]
```

## Fix idea
`MailStore.title`: while `normalizedSearch` isn't empty, "Searching “<mailbox or account>”"; `MessageViewer.subtitle`: the number of results (`visibleMessages.count`) instead of the mailbox counts.
