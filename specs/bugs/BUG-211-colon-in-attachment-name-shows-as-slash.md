---
title: "⚠️ An attachment with \":\" in its name (attached message \"Re: Budget\") is saved as \"Re/ Budget.eml\" in the Finder"
priority: P4
area: attachments
status: open
found: 2026-11-13
---

## Summary
`Attachment.fileName` maps "/" to ":" so the Finder shows a sender's "/" as "/", but keeps the sender's own ":". On macOS a ":" in a POSIX file name is shown as "/" by the Finder, the Save panel and Quick Look's title. Attached messages are named after their subject, which usually has a colon ("Re:", "AW:", "Fwd:", times like "10:30"), so "Re: Budget 10:30.eml" appears as "Re/ Budget 10/30.eml" in Mail Downloads, Save Attachment and drag-out.

## Expected
Apple File System Programming Guide / HFS+ ↔ POSIX name mapping: ":" in a POSIX name displays as "/" in Cocoa/Finder. What to show instead (Mail uses "-"?) is ⚠️ recalled, hence P4.

## Repro
Probe `Probe_R5I_Attachments/colonInNameIsNotShownAsSlashInFinder` in `Tests/MailModelTests/Probe_R5ITests.swift`:

```sh
swift test --package-path . --scratch-path .build/tests --skip-build --filter Probe_R5I_Attachments/colonInNameIsNotShownAsSlashInFinder
```
(after the test build from CLAUDE.md)

## Failure output
```
Expectation failed: !a.fileName.contains(":")
  a.fileName → "Re: Budget 10:30.eml"  (shows as Re/ Budget 10/30.eml)
```

## Fix idea
In `Attachment.fileName`, replace the sender's ":" (before mapping "/" to ":") with "-" (or U+A789), keeping the "/" mapping.
