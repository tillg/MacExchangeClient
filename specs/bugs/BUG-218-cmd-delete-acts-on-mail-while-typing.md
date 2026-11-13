---
title: "⌘⌫ while typing in a compose window (or the search field) deletes the main window's selected message, and erases it if it is in Trash"
priority: P1
area: MailCommands
status: open
found: 2026-11-13
---
Draft id: R5F-01 (probe suites `Probe_R5*` in `probes/Probe_R5*Tests.swift`).

## Summary
Message ▸ Delete has ⌘⌫ and always runs `store.deleteSelection()` on the main window's selection, whatever has the keyboard focus. ⌘⌫ is also the text system's "delete to the start of the line". Pressing it in the search field, or in the text of a compose window, doesn't edit the text: the menu takes the key first and moves the selected message to Trash. If that message is in Trash, it is erased (removed here, `DeleteItem` queued for Exchange), without the user ever looking at the list.

## Expected
In Mail's MainMenu.nib, Delete (⌘⌫, `NSKeyEquiv='\x08'` Command, `Mail.menuBar.editMenu.delete`) is wired with an `NSNibControlConnector` to `deleteMessages:` and no destination: a first-responder action. It goes up the key window's responder chain, so with a compose window in front it never reaches the viewer's messages. Plain correctness: a text-editing key in another window must not erase mail (data loss). The search-field case (same window as the list) is ⚠️: the chain there does reach the viewer, and how Mail validates it wasn't checked.

## Repro
Evidence: view harness (real views and `MailCommands` from `Sources/MailReplica`, sample data only, own binary name and defaults domain; no account, no disk, no network). The app started from a shell can't become active, so the harness hands the key event, built from key code 51 with Command (the system fills in U+007F), to the window first and then to the menu bar, which is `NSApp.sendEvent`'s order for key equivalents. Before the key it calls each menu's `menuNeedsUpdate` (as when a menu tracks), so SwiftUI brings the items' enabled state up to date.
```
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk swift build --package-path W --scratch-path W/.build -c debug --product MailReplica
specs/bugs/probes-views/run-harness.sh build
specs/bugs/probes-views/run-harness.sh delete-in-search
R5F_TRASH=1 specs/bugs/probes-views/run-harness.sh delete-in-compose   # the message is first moved to Trash and selected there
specs/bugs/probes-views/run-harness.sh delete-in-list     # control: list focused, ⌘⌫ moves to Trash as it should
```

## Failure output
```
R5F first responder: SearchTextView, search text "hello world"
R5F key event from key code 51: characters ["7f"], ignoring modifiers ["7f"]
R5F key handled by the menu bar
R5F FAIL: expected ⌘⌫ in the search field to edit the field and leave "Q4 roadmap review – agenda" in inbox, got it in trash

R5F compose key: nil, first responder DropTextView
R5F before: compose text "Hello", selected "Q4 roadmap review – agenda" in trash
R5F key handled by the menu bar
R5F FAIL: expected ⌘⌫ in the compose text to delete text before the insertion point and leave "Q4 roadmap review – agenda" in trash, got text "Hello" and the message gone (erased)
```

## Fix idea
`MailCommands.swift:84-85`: don't act when a text view is first responder (`NSApp.keyWindow?.firstResponder is NSText`), or only when the key window is a viewer window and its list has focus (e.g. a `@FocusedValue` set by `MessageListView`). Same for the other Message commands that take the store's selection from any window.
