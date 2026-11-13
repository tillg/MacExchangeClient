---
title: "Reply and Reply All ignore the sender's Reply-To and go to From (e.g. noreply@)"
priority: P2
area: compose / EWS body
status: open
found: 2026-11-13
---
Draft id: R5D-01 (probe suites `Probe_R5*` in `probes/Probe_R5*Tests.swift`).

## Summary
A message with a `Reply-To` header (shops, ticket systems, mailing lists, colleagues who set one) is answered to its `From` address. `bodyRequest` never asks Exchange for `message:ReplyTo`, `Message` has no field for it, and `MailStore.draft` builds To from `m.from`. A reply to `noreply@shop.example` that asked for answers at `support@shop.example` goes to the no-reply box (bounced or unread). P2 rather than P1: the wrong address is visible in To before Send.

## Expected
RFC 5322 §3.6.2: "When the 'Reply-To:' field is present, it indicates the address(es) to which the author of the message suggests that replies be sent." Reply → Reply-To addresses; Reply All → Reply-To plus To/Cc. EWS exposes it as `message:ReplyTo` (`t:ReplyTo/t:Mailbox`). Not in limitations.md or feature-map (feature-map 211 is about writing a Reply-To, not honouring one).

## Repro
Probe `Probe_R5D_Compose/replyGoesToReplyToAddress` in `Tests/MailModelTests/Probe_R5DTests.swift`:

```sh
swift test --package-path . --scratch-path .build/tests --skip-build --filter Probe_R5D_Compose/replyGoesToReplyToAddress
```
(after the test build from CLAUDE.md)

## Failure output
```
Expectation failed: to == "support@shop.example"
reply goes to noreply@shop.example
```

## Fix idea
Request `message:ReplyTo` in `EWSBackend.bodyRequest`, parse it in `parseBody` into `MessageBody`/`Message.replyTo`; in `MailStore.draft` use it instead of `m.from` for .reply/.replyAll (keep the own-message rule).
