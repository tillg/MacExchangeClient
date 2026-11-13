---
title: 'The conversation row shows "Jan (mgm-tp)" / "Sergio Luis" / "Jan Jikeli" instead of first names'
priority: P3
area: Models / ConversationRow
status: open
found: 2026-11-13
---
Draft id: R5A-07 (probe suites `Probe_R5*` in `probes/Probe_R5*Tests.swift`).

## Summary
`ConversationRow.senders` handles "Last, First" by taking everything after the comma, without cutting it to the first word. Exchange's common display names "Jikeli, Jan (mgm-tp)" and "Lerena, Sergio Luis" give "Jan (mgm-tp) & Sergio Luis". It also splits only on U+0020, so a name with a no-break space (which `Contact.initials` already handles) shows in full: "Jan Jikeli & Bob".

## Expected
README "Conversations": "the senders' first names (\"Jan & Sergio\")". The code's own comment says "Gartner, Till" is Till. `Contact.initials` treats no-break spaces as word breaks.

## Repro
Probe: `conversationSendersAreFirstNamesForCorporateAndNoBreakSpaceNames` in `Tests/MailModelTests/Probe_R5ATests.swift`.

```
swift build --package-path W --scratch-path W/.build/tests --target MailModelTests -Xswiftc -load-plugin-library -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
swift test --package-path W --scratch-path W/.build/tests --skip-build --filter Probe_R5A/conversationSendersAreFirstNamesForCorporateAndNoBreakSpaceNames
```

## Failure output
```
Expectation failed: ConversationRow.senders(corp) == "Jan & Sergio"
ConversationRow.senders(corp) → "Jan (mgm-tp) & Sergio Luis"
Expectation failed: ConversationRow.senders(nbsp) == "Jan & Bob"
ConversationRow.senders(nbsp) → "Jan Jikeli & Bob"
```

## Fix idea
After taking the part after the comma, split on `isWhitespace` (as `initials` does) and take the first word.
