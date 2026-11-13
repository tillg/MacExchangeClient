---
title: 'Toolbar: View Options shows line.3.horizontal instead of Mail''s ellipsis.circle; the Flag tooltip lacks the colour ("Flag selected messages as Red")'
priority: P4
area: UI / MessageViewer
status: open
found: 2026-11-13
---
Draft id: R5N-05 (probe suites `Probe_R5*` in `probes/Probe_R5*Tests.swift`).

## Summary
- The View Options toolbar menu uses the SF Symbol `line.3.horizontal` (three lines). Mail's item uses `ellipsis.circle` (… in a circle).
- The Flag toolbar button's tooltip is "Flag selected messages"; Mail's says which colour: "Flag selected messages as %@".
(The Junk tooltip is already BUG-182.)

## Expected
Mail.app `MainWindow.toolbar`, item `messageListViewOptionsFromToolbar:`: `image = ellipsis.circle`, `help = ToolTipMessageListViewOptionsMenu` ("View Options"). `Localizable.loctable` en: `SetFlaggedStatusToolTipFormat%1$@` = "Flag selected messages as %1$@". README: Toolbar ✅ "`MainWindow.toolbar` default set and SF Symbol names".

## Repro
No probe (view layer). Evidence: code + bundle.
- `Sources/MailReplica/MessageViewer.swift:136` `Label("View Options", systemImage: "line.3.horizontal")`
- `Sources/MailReplica/MessageViewer.swift:198` `.help("Flag selected messages")`; the button's primary action flags red (`MessageViewer.swift:195`).

## Failure output
View Options button drawn as ≡; Mail draws ⊙…. Flag tooltip "Flag selected messages"; Mail "Flag selected messages as Red".

## Fix idea
`systemImage: "ellipsis.circle"`; `.help("Flag selected messages as Red")` (the colour the primary action sets).
