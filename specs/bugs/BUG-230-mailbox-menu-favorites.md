---
title: 'Mailbox menu: ⌘1–⌘9 mailboxes sit at the top level instead of under Go to Favorite Mailbox, and Get New Mail has its own group'
priority: P4
area: UI / MailCommands
status: open
found: 2026-11-13
---
Draft id: R5N-04 (probe suites `Probe_R5*` in `probes/Probe_R5*Tests.swift`).

## Summary
The Mailbox menu lists the favourite mailboxes (⌘1–⌘9) as top-level items. In Mail they are in the submenu Mailbox ▸ Go to Favorite Mailbox. Also a divider separates Get New Mail from Mark All Messages as Read; in Mail they are in the same first group.

## Expected
Mail.app `Base.lproj/MainMenu.nib`, menu "Mailbox" (#2237): Get New Mail ⇧⌘N, Synchronize, Mark All Messages as Read, —, Erase Deleted Items, Erase Junk Mail, —, New Mailbox…, …, —, Open Quickly…, Go to Favorite Mailbox ▸ (#2249: Mailbox 1 ⌘1 … Mailbox 9 ⌘9), Move to Favorite Mailbox ▸, … README Shortcuts ✅ `MainMenu.nib` ("Go to mailbox ⌘1–9").

## Repro
No probe (view layer). Evidence: code + bundle.
- `Sources/MailReplica/MailCommands.swift:49-50` `Button("Get New Mail")…` then `Divider()`
- `MailCommands.swift:53-56` `ForEach(store.favoriteMailboxes…) { Button(label(ref))… }` directly in `CommandMenu("Mailbox")`

## Failure output
Mailbox (replica): Get New Mail, —, Mark All Messages as Read, —, All Inboxes ⌘1, <account> Inbox ⌘2, …
Mail: Get New Mail, Synchronize, Mark All Messages as Read, —, …, Go to Favorite Mailbox ▸ (⌘1…⌘9).

## Fix idea
Drop the divider after Get New Mail and wrap the `ForEach` in `Menu("Go to Favorite Mailbox")` after a divider.
