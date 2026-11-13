---
title: "A forward whose original is gone while its files load is released without them, without a word"
priority: P3
area: compose / forward
status: open
found: 2026-11-13
---

## Summary
`includeOriginalAttachments` starts with `guard let id = draft.loadingOriginal, let m = message(id) else { draft.loadingOriginal = nil; return }`. If the original is no longer in memory when the files are fetched (deleted on the server and synced away while the forward opens, erased from Trash right after pressing Forward, or gone by the time the user clicks Try Again), `loadingOriginal` is cleared, Send is enabled, no status is set and the window never shows "The original attachments couldn't be added." The forward goes out without its files.

## Expected
README: "A forward can't be sent until the original's files have loaded; if they can't be, the window says so and offers Try Again or Continue Without Them." d-bug-071: all or none, a failure keeps it blocked, the user decides, "not a silent fallback".

## Repro
Probe `Probe_R5K_Attachments/forwardOfVanishedOriginalDoesNotSilentlyDropFiles` in `Tests/MailModelTests/Probe_R5KTests.swift`:
```sh
swift test --package-path . --scratch-path .build/tests --skip-build --filter Probe_R5K_Attachments/forwardOfVanishedOriginalDoesNotSilentlyDropFiles
```

## Failure output
```
Expectation failed: d.loadingOriginal != nil || !d.attachments.isEmpty
  forward can be sent without its files; status: nil
```

## Fix idea
In `MailStore.includeOriginalAttachments`, treat a missing original like one that can't be loaded: keep `loadingOriginal` and set the status ("the original message is no longer available").
