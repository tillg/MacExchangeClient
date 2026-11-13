---
title: 'Message header: the date breaks onto two lines in a narrow message pane'
priority: P4
area: UI / MessageDetailView
status: open
found: 2026-11-13
---
Draft id: R5E-03 (probe suites `Probe_R5*` in `probes/Probe_R5*Tests.swift`).

## Summary
At the minimum window width (900 pt), the message pane is about 320 pt wide. The header's first line (sender, paperclip with count, date) has no room, and the date wraps: "13. Nov 2026 at" / "13:04", overlapping the subject line's height. The sender name and date compete with no truncation rule.

## Expected
The date stays on one line (it is the fixed-size part; the sender name truncates first), as in Mail's header. Plain layout correctness.

## Repro
No probe: UI only. Snapshot (fresh snapshot defaults, so the split widths aren't remembered):
```sh
defaults delete MailReplicaSnapshot; tools/snapshot.sh $PWD/tmp/e03.png MAIL_SNAPSHOT_SIZE=900x500
```
PNG: `specs/bugs/png/BUG-180-header-date-wraps.png`.

## Failure output
Header shows "Priya Raman  📎1  13. Nov 2026 at" with "13:04" on a second line.

## Fix idea
`MessageHeader`: `.lineLimit(1).fixedSize()` on the date (and attachment button), `.lineLimit(1)` + truncation on the sender name.
