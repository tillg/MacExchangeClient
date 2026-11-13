---
title: 'Two different senders with the same first name show as one sender''s full name'
priority: P3
area: Models / ConversationRow
status: open
found: 2026-11-13
---
Draft id: R5A-04 (probe suites `Probe_R5*` in `probes/Probe_R5*Tests.swift`).

## Summary
`ConversationRow.senders` removes duplicates by first name. With "Jan Jikeli" and "Jan Müller" in one conversation, `names` has a single entry, so the row shows the full name "Jan Jikeli", the form kept for a conversation with one sender. The row hides that a second person wrote, and names only one of them.

## Expected
README "Conversations": "the senders' first names (\"Jan & Sergio\", or the full name when it is one sender)". These are two senders.

## Repro
Probe: `twoSendersWithTheSameFirstNameAreNotShownAsOne` in `Tests/MailModelTests/Probe_R5ATests.swift`.

```
swift build --package-path W --scratch-path W/.build/tests --target MailModelTests -Xswiftc -load-plugin-library -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
swift test --package-path W --scratch-path W/.build/tests --skip-build --filter Probe_R5A/twoSendersWithTheSameFirstNameAreNotShownAsOne
```

## Failure output
```
Expectation failed: ConversationRow.senders(names) != "Jan Jikeli"
ConversationRow.senders(names) → "Jan Jikeli"
```

## Fix idea
Count distinct senders by address (or full name), not by first name. Use the full-name form only when there is one distinct sender.
