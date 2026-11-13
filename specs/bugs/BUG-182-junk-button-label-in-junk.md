---
title: 'Junk button, menu and context menu keep saying "Junk" / "Move to Junk" in the Junk mailbox, where they move mail to the Inbox'
priority: P4
area: UI / MessageViewer, MailCommands, MessageListView
status: open
found: 2026-11-13
---
Draft id: R5E-05 (probe suites `Probe_R5*` in `probes/Probe_R5*Tests.swift`).

## Summary
`toggleJunk` moves mail back to the Inbox when all selected messages are in Junk (functional.md: "Not Junk"). But every control still describes the opposite: the toolbar segment's help is "Mark selected messages as junk mail", Message ▸ "Move to Junk" (⇧⌘J) and the context menu "Move to Junk". In Junk, "Move to Junk" takes the mail out of Junk. The toolbar help text also isn't Mail's.

## Expected
Mail.app `MainWindow.toolbar`, segment `moveToJunk:` of `archive_delete_junk`: `help` = `ToolTipJunk` ("Move selected messages to Junk"), `altTitle` = `ToolbarNotJunk` ("Not Junk"). `Localizable.loctable`: `NotJunk` "Not Junk", `ToolTipNotJunk` "Move selected messages to Inbox". README claims the toolbar is ✅ from `MainWindow.toolbar`.

## Repro
No probe: UI only (labels and tooltips; menus and tooltips can't be captured by the snapshot hook). Code: `MessageViewer.swift` `.help("Mark selected messages as junk mail")`; `MailCommands.swift` `Button("Move to Junk")`; `MessageListView.swift` `MessageContextMenu` `Button("Move to Junk")`. Context snapshot of the Junk mailbox (toolbar unchanged):
```sh
defaults delete MailReplicaSnapshot; tools/snapshot.sh $PWD/tmp/e05j.png MAIL_SNAPSHOT_SIZE=1280x800 MAIL_SNAPSHOT_MAILBOX=iCloud/junk
```
PNG: `specs/bugs/png/BUG-182-junk-mailbox-toolbar.png`.

## Failure output
In Junk the toolbar, menu and context menu say Junk / Move to Junk; Mail says Not Junk / "Move selected messages to Inbox".

## Fix idea
When every selected message is in Junk, title "Not Junk" and help `ToolTipNotJunk`; otherwise help "Move selected messages to Junk". Same condition as `toggleJunk` (expose it from `MailStore`).
