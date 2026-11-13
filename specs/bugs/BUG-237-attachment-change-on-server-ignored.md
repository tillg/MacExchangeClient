---
title: "A file added to or removed from a message on the server (a draft edited in Outlook) never shows: the old attachment list and paperclip stay"
priority: P3
area: Sync / attachments
status: deferred
found: 2026-11-13
---

## Summary
When a later summary arrives for a message whose body is loaded, `merge` keeps the body, attachment list and `hasAttachments` unless the people or the preview changed (BUG-057 fix). Adding a file to a draft in Outlook/OWA (or removing one) changes only `HasAttachments`: the text and preview stay the same. So the old list stays for good: no paperclip and no file for an added attachment; a removed one stays listed and fails to open ("no longer on the server"); a replaced one is fetched by position, so the name shown can open another file.

## Expected
Plain correctness (wrong data shown after sync). merge's own comment: when "the message changed on the server (a draft edited elsewhere)… its body is fetched again when shown"; the summary's `HasAttachments` (ews.md summary fields) says it changed.

## Repro
Probe `Probe_R5K_Attachments/attachmentChangeOnServerRefreshesTheList` in `Tests/MailModelTests/Probe_R5KTests.swift`:
```sh
swift test --package-path . --scratch-path .build/tests --skip-build --filter Probe_R5K_Attachments/attachmentChangeOnServerRefreshesTheList
```

## Failure output
```
Expectation failed: m?.hasAttachments == true || m?.needsBody == true
  hasAttachments Optional(false), needsBody Optional(false)
```

## Fix idea
In `MailStore.merge`, keep the loaded body only when `m.hasAttachments == old.hasAttachments` too (better: compare the server's ChangeKey, which every edit changes).

## Deferred (2026-11-13)
Comparing the summary's HasAttachments with the loaded body's list isn't safe: the summary counts inline pictures
(signature logos), the body's list leaves them out, so every sync would mark such mail for a refetch. The right signal
is the item's ChangeKey (every edit changes it), which the store doesn't keep yet: a model and storage change. See
DECISIONS.md run-2026-11-13-1235-12.
