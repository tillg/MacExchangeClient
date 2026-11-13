---
title: "Erasing a message from Trash doesn't suppress read receipts (DeleteItem without SuppressReadReceipts)"
priority: P3
area: ews
status: open
found: 2026-11-13
---

## Summary
Delete in Trash sends `DeleteItem DeleteType="SoftDelete"` with no `SuppressReadReceipts` attribute. Marking read
sends `UpdateItem … SuppressReadReceipts="true"`, so the app never sends a receipt when you read a message, but erasing
an unread message that asked for a read receipt can make Exchange send the sender a "not read" receipt, saying you
deleted it without reading it.

## Expected
- No receipts are sent: README ("read state (without sending read receipts)") and docs/feature-map.md #48 ("Received
  requests are ignored on purpose").
- Microsoft's DeleteItem reference, https://learn.microsoft.com/en-us/exchange/client-developer/web-service-reference/deleteitem
  (fetched): "**SuppressReadReceipts** — Indicates whether read receipts for the deleted item are suppressed. A text
  value of true indicates that the read receipts are suppressed. A value of false indicates that the read receipts are
  sent to the sender. This attribute is optional." The Exchange 2013 SP1 `messages.xsd` has it on `DeleteItemType`
  (`<xs:attribute name="SuppressReadReceipts" type="xs:boolean" use="optional"/>`).
- ⚠️ The page doesn't say what happens when the attribute is left out. That Exchange then sends the receipt (as with
  `false`) is inferred, not confirmed on a live server; hence P3.

## Repro
Probe `Probe_R5JTests/r5j01_eraseSuppressesReadReceipts` in `Tests/MailModelTests/Probe_R5JTests.swift`. It runs the real
`EWSBackend.delete` over HTTP to a loopback server that records the request body.

```sh
swift test --package-path . --scratch-path .build/tests --skip-build --filter Probe_R5JTests/r5j01_eraseSuppressesReadReceipts
```
(after the test build from CLAUDE.md)

## Failure output
```
Expectation failed: del.attr("SuppressReadReceipts") == "true"
DeleteItem attributes: ["DeleteType=SoftDelete"]
```

## Fix idea
`EWSBackend.deleteRequest`: add `SuppressReadReceipts="true"` to `m:DeleteItem`, as `updateRequest` already does.
