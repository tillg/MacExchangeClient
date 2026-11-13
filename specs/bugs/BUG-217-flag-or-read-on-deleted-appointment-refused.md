---
title: "Flagging or marking read a deleted appointment in Trash is refused and undone (UpdateItem lacks SendMeetingInvitationsOrCancellations)"
priority: P3
area: ews
status: open
found: 2026-11-13
---

## Summary
A deleted appointment in Deleted Items is listed in Trash like a message (see BUG-216). It shows as unread, because a
calendar item has no `IsRead`. Flagging it or marking it read sends
`UpdateItem MessageDisposition="SaveOnly" ConflictResolution="AlwaysOverwrite" SuppressReadReceipts="true"` with a
`t:Message` wrapper and no `SendMeetingInvitationsOrCancellations`. Exchange refuses that for a calendar item, so the
flag or read state springs back with "Exchange refused a change: …".

## Expected
- https://learn.microsoft.com/en-us/exchange/client-developer/web-service-reference/responsecode (fetched):
  "**ErrorSendMeetingInvitationsOrCancellationsRequired**: This error is returned by the UpdateItem operation if the
  SendMeetingInvitationsOrCancellations attribute is missing from the request and the item to update is a calendar item."
- Exchange 2013 SP1 `messages.xsd`, `UpdateItemType`: `SendMeetingInvitationsOrCancellations` is an optional
  attribute, so sending `SendToNone` always is valid.
- ⚠️ `IsRead` is defined on `MessageType` only, not on `CalendarItemType` (types.xsd). A read write for a calendar item
  may still be refused with the attribute; skipping read writes for non-message items, and not showing them unread, is
  the likely full fix. Not checked on a live server.

## Repro
Probe `Probe_R5JTests/r5j04_flagAppointmentInTrash` in `Tests/MailModelTests/Probe_R5JTests.swift`. It uses the same
loopback server as BUG-216, which answers UpdateItem as the ResponseCode reference above documents.

```sh
swift test --package-path . --scratch-path .build/tests --skip-build --filter Probe_R5JTests/r5j04_flagAppointmentInTrash
```
(after the test build from CLAUDE.md)

## Failure output
```
Expectation failed: s.message(cal.id)?.flag != nil
flag undone; status: Exchange refused a change: SendMeetingInvitationsOrCancellations attribute is required for Calendar items. (ErrorSendMeetingInvitationsOrCancellationsRequired)
Expectation failed: upd?.attr("SendMeetingInvitationsOrCancellations") != nil
UpdateItem attributes: ["MessageDisposition=SaveOnly", "ConflictResolution=AlwaysOverwrite", "SuppressReadReceipts=true"]
```

## Fix idea
`EWSBackend.updateRequest`: add `SendMeetingInvitationsOrCancellations="SendToNone"`. In `EWSBackend.message`, mark
non-message items (no `IsRead` in the summary, element other than Message/Meeting*) as read so they don't count as unread.
