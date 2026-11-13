---
title: "A deleted appointment or task in Trash can't be erased: DeleteItem lacks SendMeetingCancellations / AffectedTaskOccurrences"
priority: P2
area: ews
status: open
found: 2026-11-13
---

## Summary
An appointment or task deleted in Outlook goes to Deleted Items. The Trash sync lists it like a message, because
`EWSBackend.message` accepts any item with an `ItemId` (`t:CalendarItem`, `t:Task`). Delete in Trash then sends
`<m:DeleteItem DeleteType="SoftDelete">` with neither `SendMeetingCancellations` nor `AffectedTaskOccurrences`.
Exchange refuses that for calendar items and tasks. The app undoes the erase and both items come back with "Exchange
refused a change: … (ErrorAffectedTaskOccurrencesRequired)", every time. Emptying Trash never gets rid of them.

## Expected
- https://learn.microsoft.com/en-us/exchange/client-developer/web-service-reference/deleteitem (fetched):
  "**SendMeetingCancellations** … This attribute is required when calendar items are deleted. This attribute is
  optional if non-calendar items are deleted." "**AffectedTaskOccurrences** … This attribute is required when tasks
  are deleted. This attribute is optional when non-task items are deleted." "The DeleteItem operation can be performed
  on any item type."
- https://learn.microsoft.com/en-us/exchange/client-developer/web-service-reference/responsecode (fetched):
  "**ErrorSendMeetingCancellationsRequired**: This error is returned by the DeleteItem operation if the
  SendMeetingCancellations attribute is missing from the request and the item to delete is a calendar item." and
  "**ErrorAffectedTaskOccurrencesRequired**: … When the DeleteItem element is used to delete at least one item that is
  a task, … the AffectedTaskOccurrences attribute has to be specified".
- Erasing from Trash should work for whatever Trash lists. Since the attributes are optional for other items, adding
  them always is safe.

## Repro
Probe `Probe_R5JTests/r5j03_eraseAppointmentAndTaskFromTrash` in `Tests/MailModelTests/Probe_R5JTests.swift`. The Trash
is filled through the real `EWSBackend.parseSync` from a SyncFolderItems page with a `t:CalendarItem` and a `t:Task`.
The real `MailStore` → `EWSBackend` → `EWSClient` then erase them over HTTP to a loopback server. That server answers
DeleteItem as the ResponseCode reference above documents.

```sh
swift test --package-path . --scratch-path .build/tests --skip-build --filter Probe_R5JTests/r5j03_eraseAppointmentAndTaskFromTrash
```
(after the test build from CLAUDE.md)

## Failure output
```
Expectation failed: s.messages.isEmpty
back in Trash: ["Dentist", "Call back"]; status: Exchange refused a change: AffectedTaskOccurrences attribute is required for Task items. (ErrorAffectedTaskOccurrencesRequired)
Expectation failed: del?.attr("SendMeetingCancellations") == "SendToNone" && del?.attr("AffectedTaskOccurrences") != nil
DeleteItem attributes: ["DeleteType=SoftDelete"]
```

## Fix idea
`EWSBackend.deleteRequest`: always add `SendMeetingCancellations="SendToNone" AffectedTaskOccurrences="AllOccurrences"`
(erasing from Trash must not send cancellations). Separately, consider whether non-mail items belong in the list at all.
