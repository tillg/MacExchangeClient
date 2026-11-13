---
title: 'Message menu differs from MainMenu.nib: "Mark as Read/Unread", Toggle Flag outside the Flag submenu, Move to Junk after Archive, Delete in Message instead of Edit'
priority: P4
area: UI / MailCommands
status: open
found: 2026-11-13
---
Draft id: R5N-02 (probe suites `Probe_R5*` in `probes/Probe_R5*Tests.swift`).

## Summary
The Message menu has the right shortcuts but not Mail's titles and layout:
- the read item is titled "Mark as Read/Unread"; Mail shows "Mark as Read" or "Mark as Unread" for the selection;
- Toggle Flag (⇧⌘L) is a top-level item; in Mail it is the last item of the Flag submenu, after Clear Flag;
- Move to Junk sits after Archive; in Mail it follows Mark as Read in the same group, before Flag, and Archive is in the next group;
- Delete (⌘⌫) is in the Message menu; in Mail it is Edit ▸ Delete (after Paste, before Select All). The Message menu has no Delete.

## Expected
Mail.app `Base.lproj/MainMenu.nib`, menu "Message" (#2267) in order: Send ⇧⌘D, —, Reply, Reply All, Forward, …, —, Mark as Read ⇧⌘U, Move to Junk ⇧⌘J, Mute, Flag ▸ (colours, —, Clear Flag, Toggle Flag ⇧⌘L), Set Priority, —, Archive ⌃⌘A, Move to Predicted Mailbox, Move to, Copy to, … Menu "Edit" (#2096): Undo, Redo, —, Cut, Copy, Paste, Delete ⌘⌫ (`Mail.menuBar.editMenu.delete`), Select All. `Localizable.loctable` en: `MarkReadMenuItem` "Mark as Read", `MarkUnreadMenuItem` "Mark as Unread". README: "Menu bar and shortcuts taken from Mail's own `MainMenu.nib`"; Shortcuts ✅ `MainMenu.nib`.

## Repro
No probe (menu built in the view layer). Evidence: code + bundle.
- `Sources/MailReplica/MailCommands.swift:67` `Button("Mark as Read/Unread")`
- `MailCommands.swift:69-78` Toggle Flag as a top-level item before `Menu("Flag")`, which ends with Clear Flag
- `MailCommands.swift:81-84` Archive, then Move to Junk
- `MailCommands.swift:85-94` `Button("Delete")…keyboardShortcut(.delete)` inside `CommandMenu("Message")`
- Bundle dump: `python3 nibdump.py`-based tree of `MainMenu.nib` menu `MailViewer`.

## Failure output
Message menu (replica): Send, —, Reply, Reply All, Forward, —, Mark as Read/Unread, Toggle Flag, Flag ▸ (…, Clear Flag), —, Archive, Move to Junk, Delete.
Mail: Send, —, Reply, Reply All, Forward, …, —, Mark as Read, Move to Junk, Mute, Flag ▸ (…, Clear Flag, Toggle Flag), Set Priority, —, Archive, …; Delete under Edit.

## Fix idea
In `MailCommands.swift`: title from the selection ("Mark as Unread" when all are read, as `MessageContextMenu` already does), move Toggle Flag into `Menu("Flag")` after Clear Flag, put Move to Junk right after the read item, and move Delete to `CommandGroup(after: .pasteboard)`-equivalent position in Edit (keeping the BUG-218 text-view handling).
