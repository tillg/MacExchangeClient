---
title: 'Flagged in the sidebar shows no count while flagged messages are read'
priority: P4
area: UI / SidebarView
status: open
found: 2026-11-13
---
Draft id: R5E-08 (probe suites `Probe_R5*` in `probes/Probe_R5*Tests.swift`).

## Summary
Every sidebar row except Drafts, Sent, Trash and Archive shows its unread count. Flagged messages are usually already read, so Flagged shows no badge although it holds messages (sample data: Jonas Weber's red flag and Lufthansa's orange flag, both read: no badge).

## Expected
⚠️ Mail shows the number of flagged messages next to Flagged (recalled from Mail, not read from the bundle; README marks the badge rules ⚠️). Hence P4.

## Repro
No probe: the counts are right (`MailStore.count(.smart(.flagged))` is 2); the view picks the unread one. Snapshot:
```sh
defaults delete MailReplicaSnapshot; tools/snapshot.sh $PWD/tmp/e09.png MAIL_SNAPSHOT_SIZE=1280x800
```
PNG: `specs/bugs/png/BUG-185-flagged-no-badge.png` (crop: `…-crop.png`), list shows two flagged rows.

## Failure output
Flagged row without a badge; two flagged messages in the list.

## Fix idea
`SidebarView.row`: `case .smart(.flagged): store.count(ref)`.
