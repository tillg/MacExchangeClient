---
title: 'Answering an invite moves the selection to another conversation, but only when the selection holds the invite rather than its row'
priority: P4
area: MailStore / conversations
status: open
found: 2026-11-13
---
Draft id: R5A-06 (probe suites `Probe_R5*` in `probes/Probe_R5*Tests.swift`).

## Summary
An older invite is selected and shown, then a reply arrives in its conversation, so the row now stands for the reply. Answering the invite (Accept etc.) goes through `answer` → `selection == [id]` → `actOnSelection`. That moves the selection to the next conversation, "Other", which is opened and marked read, although the conversation row (the reply) stays in the list. When the same row was selected by clicking it (`selection == [row]`), the same answer keeps the row selected (the control in the probe passes). On screen the two states look the same, so the outcome shouldn't differ. functional.md says an answered selected invite selects the next message. That fits a list where the invite is the row; here the row stays.

## Expected
functional.md "No hidden selection": "A selected message that stays in the list stays selected". The probe's control shows the rule the app follows when the row is selected directly.

## Repro
Probe: `answeringTheShownInviteKeepsItsConversationRowSelected` in `Tests/MailModelTests/Probe_R5ATests.swift`.

```
swift build --package-path W --scratch-path W/.build/tests --target MailModelTests -Xswiftc -load-plugin-library -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
swift test --package-path W --scratch-path W/.build/tests --skip-build --filter Probe_R5A/answeringTheShownInviteKeepsItsConversationRowSelected
```

## Failure output
```
Expectation failed: s.listSelection == [row]
selection moved to ["Other"]
```

## Fix idea
In `answer`, decide by rows: use `actOnSelection` only when the invite's row leaves the list. Otherwise use `keepingSelectionVisible` (with the BUG-155 fix).
