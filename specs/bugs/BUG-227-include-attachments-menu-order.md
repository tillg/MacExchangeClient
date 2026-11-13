---
title: 'Edit ▸ Include Attachments With Replies lists Never, Ask, When Adding Recipients, Always; Mail lists Always, Never, When Adding Recipients, Ask'
priority: P4
area: MailModel / IncludeAttachments, MailCommands
status: open
found: 2026-11-13
---
Draft id: R5N-01 (probe suites `Probe_R5*` in `probes/Probe_R5*Tests.swift`).

## Summary
The submenu Edit ▸ Include Attachments With Replies shows its four choices in a different order from Mail. The README says the menu is read from `MainMenu.nib` (✅).

## Expected
Mail.app `Base.lproj/MainMenu.nib`, menu "Include Attachments With Replies" (NSMenu #2124, ids `Mail.menuBar.editMenu.includeAttachmentsWithReplies.*`): Always, Never, When Adding Recipients, Ask. The item tags agree: always 96, never 97, whenAddingRecipients 98, ask 99. README "How faithful is it?", row "Replies and size": Include Attachments With Replies ✅ `MainMenu.nib`.

## Repro
`Probe_R5NFidelityTests/includeAttachmentsMenuOrderMatchesMainMenuNib` in `Tests/MailModelTests/Probe_R5NTests.swift`.
```
swift test --package-path W --scratch-path W/.build/tests --skip-build --filter Probe_R5N
```

## Failure output
```
Expectation failed: IncludeAttachments.allCases.map(\.title) == nib
  IncludeAttachments.allCases.map(\.title) → ["Never", "Ask", "When Adding Recipients", "Always"]
  nib → ["Always", "Never", "When Adding Recipients", "Ask"]
```

## Fix idea
Reorder the cases in `Models.swift` `enum IncludeAttachments` to `always, never, whenAddingRecipients, ask` (raw values are stored in defaults, so the order change is safe). `MailCommands.swift:36` iterates `allCases`.
