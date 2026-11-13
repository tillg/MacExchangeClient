---
title: 'With 7 or more accounts the app crashes building the Mailbox menu (⌘10 shortcut)'
priority: P2
area: UI / MailCommands
status: open
found: 2026-11-13
---
Draft id: R5E-06 (probe suites `Probe_R5*` in `probes/Probe_R5*Tests.swift`).

## Summary
The Mailbox menu gives every favourite a shortcut `KeyEquivalent(Character("\(i + 1)"))`. Favourites are All Inboxes, VIPs, Flagged plus one Inbox per account, so with 7 accounts the 10th item asks for `Character("10")`, which traps: "Can't form a Character from a String containing more than one extended grapheme cluster". The menu is built at launch and whenever the store changes, so the app crashes on adding the 7th account and on every launch after.

## Expected
No crash (plain correctness). Only ⌘1…⌘9 exist; items after the 9th get no shortcut.

## Repro
No probe: UI only (`MailCommands` is in the app target; adding 7 accounts isn't possible in the snapshot hook). The trap itself, with the same expression:
```sh
printf 'let i = 9\nlet c = Character("\\(i + 1)")\nprint(c)\n' > t.swift && swift t.swift
```
Code: `Sources/MailReplica/MailCommands.swift`, `ForEach(Array(favorites.enumerated()) …) .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")))`.

## Failure output
```
Swift/Character.swift:177: Fatal error: Can't form a Character from a String containing more than one extended grapheme cluster
```

## Fix idea
Only add the shortcut for `i < 9` (e.g. `.keyboardShortcut(i < 9 ? KeyEquivalent(Character(String(i + 1))) : nil)` via a conditional modifier), or limit the shortcut list to the first nine.
