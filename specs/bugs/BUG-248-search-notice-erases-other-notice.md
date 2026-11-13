---
title: 'A search''s notice ("Showing the newest 2,000 results", "Search failed") replaces a "Couldn''t send" or sign-in notice, and clearing the search erases it for good'
priority: P3
area: MailStore / search
status: open
found: 2026-11-13
---

## Summary
`runSearch` writes its notice into the one `status` line, over whatever was there: "Couldn't send “Budget”…", "Sign-in to … failed … Nothing is sent until then", or a refused change. Clearing the search then sets `status = nil` (the notice is the search's own), so the earlier notice is gone although its cause remains; the user never learns that a send failed or that the account is paused.

## Expected
search.md › Index path 6: "Clearing the field … clears the 2,000 notice or a Search failed notice. Any other status stays." DECISIONS d-bug-031: the search notices are cleared with the search and "Any other status is left alone". architecture.md: "Couldn't send …" and sign-in notices are not cleared by a check.

## Repro
Probe `Probe_R5MStore/searchNoticeDoesNotEraseAnotherNotice` in `Tests/MailModelTests/Probe_R5MTests.swift`.

```
swift build --package-path W --scratch-path W/.build/tests --target MailModelTests -Xswiftc -load-plugin-library -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
swift test --package-path W --scratch-path W/.build/tests --skip-build --filter Probe_R5MStore/searchNoticeDoesNotEraseAnotherNotice
```

## Failure output
```
Expectation failed: s.status == notice
during the search: Showing the newest 2,000 results; after clearing it: nil
s.status → nil
```

## Fix idea
Keep the search notice apart (e.g. `searchNotice`, shown in the subtitle in preference to `status`), or remember the status it replaced and put it back when the search notice goes.
