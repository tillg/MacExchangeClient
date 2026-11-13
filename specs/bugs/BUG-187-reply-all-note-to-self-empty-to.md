---
title: "Reply All to a note sent only to myself opens with an empty To"
priority: P4
area: compose
status: open
found: 2026-11-13
---
Draft id: R5D-02 (probe suites `Probe_R5*` in `probes/Probe_R5*Tests.swift`).

## Summary
For a message from me to me, Reply gives To = me (BUG-029 follow-up), but Reply All removes my own address from both From and To and opens a window with an empty To field.

## Expected
Same rule as Reply (functional.md Compose: "if none is left, the sender's address"; DECISIONS d-bug-029 / commit 45517e5 "a reply to a note only to myself still goes to me"). ⚠️ Inference: those sources state the fallback for Reply only; Reply All yielding fewer recipients than Reply (none) is plain inconsistency.

## Repro
Probe `Probe_R5D_Compose/replyAllToNoteToSelfGoesToMe` in `Tests/MailModelTests/Probe_R5DTests.swift`:

```sh
swift test --package-path . --scratch-path .build/tests --skip-build --filter Probe_R5D_Compose/replyAllToNoteToSelfGoesToMe
```
(after the test build from CLAUDE.md)

## Failure output
```
Expectation failed: to == "me@work.com"
Reply All To is ""
```

## Fix idea
`MailStore.draft` .replyAll: if `to` and `cc` both come out empty, fall back to the .reply result (`m.from.email`).
