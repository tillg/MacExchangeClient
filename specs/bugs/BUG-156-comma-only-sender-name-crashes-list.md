---
title: 'A sender named "," (or ", ") in a conversation crashes the app'
priority: P1
area: Models / ConversationRow
status: open
found: 2026-11-13
---
Draft id: R5A-03 (probe suites `Probe_R5*` in `probes/Probe_R5*Tests.swift`).

## Summary
`ConversationRow.senders` takes the part after the last comma of a name with a comma: `full.split(separator: ",").last!`. For a name made only of commas (",", ", " after trimming) `split` returns no pieces, and the force unwrap traps. The name comes straight from the message's From (`EWSBackend.contact` keeps any non-empty `Name`), so any sender can set it, for example an empty "Last, First" directory entry. The list draws the row on every render, so with conversations on (the default) the app crashes whenever that conversation is on screen, also at the next launch.

## Expected
Plain correctness: a sender's display name must not crash the app.

## Repro
Probe: `conversationSendersWithCommaOnlyNameDoNotCrash (exit test)` in `Tests/MailModelTests/Probe_R5ATests.swift`.

```
swift build --package-path W --scratch-path W/.build/tests --target MailModelTests -Xswiftc -load-plugin-library -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
swift test --package-path W --scratch-path W/.build/tests --skip-build --filter Probe_R5A/conversationSendersWithCommaOnlyNameDoNotCrash
```

## Failure output
```
Expectation failed: expected exit status ".success", but ".signal(SIGTRAP)" was reported instead
```

## Fix idea
In `ConversationRow.senders`, use `.last.map(String.init) ?? full` (and the same for `split(separator: " ").first!`), and fall back to the address when the result is empty.
