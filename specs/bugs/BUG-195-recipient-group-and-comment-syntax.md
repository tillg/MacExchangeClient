---
title: "Recipients written with RFC 5322 group syntax or a comment become invalid addresses (\"Team: a@x.com\", \"a@x.com (Ann)\")"
priority: P4
area: compose
status: open
found: 2026-11-13
---
Draft id: R5D-11 (probe suites `Probe_R5*` in `probes/Probe_R5*Tests.swift`).

## Summary
`Contact.parseList` only knows `Name <addr>` and bare addresses. Group syntax pasted from a header (`Team: a@x.com, b@y.com;`) gives the address `Team: a@x.com`, and an address with a comment (`a@x.com (Ann Smith)`) gives `a@x.com (Ann Smith)`; Exchange rejects or bounces those recipients.

## Expected
RFC 5322 §3.4 (group = display-name ":" [group-list] ";") and §3.2.2 (CFWS comments in addresses).

## Repro
Probe `Probe_R5D_Compose/recipientGroupAndCommentSyntax` in `Tests/MailModelTests/Probe_R5DTests.swift`:

```sh
swift test --package-path . --scratch-path .build/tests --skip-build --filter Probe_R5D_Compose/recipientGroupAndCommentSyntax
```
(after the test build from CLAUDE.md)

## Failure output
```
Expectation failed: group == ["a@x.com", "b@y.com"]  → ["Team: a@x.com", "b@y.com"]
Expectation failed: comment == ["a@x.com"]  → ["a@x.com (Ann Smith)"]
```

## Fix idea
In `Contact.parseList`, strip a leading `display-name:` group label and trailing `;`, and remove `( … )` comments (using the comment as the name when there is none).
