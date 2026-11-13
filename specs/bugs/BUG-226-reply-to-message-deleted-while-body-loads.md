---
title: "Reply to an unopened message that is deleted on the server while its body loads opens an empty message from the first account"
priority: P4
area: MailStore
status: open
found: 2026-11-13
---
Draft id: R5G-07 (probe suites `Probe_R5*` in `probes/Probe_R5*Tests.swift`).

## Summary
`loadedDraft` loads the body first (d-bug-068), then calls `draft(kind, to: id)`. If a sync removed the message meanwhile (deleted elsewhere), `draft` falls back to `Draft(accountID: accounts[0].id)`: the compose window opens with no recipient, no subject, no quote, and from the first account, which may be another account than the message's.

## Expected
Plain correctness: Reply answers the message the user chose, from its account; at least it must not switch to another account silently (cf. `sendingAccount`: "never another one").

## Repro
`EWSFlowTests/Probe_R5GRaces/replyToAMessageDeletedWhileItsBodyLoads`:
```
swift test --package-path W --scratch-path W/.build/tests --skip-build --filter Probe_R5GRaces/replyToAMessageDeletedWhileItsBodyLoads
```

## Failure output
```
Expectation failed: d.accountID == acct.id && d.subject == "Re: Budget"
draft from the other account, subject ''
```

## Fix idea
In `loadedDraft`, take the message before loading and build the draft from it when it's gone afterwards (or return nil and let the caller show a status).
