---
title: "A damaged Mail.sqlite stops all saving for good; it's never set aside"
priority: P3
area: storage
status: open
found: 2026-11-13
---
Draft id: R5C-05 (probe suites `Probe_R5*` in `probes/Probe_R5*Tests.swift`).

## Summary
If `Mail.sqlite` isn't a readable database (damaged by a disk problem or a crash, or overwritten), `MailDatabase(url:)` throws "file is not a database". `AppSetup.loadMail` then shows "Couldn't load mail from disk … Changes aren't saved until relaunch", but every relaunch fails the same way: no mail is ever stored again, every launch downloads everything from the server, and search scans memory. Only deleting the file by hand helps.

## Expected
Plain correctness (the notice promises a relaunch helps). The same situation for `Cache.json` is handled by setting the file aside and starting an empty store that the server refills (DECISIONS #d-bug-009, storage.md "Import from Cache.json" step 2).

## Repro
`Probe_R5CStorage/aDamagedDatabaseFileIsSetAsideAndANewOneCreated`:
`swift test --package-path . --scratch-path .build/tests --skip-build --filter Probe_R5CStorage/aDamagedDatabaseFileIsSetAsideAndANewOneCreated`

## Failure output
```
Issue recorded: damaged database isn't recovered: Mail database: file is not a database
Expectation failed: opened != nil
Expectation failed: !kept.isEmpty
```

## Fix idea
In `MailDatabase.init` (or `AppSetup.loadMail`), on SQLITE_NOTADB/SQLITE_CORRUPT rename `Mail.sqlite` (+ `-wal`, `-shm`) to `Mail.sqlite.unreadable` (`freeName`), create a new database and say so in the status.
