---
title: 'The window subtitle says "1 messages" for a mailbox with one message'
priority: P4
area: UI / MessageViewer
status: open
found: 2026-11-13
---
Draft id: R5E-01 (probe suites `Probe_R5*` in `probes/Probe_R5*Tests.swift`).

## Summary
The subtitle under the mailbox title is built as `"\(n) messages"` with no singular form. A mailbox holding one message (sample data: Work ▸ Drafts, iCloud ▸ Junk, Work ▸ Sent) reads "1 messages".

## Expected
"1 message". Mail.app `Localizable.loctable`, key `MessagesStatusFormat%1$lu`: `one` = "%1$lu message", `other` = "%1$lu messages" (and `MessagesStatusFormatWithUnread%1$lu%2$lu` likewise). specs/system/functional.md: subtitle is "N messages, U unread".

## Repro
No probe: UI only (the text is built in the view). Snapshot:
```sh
defaults delete MailReplicaSnapshot; tools/snapshot.sh $PWD/tmp/e01.png MAIL_SNAPSHOT_SIZE=1280x800 MAIL_SNAPSHOT_MAILBOX=Work/drafts
```
PNG: `specs/bugs/png/BUG-178-subtitle-1-messages.png` (crop: `…-crop.png`).

## Failure output
Subtitle reads "Drafts / 1 messages" (seen in the PNG; also iCloud/junk and Work/sent).

## Fix idea
`MessageViewer.subtitle`: use a plural-aware string (`^[\(n) message](inflect: true)` or a `.stringsdict`), for the unread part too.
