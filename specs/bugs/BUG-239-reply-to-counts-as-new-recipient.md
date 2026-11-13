---
title: "Include Attachments ▸ When Adding Recipients: a reply to a message with Reply-To pulls in the original's files though no one was added"
priority: P3
area: compose / Include Attachments With Replies
status: open
found: 2026-11-13
---

## Summary
A reply goes to the Reply-To addresses when the message has them (mailing lists, ticket systems, newsletters). `addsNewRecipient` knows only From, To, Cc and the account's address as "on the original", not Reply-To. With When Adding Recipients, just leaving the untouched To field (or pressing Return, or adding a Cc who was on the original) adds the original's files, and they go out to the list.

## Expected
functional.md: "When Adding Recipients: on leaving To/Cc or Return, if an address with '@' wasn't on the original". The Reply-To addresses are on the original (RFC 5322 §3.6.2) and are what the app itself put in To; nobody was added.

## Repro
Probe `Probe_R5K_Attachments/replyToAddressIsNotANewRecipient` in `Tests/MailModelTests/Probe_R5KTests.swift`:
```sh
swift test --package-path . --scratch-path .build/tests --skip-build --filter Probe_R5K_Attachments/replyToAddressIsNotANewRecipient
```

## Failure output
```
Expectation failed: !s.addsNewRecipient(d)
  the untouched reply counts as adding a recipient: To = team@lists.x.com, tickets@x.com
```

## Fix idea
In `MailStore.addsNewRecipient`, add `m.replyTo ?? []` to `original`.
