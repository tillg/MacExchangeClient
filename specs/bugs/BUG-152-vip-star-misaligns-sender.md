---
title: 'VIP star sits in the sender line, pushing the name out of line with subject and preview (and next to the unread dot)'
priority: P4
area: MessageList
status: open
found: 2026-11-13
---
## Summary
In a list row, the VIP star is put inside the sender's HStack. The sender's name then starts about 17 pt further right than the subject and preview below it. On an unread VIP mail, the dot and the star sit side by side. Mail draws the VIP star in the leading status column (where the unread dot goes), keeping the name aligned.

## Repro
Unmodified sample data: `snap.sh base.png MAIL_SNAPSHOT_SIZE=1280x800` (Priya Raman "Q4 roadmap review", Mom "Photos from the weekend"). Unread variant: any snapshot where that row isn't selected (for example the "Stress long" snapshot).

## Expected vs actual
- Bug: png/R4-UI-07-vip-unread-row-bug.png: unread VIP row with dot, then star, then "Priya Raman" indented relative to "Q4 roadmap review".
- Bug and control: png/R4-UI-07-vip-read-and-plain-rows.png: the read VIP row (name indented) above a plain row from the same sender (name aligned with the subject).
Expected: the sender's name left-aligned with the subject in every row, with the star in the dot column.

## Why expected
README list row: "Unread dot, bold sender, …" (⚠️ drawn in code). This is an alignment defect within our own layout: every other row aligns sender, subject and preview.

## Likely cause
Sources/MailReplica/MessageListView.swift:110-121: `Image("star.fill")` is inside the sender `HStack` instead of the leading 8 pt dot column.
