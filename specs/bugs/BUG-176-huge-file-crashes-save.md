---
title: "Saving a draft file or pending send of 2 GB or more crashes the app"
priority: P3
area: storage
status: open
found: 2026-11-13
---
Draft id: R5C-06 (probe suites `Probe_R5*` in `probes/Probe_R5*Tests.swift`).

## Summary
`Statement.bind(_:Data?)` passes `Int32(v.count)` (and text binds `Int32(v.utf8.count)`), which traps for 2 GiB or more. A file that big kept with a draft (a send Exchange refused → `keepInDrafts` → `files` table), or a send waiting in the outbox whose JSON (attachments in base64, 4/3 larger, so from about 1.6 GB of files) passes 2 GiB, crashes the app at the next 15-second save instead of failing it. The crash loses every change since the last save. The compose window lets such a message be sent after the size warning.

## Expected
Plain correctness: no crash; at worst the write fails and "Couldn't save mail: …" is shown (storage.md "Writing": "Any error rolls the batch back").

## Repro
`Probe_R5CStorage/aHugeKeptFileDoesNotCrashTheSave` (exit test: runs the write in a child process):
`swift test --package-path . --scratch-path .build/tests --skip-build --filter Probe_R5CStorage/aHugeKeptFileDoesNotCrashTheSave`

## Failure output
```
Expectation failed: expected exit status ".success", but ".signal(SIGTRAP)" was reported instead
```

## Fix idea
`MailDatabase.swift` `Statement.bind`: use `sqlite3_bind_blob64` / `sqlite3_bind_text64` with `UInt64(count)` (SQLite then returns SQLITE_TOOBIG, which `step` throws). Better still, refuse such files in compose or keep them out of the outbox JSON.
