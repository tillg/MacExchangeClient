---
title: "An account whose server doesn't answer (on-prem Exchange off the VPN) holds up the other accounts' new mail and changes for up to 60 s per check"
priority: P3
area: MailStore
status: open
found: 2026-11-13
---
Draft id: R5G-06 (probe suites `Probe_R5*` in `probes/Probe_R5*Tests.swift`).

## Summary
BUG-096 made an unreachable account's *error* stop only that account's changes. A server that doesn't answer at all (packets dropped, as an on-prem server is when the VPN is off) gives no error until `EWSClient`'s 60 s timeout. `drain` sends changes one at a time, oldest first, so a change of account A waits 60 s, and every change and send of account B queued after it waits too. `refresh` first awaits the flush, so B's quick check (new mail) waits as well; and the quick check itself goes through the accounts one after the other. Every 15 s cycle repeats it.

## Expected
README: "When only one account's server can't be reached, only that account's changes wait; the others go out". What's New 2026-11-13: "When one account's server can't be reached, your other accounts still send your messages and changes right away" and "… stay up to date".

## Repro
`EWSFlowTests/Probe_R5GRaces/aServerThatDoesntAnswerHoldsUpTheOtherAccount` (A on a held loopback server, B answering; A has a flag change queued):
```
swift test --package-path W --scratch-path W/.build/tests --skip-build --filter Probe_R5GRaces/aServerThatDoesntAnswerHoldsUpTheOtherAccount
```

## Failure output
```
Expectation failed: arrived
B's new mail didn't arrive within 5 s while A's server was silent (B served 1)
```
(B was asked only after A's answer was released.)

## Fix idea
Run `drain` per account (one task per account, order kept within an account) and don't make the quick check await other accounts' flushes; check accounts concurrently (a task group over `backends`) in `refresh`.
