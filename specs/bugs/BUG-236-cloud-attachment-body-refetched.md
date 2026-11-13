---
title: "A message with a cloud attachment (OneDrive/SharePoint link) fetches its body again every time it is shown"
priority: P4
area: attachments / EWS
status: open
found: 2026-11-13
---

## Summary
`listedAttachments` lists a `ReferenceAttachment` as "Name.webloc" with no size (d-bug-145). `Message.needsBody` treats any attachment without a size as "body loaded by an old version" and asks for the body again. So the body of such a message is fetched on every showing, before every reply and before every forward (`loadedDraft`, `includeOriginalAttachments`): one extra GetItem each time, for good. (⚠️ d-bug-145: with RequestServerVersion Exchange2013_SP1 an on-prem server may never return one.)

## Expected
Plain correctness and domain-model.md: `needsBody` is meant for bodies "loaded before attachments had a size". A body that was just loaded is not "old"; it is fetched once.

## Repro
Probe `Probe_R5K_Attachments/cloudAttachmentBodyIsFetchedOnce` in `Tests/MailModelTests/Probe_R5KTests.swift` (loopback ScriptedServer):
```sh
swift test --package-path . --scratch-path .build/tests --skip-build --filter Probe_R5K_Attachments/cloudAttachmentBodyIsFetchedOnce
```
(after the test build from CLAUDE.md)

## Failure output
```
Expectation failed: s.message(id)?.needsBody == false
  needsBody stays true after the body loaded
Expectation failed: server.served == 1
  body fetched 3 times for one message
```

## Fix idea
Exempt link attachments from the size test (e.g. give the `.webloc` a size, or check `size == nil && contentType != nil`/a link flag) in `Message.needsBody` or `EWSBackend.listedAttachments`.
