---
title: "A message whose text holds one non-UTF-8 byte or a raw control character never opens (\"Unreadable EWS response\" on every try)"
priority: P4
area: ews / transport
status: open
found: 2026-11-13
---

## Summary
`EWSClient.sanitize` repairs only character *references* XML forbids (`&#11;`). A response with a raw byte that isn't UTF-8 (e.g. a Latin-1 "é", 0xE9, from an old mail) or a raw control character (U+000B) is passed to `XMLDocument` unchanged and the whole page fails: the body never loads, the status says "Couldn't load message: Unreadable EWS response … Input is not proper UTF-8" / "PCDATA invalid Char value 11", and every later showing asks again with the same result. The same text as a reference loads (control test). For a sync page or FindItem it would stall the folder in the same way. Not confirmed that Exchange ever emits such bytes (its writer normally escapes), hence P4.

## Expected
Plain correctness/robustness: `sanitize` exists so one bad character from an old mail can't fail a whole page (its doc comment); the raw forms are the same problem.

## Repro
Probe `Probe_R5I_EWS/bodyWithNonUTF8ByteOrRawControlLoads (control: Probe_R5I_EWS/controlInvalidReferenceIsRepaired passes)` in `Tests/MailModelTests/Probe_R5ITests.swift`:

```sh
swift test --package-path . --scratch-path .build/tests --skip-build --filter Probe_R5I_EWS/bodyWithNonUTF8ByteOrRawControlLoads
```
(after the test build from CLAUDE.md)

## Failure output
```
Expectation failed: s.message(id)?.bodyLoaded == true
  status: Couldn't load message: Unreadable EWS response (743 bytes, HTTP 0): Line 1: Input is not proper UTF-8, indicate encoding ! Bytes: 0xE9 0x3C 0x2F 0x74
Expectation failed: s2.message(id2)?.bodyLoaded == true
  status: Couldn't load message: Unreadable EWS response (752 bytes, HTTP 0): Line 1: PCDATA invalid Char value 11
```

## Fix idea
In `EWSClient.sanitize`, also decode invalid UTF-8 as U+FFFD (`String(decoding:)` already does) and replace raw C0 controls other than tab/LF/CR, not only when "&#" occurs.
