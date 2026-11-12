---
title: Reply All leaves a trailing ", " (empty recipient) when the original lists a recipient without address
priority: P4
area: MailStore
status: open
found: 2026-11-12
---
## Summary
Reply All joins the emails of From + To + Cc without dropping empty ones. A recipient with no address (e.g. "Undisclosed recipients", or a group with no address from Exchange) produces `"ann@x.com, "`, an empty entry in To.

## Repro
File `specs/bugs/probes/Probe_LeadTests.swift`:
```swift
@Test func probe_replyAllSkipsRecipientsWithoutAddress() {
    let m = Message(accountID: work.id, mailbox: .inbox, from: Contact(name: "Ann", email: "ann@x.com"),
                    to: [Contact(name: "Me", email: work.address), Contact(name: "Undisclosed recipients", email: "")],
                    subject: "Hi", body: "b", date: Date(timeIntervalSince1970: 1_000_000))
    let s = MailStore(accounts: [work], messages: [m])
    let d = s.draft(.replyAll, to: m.id)
    #expect(d.to == "ann@x.com", "to: \(d.to.debugDescription)")
}
```

## Expected vs actual
Expected `"ann@x.com"`. Actual:
```
Expectation failed: d.to == "ann@x.com"
  d.to → "ann@x.com, "
```

## Why expected
Mail never puts an empty token in To. The trailing separator shows in the compose field and makes an empty recipient.

## Likely cause
`Sources/MailModel/MailStore.swift:1222`: `.map(\.email).filter { $0 != me }` with no `!$0.isEmpty` filter. (The case-sensitive `!= me` is filed separately, as the Reply All own-address bug.)
