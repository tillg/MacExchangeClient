---
title: 'View menu: Enable Message Filter is not in a Filter submenu, and Back ⇧⌘[ / Forward ⇧⌘] are missing though the toolbar has them'
priority: P4
area: UI / MailCommands, MessageViewer
status: open
found: 2026-11-13
---
Draft id: R5N-03 (probe suites `Probe_R5*` in `probes/Probe_R5*Tests.swift`).

## Summary
- View ▸ Enable Message Filter (⌘L) is a top-level View item after the sidebar toggle; in Mail it is inside View ▸ Filter.
- The toolbar's back/forward through visited mailboxes has no menu items and no shortcuts. Mail has View ▸ Back ⇧⌘[ and View ▸ Forward ⇧⌘] for the same toolbar control (`navigation_forward_back`).

## Expected
Mail.app `Base.lproj/MainMenu.nib`, menu "View" (#2205): Back `[` mask 0x120000 (⇧⌘), id `Mail.menuBar.viewMenu.back`; Forward `]` ⇧⌘, id `Mail.menuBar.viewMenu.forward`; Filter ▸ Enable Message Filter ⌘L (`Mail.menuBar.viewMenu.filter.enableMessageListFilter`). `MainWindow.toolbar` `navigation_forward_back` segments `navigateBack:` / `navigateForward:`. README: Toolbar ✅ includes back/forward; "Menu bar and shortcuts taken from Mail's own `MainMenu.nib`".

## Repro
No probe (view layer). Evidence: code + bundle.
- `Sources/MailReplica/MailCommands.swift:44-47` `CommandGroup(after: .sidebar) { Toggle("Enable Message Filter", …).keyboardShortcut("l") }`
- `Sources/MailReplica/MessageViewer.swift:43-50` back/forward buttons with no `keyboardShortcut` and no menu command anywhere (`grep -n '"\["' Sources/MailReplica` finds nothing).

## Failure output
View menu (replica): …Show Sidebar ⌃⌘S, Enable Message Filter ⌘L. No Back/Forward; ⇧⌘[ does nothing.
Mail: Back ⇧⌘[, Forward ⇧⌘], Filter ▸ Enable Message Filter ⌘L, …

## Fix idea
Move the history (`back`/`forward`) into a focused value or the store and add View ▸ Back/Forward with `.keyboardShortcut("[", modifiers: [.command, .shift])` / `"]"`; wrap the filter toggle in `Menu("Filter")`.
