---
title: 'README ✅ says list rows use 13 pt / 11 pt; subject, preview and date render at 12 pt'
priority: P4
area: MessageList
status: open
found: 2026-11-13
---
## Summary
The README's "How faithful" table marks "✅ fonts 13pt / 11pt" for the list row. The row never had an 11 pt font (also at the commit that wrote this README line, 8b5c8aa): the sender is 13 pt and the subject, preview and date are 12 pt. Either the code or the ✅ claim is wrong.

## Repro
Unmodified sample data: `snap.sh base.png MAIL_SNAPSHOT_SIZE=1280x800`. Ink heights were measured with PIL on the 2× PNG.

## Expected vs actual
- png/R4-UI-08-row-13-12pt.png ("Priya Raman / Q4 numbers review" row): sender 25 px, subject "Q4 numbers review" 20 px, preview lines (with descenders) 22 px.
- Control, 12 pt: header "To: Alex Morgan" (12 pt, with a descender) = 22 px, the same as the preview.
- Control, 11 pt: png/R4-UI-08-attachment-label-11pt-control.png, attachment label (11 pt) "Q4-" = 18 px and "Roadmap.pdf" = 21 px. The subject's "Q4" is 20 px (ratio 1.11 ≈ 12/11).
So the rows render at 13/12, not 13/11.

## Why expected
README ✅ line: "List row | … | ⚠️ drawn in code · ✅ fonts 13pt / 11pt".

## Likely cause
Sources/MailReplica/MessageListView.swift:123,126,135 use `.system(size: 12)` for the date, subject and preview. Fix either those or the README's claim.
