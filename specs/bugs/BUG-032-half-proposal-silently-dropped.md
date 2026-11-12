---
title: A proposed new time with only a start (or only an end) is accepted, then silently sent as a plain answer
priority: P3
area: MailStore
status: open
found: 2026-11-12
---
## Summary
`respond(_ reply: InviteReply, to:)` refuses a proposal only when both times are set and end <= start. If only `proposedStart` or only `proposedEnd` is set, the reply is queued. `EWSBackend` writes `ProposedStart`/`ProposedEnd` only when both exist, so the organizer gets a plain Tentative/Decline and no proposal, while the user thinks they proposed a time.

## Repro
File `specs/bugs/probes/Probe_LeadTests.swift` (`probe_proposalWithStartButNoEndIsRefused`, `probe_proposalWithEndButNoStartIsRefused`):
```swift
@Test func probe_proposalWithStartButNoEndIsRefused() {
    let (s, id) = inviteStore()   // one remote invite "M", see the probe file
    s.respond(InviteReply(response: .tentative, proposedStart: Date(timeIntervalSince1970: 2_100_000)), to: id)
    #expect(s.outbox.isEmpty, "queued: \(s.outbox.map(\.change))")
}
```

## Expected vs actual
Expected: refused with a status message (as for end <= start) and nothing queued.
Actual:
```
Expectation failed: s.outbox.isEmpty
  s.outbox → [PendingChange(... change: ServerChange.reply("M", InviteReply(response: .tentative, ..., proposedStart: Optional(1970-01-25 07:20:00 +0000), proposedEnd: nil)) ...)]
```
The end-only case fails the same way.

## Why expected
The store already validates proposals ("The proposed meeting must end after it starts."). A proposal needs both times: EWS `EWSBackend.swift:228` sends them only as a pair, so a half proposal is lost without notice.

## Likely cause
`Sources/MailModel/MailStore.swift:869`: `if let s = reply.proposedStart, let e = reply.proposedEnd, e <= s`. It should also refuse when exactly one of the two is nil.
