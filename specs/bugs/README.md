# Bug list

Found 2026-11-12 by probe tests. Each bug file has its repro test and the failure output. All probes are in `probes/`. To run them, copy them into `Tests/MailModelTests/` and run with `--filter Probe_`. Each bug cites at least one failing probe; a few passing probes are controls. They stay out of the main suite.

Limits: results are store-level only, and the app wasn't run. Mail.app expectations marked ⚠️ are recalled, not checked. Some EWS items use response shapes not confirmed on the live server. Sync with the server is untested: there is no backend double and mocks aren't allowed.

| # | Priority | Area | Title |
|---|---|---|---|
| [029](BUG-029-reply-to-own-sent-message-addresses-self.md) | P3 | MailStore | Reply to a message in Sent addresses the reply to myself |
| [030](BUG-030-local-save-draft-drops-cc.md) | P3 | MailStore | Save Draft without a server loses the Cc recipients |
| [031](BUG-031-search-failed-notice-never-cleared.md) | P3 | MailStore | "Search failed: …" stays under the window title after the search is cleared or succeeds |
| [032](BUG-032-half-proposal-silently-dropped.md) | P3 | MailStore | A proposed new time with only a start (or only an end) is accepted, then silently sent as a plain answer |
| [033](BUG-033-nul-character-truncates-text-and-breaks-search.md) | P4 | MailDatabase | Text with a NUL character is cut off when stored, and a search containing NUL throws |
| [034](BUG-034-separator-characters-corrupt-contacts-and-attachments.md) | P4 | MailDatabase | Names containing U+001E/U+001F corrupt the stored To/Cc and attachment lists |
| [035](BUG-035-plaintext-fallback-rough.md) | P4 | EWS | Plain-text fallback of HTML mail: entities left raw, words run together, comment tails leak, slow on unclosed <style> |
| [036](BUG-036-empty-textbody-hides-html-text.md) | P4 | EWS | An empty `<t:TextBody/>` next to an HTML body gives the message empty text |
| [037](BUG-037-folder-tree-duplicates-repeated-folders.md) | P4 | EWS | A folder returned twice by FindFolder paging appears twice in the sidebar |
| [038](BUG-038-parse-invite-ignores-item-type.md) | P4 | EWS | parseBody builds an invite for any item with Start/End (e.g. a MeetingResponse), while message() limits invites to requests/cancellations |
| [039](BUG-039-hasremotecontent-import-false-positive.md) | P4 | HTMLPage | Any text mentioning "@import" shows the Load Remote Content banner |
| [040](BUG-040-cid-regex-matches-inside-words.md) | P4 | HTMLPage | cid: references are found inside ordinary words ("acid:rain", "Lucid:dreams") |
| [041](BUG-041-cid-unquoted-self-closing-keeps-slash.md) | P4 | HTMLPage | Unquoted cid: in a self-closing tag gets a trailing "/" in its ID, so the image never shows |
| [042](BUG-042-cid-html-entities-not-decoded.md) | P4 | HTMLPage | cid: references with &amp; (or other entities) are not decoded, so the image is not found |
| [043](BUG-043-unresolved-uppercase-cid-image-not-hidden.md) | P4 | HTMLPage | Unresolved CID: (uppercase scheme) images are not hidden when remote content is allowed |
| [044](BUG-044-initials-only-split-on-ascii-space.md) | P4 | Models | Contact.initials ignores names separated by tab or no-break space |
| [045](BUG-045-initials-can-be-three-letters.md) | P4 | Models | Contact.initials can return 3+ letters (ß, ǆ, ﬀ expand when uppercased) |
| [046](BUG-046-preview-keeps-whitespace-only-lines.md) | P4 | Models | Message.preview keeps whitespace-only lines and tabs, leaving gaps in the list preview |
| [047](BUG-047-action-that-changes-nothing-moves-selection.md) | P4 | MailStore | Archive while viewing Archive changes nothing but moves the selection to the next message |
| [048](BUG-048-drop-reports-success-when-nothing-changed.md) | P4 | MailStore | drop() returns true for an already-flagged Trash message dropped on Flagged, although nothing changed |
| [049](BUG-049-local-send-empty-subject-inconsistent.md) | P4 | MailStore | Sending without a server stores an empty subject; Drafts and failed sends use "(No Subject)" |
| [050](BUG-050-reply-all-trailing-comma-for-addressless-recipient.md) | P4 | MailStore | Reply All leaves a trailing ", " (empty recipient) when the original lists a recipient without address |
| [051](BUG-051-symlink-to-folder-cannot-be-attached.md) | P4 | MailStore | Attaching a symbolic link to a folder fails with "Couldn't attach" instead of zipping the folder |
| [052](BUG-052-memory-search-fallback-ignores-readme-rules.md) | P3 | MailStore | In-memory fallback search ignores the README matching rules (To/Cc/preview, every word, accents) |
| [053](BUG-053-upgrade-resync-keeps-mail-deleted-on-server.md) | P2 | MailDatabase | The from-scratch re-sync after the conversation upgrade never removes mail deleted or moved on the server since the last session (ghost messages forever) |
| [054](BUG-054-invalid-sync-state-never-reset.md) | P2 | EWS | A SyncState Exchange rejects (ErrorInvalidSyncStateData) is kept: every later check of that folder fails the same way |
| [055](BUG-055-failed-send-draft-loses-attachment-content-after-relaunch.md) | P2 | MailStore | A message that failed to send is kept "in Drafts on this Mac", but after a relaunch its attached files can no longer be opened |
| [056](BUG-056-sign-in-removes-exchange-account-without-password.md) | P2 | MailStore | Signing in (e.g. to re-enter a missing password) removes an Exchange account that has no Keychain password; its mail stays in All Inboxes without an account |
| [057](BUG-057-summary-sync-wipes-loaded-addresses.md) | P2 | MailStore | A later list summary of an opened message replaces its sender/recipient addresses with names only (Reply/Reply All go to empty addresses) and brings back the paperclip |
| [058](BUG-058-imported-cache-never-learns-conversations.md) | P3 | MailDatabase | Mail imported from Cache.json keeps the cache's sync positions, so it never learns its conversation |
| [059](BUG-059-one-missing-item-fails-whole-batch.md) | P3 | EWS | One item gone on the server makes a whole batch (read, flag, move, delete) fail: the other items changed on Exchange but are undone here, moved ones lose their new IDs |
| [060](BUG-060-response-without-result-taken-as-success.md) | P3 | EWS | A response without any EWS result (empty SOAP body, a well-formed proxy/error page) counts as success: Send reports nothing, a sync "completes" with an empty token |
| [061](BUG-061-transient-server-errors-undo-changes.md) | P3 | MailStore | Throttling (ErrorServerBusy) or a 503 page undoes the user's change as "Exchange refused a change" instead of keeping it queued |
| [062](BUG-062-archive-role-given-to-nested-or-deleted-folder.md) | P3 | EWS | Without a top-level Archive, any folder named "Archive" becomes the Archive mailbox, even one inside Deleted Items or deep in Inbox |
| [063](BUG-063-inline-flagged-attachment-without-reference-invisible.md) | P3 | EWS | An attachment Exchange flags IsInline that the body doesn't show (text mail, no cid: reference) is neither listed nor shown: it can't be seen or saved |
| [064](BUG-064-stray-closing-div-cuts-off-html-mail.md) | P3 | HTMLPage | A stray </div> in an HTML mail closes the measured wrapper, so the rest of the message is cut off |
| [065](BUG-065-sender-body-bgcolor-and-text-overridden.md) | P3 | HTMLPage | The sender's <body bgcolor>/text colours are overridden by our white page, so light text on a dark mail becomes invisible |
| [066](BUG-066-quirks-mode-table-text-16px.md) | P3 | HTMLPage | Every HTML mail renders in quirks mode, so text in tables is 16 px instead of Mail's 14 px default |
| [067](BUG-067-slash-o-local-part-counts-as-organisation.md) | P3 | HTMLPage | An outside sender whose address starts with "/o=" counts as "my organisation", so remote images load and tell the sender the mail was opened |
| [068](BUG-068-reply-forward-of-unopened-exchange-message-uses-summary.md) | P3 | MailStore | Reply / Reply All / Forward on an Exchange message that hasn't been opened yet: empty To, 'Ann Lee <>' attribution, nothing quoted, wrong When-Adding-Recipients answer |
| [069](BUG-069-invite-answer-for-vanished-invite-silently-dropped.md) | P3 | Invite | Respond with Comments: if the invite is gone by the time you press Send, the answer and comment vanish without a word |
| [070](BUG-070-draft-of-removed-account-sent-from-another-account.md) | P3 | MailStore | A message written for an account that no longer exists is silently sent (or saved) from the first other account |
| [071](BUG-071-forward-released-without-original-files.md) | P3 | MailStore | A forward whose original files can't be fetched becomes sendable without them, with no message at all when the body couldn't be loaded |
| [072](BUG-072-erased-message-resurrected-by-sync.md) | P3 | MailStore | A message erased from Trash comes back when a Trash page or the newest lookup lists it before the queued delete reached the server |
| [073](BUG-073-rename-after-move-duplicates-message.md) | P3 | MailStore | A moved message appears twice when the destination sync brings its new ID before the move's answer renames it |
| [074](BUG-074-deletion-during-pending-move-forgotten.md) | P3 | MailStore | A server deletion that arrives while a move is queued is ignored for good; when the move then fails the message stays as a ghost |
| [075](BUG-075-pending-change-swallows-unrelated-server-changes.md) | P3 | MailStore | A queued change of one property throws away the server's changes to the other properties of that message (flag, read state) |
| [076](BUG-076-launch-quick-check-duplicates-offline-move.md) | P3 | MailStore | At launch, the Inbox check duplicates a message that was moved offline last session (its queued move is restored, the message is not in memory yet) |
| [077](BUG-077-removed-server-folder-mail-lingers.md) | P3 | MailStore | Mail of a folder removed on the server stays: shown in Flagged and search, and a selected removed folder has a blank title |
| [078](BUG-078-refused-batch-undo-freezes-ui.md) | P3 | MailStore | Undoing a refused batch of 100 changes takes about 1 s on a 70k-message account (main thread) |
| [079](BUG-079-mail-of-account-no-longer-set-up-loaded-at-launch.md) | P4 | MailStore | Stored mail of an account that is no longer set up is loaded at launch and shows in All Inboxes and search (its rows are never removed) |
| [080](BUG-080-switching-account-scope-flashes-no-results.md) | P4 | MailStore | Switching from one account's mailbox to another's during a search shows an empty list (No Results) until the new answer arrives |
| [081](BUG-081-cjk-words-inside-sentence-not-found.md) | P4 | MailDatabase | Index search can't find a Chinese or Japanese word inside a sentence (the old search could) |
| [082](BUG-082-greek-accents-not-ignored.md) | P4 | MailDatabase | Search doesn't ignore Greek accents: "καλημερα" doesn't find "Καλημέρα" |
| [083](BUG-083-import-fails-after-database-is-in-place-when-imported-cache-exists.md) | P4 | MailDatabase | Import from Cache.json reports failure after the database is already in place when Cache.json.imported exists; the session then saves nothing |
| [084](BUG-084-ipf-note-subclass-folders-hidden.md) | P4 | EWS | Mail folders whose class is a subclass of IPF.Note (e.g. IPF.Note.OutlookHomepage) are left out of the folder tree |
| [085](BUG-085-embedded-data-fonts-blocked.md) | P4 | HTMLPage | Fonts embedded in the mail (data: URIs) are blocked unless remote content is allowed |
| [086](BUG-086-daylayout-zero-length-events-drawn-on-top.md) | P4 | Invite | Day column: zero-length (or end-before-start) events take no room, so they are drawn on top of the event starting at the same time |
| [087](BUG-087-save-attachment-fails-next-to-dangling-symlink.md) | P4 | MailStore | Saving an attachment fails when a broken alias/symlink with the same name is in the target folder |
| [088](BUG-088-sign-in-resets-mailbox-and-selection.md) | P4 | MailStore | Signing in another account always jumps to All Inboxes and clears the selection, even when no sample account was removed |
| [089](BUG-089-failed-send-status-wording.md) | P4 | MailStore | After a failed Save Draft the status says "Couldn't send …"; with no subject it reads "Couldn't send “”" |
| [090](BUG-090-failed-send-draft-loses-picture-placement.md) | P4 | MailStore | The draft kept after a failed send loses where the pictures were placed in the text |
| [091](BUG-091-moving-placed-picture-not-a-change.md) | P4 | Models | Moving a picture to another place in the text doesn't count as a change, so closing the window discards it without asking |
| [092](BUG-092-refresh-before-restore-duplicates-inbox.md) | P4 | MailStore | A refresh that runs before launch has restored the stored Inbox duplicates Inbox messages |
| [093](BUG-093-server-deletion-keeps-queued-changes.md) | P4 | MailStore | Changes queued for a message that the server reports deleted stay in the outbox and are sent anyway |
