---
title: 'Include-attachments Ask dialog adds a "?" to Mail''s title and spells "Don''t Include" with a straight apostrophe'
priority: P4
area: UI / ComposeView
status: open
found: 2026-11-13
---
Draft id: R5N-07 (probe suites `Probe_R5*` in `probes/Probe_R5*Tests.swift`).

## Summary
With Include Attachments With Replies set to Ask, a reply asks "Include Attachments From Original Message?" with buttons Include / Don't Include. Mail's strings have no question mark and use a typographic apostrophe: "Include Attachments From Original Message", "Don’t Include". The README marks the Ask dialog's wording ⚠️ (estimated); the bundle has the actual strings.

## Expected
Mail.app `Compose.loctable` en: `IncludeAttachmentsFromOriginalMessage` "Include Attachments From Original Message", `IncludeAttachmentFromOriginalMessage` "Include Attachment From Original Message", `Include` "Include", `DoNotInclude` "Don’t Include" (U+2019). The app already uses U+2019 for Mail's "Don’t Save" (`ComposeView.swift:235`).

## Repro
No probe (view layer). Evidence: code + bundle.
- `Sources/MailReplica/ComposeView.swift:82` `.alert(originalCount == 1 ? "Include Attachment From Original Message?" : "Include Attachments From Original Message?", …)`
- `ComposeView.swift:85` `Button("Don't Include", role: .cancel)`

## Failure output
Title "Include Attachments From Original Message?"; button "Don't Include". Mail: "Include Attachments From Original Message"; "Don’t Include".

## Fix idea
Drop the "?" and write "Don’t Include"; update the README row (⚠️ → ✅ `Compose.loctable`).
