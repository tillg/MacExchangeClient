---
title: 'Answered invite: the chosen answer button isn''t highlighted (the tint has no effect)'
priority: P4
area: Invite
status: open
found: 2026-11-13
---
## Summary
`InviteCard.answer` tints the button of the given answer (`.tint(invite.response == r ? .accentColor : nil)`). On macOS a `.bordered` small menu button ignores `tint`, so after you answer, Accept, Tentative and Decline look exactly as before. Only the banner text says what you chose.

## Repro
Harness: copy built with `./run.sh build`, stress messages added to `Sources/MailReplica/SampleData.swift` (see `stress-SampleData.diff` in this folder), run via `snap.sh` (binary copied to `MailReplicaProbe` so it reads its own defaults domain, `MAIL_SAMPLE_DATA=1`; no Mail.sqlite, no Exchange).
Invite "Stress answered" with `response = .tentative` and a reply. `snap.sh out.png MAIL_SNAPSHOT_SIZE=1280x800 "MAIL_SNAPSHOT_SUBJECT=Stress answered"`, then compare with "Stress all day" (unanswered).

## Expected vs actual
- Bug: png/R4-UI-06-answered-tentative-bug.png: Tentative looks identical to Accept and Decline, although the banner says "You answered: Tentative".
- Control: png/R4-UI-06-unanswered-control.png: the unanswered invite. Its buttons are pixel-for-pixel the same.
Expected: the chosen answer stands out, as the code intends (and as Outlook marks the given response).

## Why expected
The code's own intent, at InviteView.swift:97.

## Likely cause
Sources/MailReplica/InviteView.swift:88-98 together with 46-48 (`.menuStyle(.button)`, `.buttonStyle(.bordered)`): tint isn't drawn for bordered menus. A prominent style (`.borderedProminent`) or an explicit background or checkmark for the chosen one would show it.
