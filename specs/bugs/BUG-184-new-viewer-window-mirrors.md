---
title: 'File ▸ New Viewer Window opens a second window that always shows the same mailbox and selection as the first'
priority: P3
area: UI / MessageViewer
status: deferred
found: 2026-11-13
---
Draft id: R5E-07 (probe suites `Probe_R5*` in `probes/Probe_R5*Tests.swift`).

## Summary
⌥⌘N opens another "viewer" window, but every viewer binds the sidebar to `store.selectedMailbox` and the list to `store.selection` of the one shared `MailStore`. Picking a mailbox or a message in one window changes the other too; the windows can't show different mailboxes. Each window's sidebar also runs `store.refresh()` on every mailbox change, so one click checks twice. Only back/forward history is per window, and it then records the other window's clicks.

## Expected
⚠️ A second viewer window can show another mailbox and message (Mail's New Viewer Window, `MainMenu.nib`, is an independent viewer; independence recalled from Mail). Plain correctness: a second window that can only mirror the first has no use, and its history is wrong.

## Repro
No probe: UI only (the hook can't open a second viewer). Code: `MailReplicaApp` `WindowGroup("Mail", id: "viewer")` shares `store`; `SidebarView.selection` sets `store.selectedMailbox`; `MessageListView` `List(selection: Bindable(store).listSelection)`; `SidebarView` `.onChange(of: store.selectedMailbox) { Task { await store.refresh() } }` in each window.

## Failure output
Both windows follow each other's mailbox and selection (by construction: one shared `selectedMailbox`/`selection`).

## Fix idea
Keep mailbox and selection per window (`@State`/`@SceneStorage` in `MessageViewer`, passed into list queries), or remove New Viewer Window until that exists.

## Deferred (2026-11-13)
a design choice: should each viewer window have its own mailbox and selection (Mail does)? That moves selection state out of MailStore. See DECISIONS.md run-2026-11-13-1235-12.
