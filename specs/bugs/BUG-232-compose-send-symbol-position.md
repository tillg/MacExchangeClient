---
title: 'Compose toolbar: Send is a paper plane at the leading edge; Mail''s Send is arrow.up at the trailing edge'
priority: P4
area: UI / ComposeView
status: open
found: 2026-11-13
---
Draft id: R5N-06 (probe suites `Probe_R5*` in `probes/Probe_R5*Tests.swift`).

## Summary
The compose window's Send button uses the SF Symbol `paperplane` and sits first, at the toolbar's leading edge (`.navigation`). Mail's compose toolbar has Send last, after a flexible space, with the symbol `arrow.up`. The Attach and Include Attachments items next to it are copied from the same file (README ✅ `ComposeWindow.toolbar`); no ✅ row names the Send symbol itself, but the README says the window uses "Mail's toolbar layout and SF Symbols".

## Expected
Mail.app `ComposeWindow.toolbar`: `"default set" = (NSToolbarFlexibleSpaceItem, "changeReplyMode:", …, "insertAttachment:", "sendLater:", NSToolbarFlexibleSpaceItem, "send:")`; item `send:`: `image = arrow.up`, `title = ToolbarSend` ("Send"), `help = ToolTipSend` ("Send message").

## Repro
No probe (view layer). Evidence: code + bundle.
- `Sources/MailReplica/ComposeView.swift:100-101` `ToolbarItem(placement: .navigation) { Button { send() } label: { Label("Send", systemImage: "paperplane") }`

## Failure output
Send drawn as a paper plane, before Attach; Mail: ↑ at the far right, after Attach.

## Fix idea
`systemImage: "arrow.up"` and move the item last with default (trailing) placement, after Save Draft.
