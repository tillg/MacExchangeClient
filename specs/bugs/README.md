# Bug list

Found 2026-11-12 by probe tests. Each bug file has its repro test and the failure output. All probes are in `probes/`. To run them, copy them into `Tests/MailModelTests/` and run with `--filter Probe_`. Each bug cites at least one failing probe; a few passing probes are controls. They stay out of the main suite.

Limits: results are store-level only, and the app wasn't run. Mail.app expectations marked ⚠️ are recalled, not checked. Some EWS items use response shapes not confirmed on the live server. Sync with the server is untested: there is no backend double and mocks aren't allowed.

| # | Priority | Area | Title |
|---|---|---|---|
| [079](BUG-079-mail-of-account-no-longer-set-up-loaded-at-launch.md) | P4 | MailStore | Stored mail of an account that is no longer set up is loaded at launch and shows in All Inboxes and search (its rows are never removed) |
| [080](BUG-080-switching-account-scope-flashes-no-results.md) | P4 | MailStore | Switching from one account's mailbox to another's during a search shows an empty list (No Results) until the new answer arrives |
| [084](BUG-084-ipf-note-subclass-folders-hidden.md) | P4 | EWS | Mail folders whose class is a subclass of IPF.Note (e.g. IPF.Note.OutlookHomepage) are left out of the folder tree |
| [088](BUG-088-sign-in-resets-mailbox-and-selection.md) | P4 | MailStore | Signing in another account always jumps to All Inboxes and clears the selection, even when no sample account was removed |
| [092](BUG-092-refresh-before-restore-duplicates-inbox.md) | P4 | MailStore | A refresh that runs before launch has restored the stored Inbox duplicates Inbox messages |
| [093](BUG-093-server-deletion-keeps-queued-changes.md) | P4 | MailStore | Changes queued for a message that the server reports deleted stay in the outbox and are sent anyway |
| [104](BUG-104-answered-invite-shows-unanswered-after-sync.md) | P3 | Invite | An invite answered here shows "Please respond" again once Exchange has moved it to Deleted Items |
| [119](BUG-119-mark-read-or-unflag-leaves-hidden-selection.md) | P4 | MailStore | Mark as Read with the unread filter on, or Clear Flag in Flagged, leaves the messages selected after they left the list |
| [120](BUG-120-unchanged-messages-rewritten-on-save.md) | P4 | MailStore | Actions that change nothing still rewrite their rows: Mark All as Read on a read mailbox rewrites every message |
| [121](BUG-121-queued-moves-store-full-message-copies.md) | P4 | MailStore | Queued changes keep a full copy of every message: archiving an opened Inbox makes a 35 MB outbox, rewritten after one more flag |
| [122](BUG-122-mark-all-read-while-loading-misses-later-mail.md) | P4 | MailStore | Mark All as Read while launch is still loading leaves the mail loaded afterwards unread |
| [123](BUG-123-same-time-messages-swap-after-relaunch.md) | P4 | MailStore | Messages with the same time swap places in Flagged (and other mixed lists) after a relaunch |
| [125](BUG-125-mailbox-selected-during-check-not-checked.md) | P4 | MailStore | Selecting a mailbox while a check is running doesn't check it (README: "at once when you select a mailbox") |
| [126](BUG-126-paging-never-ends-when-server-repeats-page.md) | P4 | MailStore | Quick check and history page forever when the server answers "more" with the same SyncState |
| [132](BUG-132-pending-search-shows-mailbox-instead-of-results.md) | P4 | MailStore | While the next search answer is on its way, the list jumps back to the plain mailbox (or "No Results") when the previous results came from memory |
| [138](BUG-138-cancelled-loads-reported-as-errors.md) | P3 | MailStore | Moving on from a message before it has loaded shows "Couldn’t load message: cancelled" (also images, calendar, attachment previews) |
| [142](BUG-142-invite-time-drops-end-date.md) | P3 | Invite | Invite card shows only the start day for a meeting that ends on a later day |
| [143](BUG-143-unloadable-picture-spins-forever.md) | P3 | Attachments | A picture attachment that can't be loaded shows a spinner forever |
| [144](BUG-144-quick-look-shows-another-file.md) | P4 | MailStore | Space on an attachment that cannot be loaded opens Quick Look on a different attachment of the message |
| [146](BUG-146-memory-search-per-keystroke-freeze.md) | P4 | MailStore | Search without the index (index build failed or still building, or "Search failed") freezes 0.6-1 s per keystroke on 180,000 messages |
| [147](BUG-147-late-quick-look-replaces-newer.md) | P4 | MailStore | Quick Look jumps back to an earlier message’s attachment when its download finishes after you looked at another message |
