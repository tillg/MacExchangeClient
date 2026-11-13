---
title: "Placed pictures are sent with a Content-ID without \"@\" (bare UUID)"
priority: P4
area: compose / sent HTML
status: open
found: 2026-11-13
---
Draft id: R5D-12 (probe suites `Probe_R5*` in `probes/Probe_R5*Tests.swift`).

## Summary
`EWSBackend.contentIDs` gives each placed picture `UUID().uuidString` as ContentId, so the sent MIME has `Content-ID: <3F05…020B>` and the HTML `cid:3F05…020B`. That isn't a msg-id (ews.md:83 documents the UUID but no decision chose the form). ⚠️ Effect on receivers not verified.

## Expected
RFC 2045 §7: Content-ID uses msg-id syntax; RFC 5322 §3.6.4: msg-id = "<" id-left "@" id-right ">". RFC 2392 cid URLs refer to that addr-spec.

## Repro
Probe `Probe_R5D_Compose/placedPictureContentIDIsAMsgID` in `Tests/MailModelTests/Probe_R5DTests.swift`:

```sh
swift test --package-path . --scratch-path .build/tests --skip-build --filter Probe_R5D_Compose/placedPictureContentIDIsAMsgID
```
(after the test build from CLAUDE.md)

## Failure output
```
Expectation failed: !ids.isEmpty && ids.values.allSatisfy { $0.contains("@") }
[0: "3F059CD3-BE4C-466B-BCBC-36172699020B"]
```

## Fix idea
`EWSBackend.contentIDs`: `"\(UUID().uuidString)@\(sender domain or "mail-replica.local")"`.
