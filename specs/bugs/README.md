# Bug list

Found 2026-11-12 by probe tests. Each bug file has its repro test and the failure output. All probes are in `probes/`. To run them, copy them into `Tests/MailModelTests/` and run with `--filter Probe_`. Each bug cites at least one failing probe; a few passing probes are controls. They stay out of the main suite.

Limits: results are store-level only, and the app wasn't run. Mail.app expectations marked ⚠️ are recalled, not checked. Some EWS items use response shapes not confirmed on the live server. Sync with the server is untested: there is no backend double and mocks aren't allowed.

| # | Priority | Area | Title |
|---|---|---|---|
| [084](BUG-084-ipf-note-subclass-folders-hidden.md) | P4 | EWS | Mail folders whose class is a subclass of IPF.Note (e.g. IPF.Note.OutlookHomepage) are left out of the folder tree |
| [104](BUG-104-answered-invite-shows-unanswered-after-sync.md) | P3 | Invite | An invite answered here shows "Please respond" again once Exchange has moved it to Deleted Items |
| [125](BUG-125-mailbox-selected-during-check-not-checked.md) | P4 | MailStore | Selecting a mailbox while a check is running doesn't check it (README: "at once when you select a mailbox") |
| [126](BUG-126-paging-never-ends-when-server-repeats-page.md) | P4 | MailStore | Quick check and history page forever when the server answers "more" with the same SyncState |
| [146](BUG-146-memory-search-per-keystroke-freeze.md) | P4 | MailStore | Search without the index (index build failed or still building, or "Search failed") freezes 0.6-1 s per keystroke on 180,000 messages |
