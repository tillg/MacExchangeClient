---
title: "⚠️ \"[cid:image001.png@01D…]\" from Exchange's text version shows in the list preview and is quoted in replies"
priority: P3
area: ews body / preview / compose
status: deferred
found: 2026-11-13
---

## Summary
For HTML mail the text comes from Exchange's `TextBody`. Exchange's HTML-to-text conversion writes each inline picture (signature logos, pasted screenshots) as "[cid:image001.png@01DA…]". The app takes that text as is: the list preview of a mail with a signature logo starts "[cid:image001.png@01DA1B2C.3D4E5F60] Hi Ann Regards", search indexes it, and Reply quotes "> [cid:image001.png@01DA1B2C.3D4E5F60]". ⚠️ The placeholder shape is recalled from Exchange/Outlook plain-text conversions, not captured from the live server here.

## Expected
Plain correctness: a content-ID reference is not text the sender wrote; the inline picture is shown in place in the HTML view, and Mail's list shows text only. P3 because it would hit every Outlook mail with a logo, but ⚠️ unconfirmed.

## Repro
Probe `Probe_R5I_EWS/cidPlaceholdersOfTextBodyAreNotShownOrQuoted` in `Tests/MailModelTests/Probe_R5ITests.swift`:

```sh
swift test --package-path . --scratch-path .build/tests --skip-build --filter Probe_R5I_EWS/cidPlaceholdersOfTextBodyAreNotShownOrQuoted
```
(after the test build from CLAUDE.md)

## Failure output
```
Expectation failed: !loaded.preview.contains("[cid:")
  preview: [cid:image001.png@01DA1B2C.3D4E5F60] Hi Ann Regards
Expectation failed: !quote.contains("[cid:")
  > [cid:image001.png@01DA1B2C.3D4E5F60]
```

## Fix idea
In `EWSBackend.parseBody`, drop `[cid:…]` tokens from `TextBody` whose ID is one of the message's attachments' `ContentId` (then drop lines left empty).

## Deferred (2026-11-13)
rests on ⚠️ (whether Exchange writes "[cid:…]" into its text version); needs a look at real mail first. See DECISIONS.md run-2026-11-13-1235-12.
