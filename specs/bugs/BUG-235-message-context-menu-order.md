---
title: 'Message list context menu: Move to Junk and Delete come after Archive; in Mail they follow Mark as Read, before Flag, and Move to is missing'
priority: P4
area: UI / MessageListView
status: open
found: 2026-11-13
---
Draft id: R5N-09 (probe suites `Probe_R5*` in `probes/Probe_R5*Tests.swift`).

## Summary
The message list's Control-click menu is Reply, Reply All, Forward, —, Mark as Read/Unread, Flag ▸, —, Archive, Move to Junk, Delete. Mail's message context menu puts Move to Junk and Delete in the Mark as Read group before Flag, then Archive and Move to after Flag. The app has a Move menu (toolbar), but the context menu has no Move to. No README row marks this menu ✅; this is a mismatch against the bundle the README says the details come from ("The details come from Mail.app's own resources"), not against a specific ✅ claim.

## Expected
Mail.app `Base.lproj/MessageViewerContextMenu.nib`, menu "Menu": Open, Send, Reply, Reply All, Forward, Forward as Attachment, Redirect, —, Remind Me ▸, Ignore Follow Up, —, Mark as Read, Move to Junk, Mute Conversation, Delete, Block Sender, …, —, Flag ▸, —, Archive, Move to Predicted Mailbox, Move to ▸, Copy to ▸, —, Apply Rules. Titles in `MessageViewerContextMenu.loctable` (17 "Mark as Read", 16 "Move to Junk", 26 "Delete", 57 "Flag", 115 "Archive", 116 "Move to").

## Repro
No probe (view layer). Evidence: code + bundle.
- `Sources/MailReplica/MessageListView.swift:203-212` (`MessageContextMenu.body`)

## Failure output
Replica: …, Mark as Read, Flag ▸, —, Archive, Move to Junk, Delete. Mail: …, Mark as Read, Move to Junk, Delete, —, Flag ▸, —, Archive, Move to ▸.

## Fix idea
Reorder `MessageContextMenu` to Mark, Move to Junk, Delete, —, Flag, —, Archive, Move to (reuse `MoveMenu`'s list); update functional.md line 49-50.
