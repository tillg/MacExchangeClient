---
title: 'Sidebar: the Unread smart mailbox shows a bare gear; Mail''s smart mailbox icon is a folder with a gear'
priority: P4
area: UI / SidebarView
status: open
found: 2026-11-13
---
Draft id: R5N-08 (probe suites `Probe_R5*` in `probes/Probe_R5*Tests.swift`).

## Summary
Under Smart Mailboxes, Unread is drawn with the SF Symbol `gearshape` (a gear alone). Mail's smart mailbox icon, `SidebarSmartFolder.icns`, is a folder with a gear on it (SF Symbol `folder.badge.gearshape`). Every other sidebar symbol matches its `Sidebar*.icns` (checked: Inbox tray, Drafts doc, Sent paperplane, Junk xmark.bin, Trash trash, Archive archivebox, VIP star, Flag flag, Folder folder).

## Expected
Mail.app `Resources/SidebarSmartFolder.icns` (rendered with `sips -s format png`): folder with a gear. README row Sidebar: ✅ "`Sidebar*.icns` names".

## Repro
No probe (view layer). Evidence: code + bundle.
- `Sources/MailReplica/SidebarView.swift:46` `row(.smart(.unread), "Unread", "gearshape")`
- `sips -s format png -Z 64 /System/Applications/Mail.app/Contents/Resources/SidebarSmartFolder.icns --out tmp/SmartFolder.png`

## Failure output
Unread row icon: a gear. Mail: a folder with a gear.

## Fix idea
`"folder.badge.gearshape"` (and make `SmartMailbox.unread.symbol` in `Models.swift`, now "envelope.badge", agree).
