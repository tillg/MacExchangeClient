---
title: "An address pasted with a BOM or word joiner around it keeps the invisible character and goes to an address that doesn't exist"
priority: P4
area: compose / recipients
status: open
found: 2026-11-13
---

## Summary
`Contact.parseList` trims blanks and line breaks (`.whitespacesAndNewlines`, which also covers U+200B) but not other invisible format characters. "\u{FEFF}ann@x.com" (BOM at the start of text copied from a file) and "Ann <ann@x.com\u{2060}>" (word joiner from a web page) keep them in `email`; the To field looks right, the message is sent to an address Exchange can't resolve (NDR) and Reply All/“adds new recipient” checks compare against the wrong string.

## Expected
RFC 5321 §4.1.2 / RFC 5322 §3.4.1: an addr-spec has no such characters; Unicode TR#31/UAX#9 list U+FEFF and U+2060 as default-ignorable (invisible).

## Repro
Probe `Probe_R5I_Recipients/invisibleCharactersAroundAddressAreDropped` in `Tests/MailModelTests/Probe_R5ITests.swift`:

```sh
swift test --package-path . --scratch-path .build/tests --skip-build --filter Probe_R5I_Recipients/invisibleCharactersAroundAddressAreDropped
```
(after the test build from CLAUDE.md)

## Failure output
```
Expectation failed: e == "ann@x.com"   "\u{FEFF}ann@x.com" -> Optional("\u{FEFF}ann@x.com")
Expectation failed: e == "ann@x.com"   "Ann <ann@x.com\u{2060}>" -> Optional("ann@x.com\u{2060}")
```

## Fix idea
In `Contact.parseList`, trim default-ignorable format characters (U+FEFF, U+2060, U+200C/D, bidi marks) with the whitespace from each address.
