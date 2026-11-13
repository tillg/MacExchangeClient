# Bug list

Found 2026-11-12 by probe tests. Each bug file has its repro test and the failure output. All probes are in `probes/`. To run them, copy them into `Tests/MailModelTests/` and run with `--filter Probe_`. Each bug cites at least one failing probe; a few passing probes are controls. They stay out of the main suite.

Limits: results are store-level only, and the app wasn't run. Mail.app expectations marked ⚠️ are recalled, not checked. Some EWS items use response shapes not confirmed on the live server. Sync with the server is untested: there is no backend double and mocks aren't allowed.

| # | Priority | Area | Title |
|---|---|---|---|
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
| [058](BUG-058-imported-cache-never-learns-conversations.md) | P3 | MailDatabase | Mail imported from Cache.json keeps the cache's sync positions, so it never learns its conversation |
| [068](BUG-068-reply-forward-of-unopened-exchange-message-uses-summary.md) | P3 | MailStore | Reply / Reply All / Forward on an Exchange message that hasn't been opened yet: empty To, 'Ann Lee <>' attribution, nothing quoted, wrong When-Adding-Recipients answer |
| [069](BUG-069-invite-answer-for-vanished-invite-silently-dropped.md) | P3 | Invite | Respond with Comments: if the invite is gone by the time you press Send, the answer and comment vanish without a word |
| [070](BUG-070-draft-of-removed-account-sent-from-another-account.md) | P3 | MailStore | A message written for an account that no longer exists is silently sent (or saved) from the first other account |
| [071](BUG-071-forward-released-without-original-files.md) | P3 | MailStore | A forward whose original files can't be fetched becomes sendable without them, with no message at all when the body couldn't be loaded |
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
| [099](BUG-099-invite-answered-in-multiselection-erased-by-delete.md) | P3 | MailStore | An invite answered while it is part of a multi-selection stays selected in Trash; Delete then erases it |
| [101](BUG-101-send-from-account-without-password.md) | P3 | MailStore | Send from an Exchange account without a Keychain password: shown in Sent though nothing is sent, or queued with no word |
| [102](BUG-102-invite-answer-comment-lost-on-network-error.md) | P3 | MailStore | Respond with Comments that fails with a network error is undone and the typed comment is lost |
| [103](BUG-103-message-changed-on-server-keeps-old-body.md) | P3 | MailStore | A draft changed on the server keeps its old loaded body: new subject, old text and files |
| [104](BUG-104-answered-invite-shows-unanswered-after-sync.md) | P3 | Invite | An invite answered here shows "Please respond" again once Exchange has moved it to Deleted Items |
| [113](BUG-113-combining-character-after-file-mark-breaks-placement.md) | P4 | Models | A combining character right after a placed file breaks the file marks: pictures change place, a stray U+FFFC is sent, Exclude removes the wrong file |
| [114](BUG-114-rtl-lines-sent-left-to-right-in-html.md) | P4 | Models | Hebrew/Arabic lines turn left-to-right (left-aligned, punctuation on the wrong side) once a placed picture makes the mail HTML |
| [115](BUG-115-address-shown-twice-when-no-display-name.md) | P4 | MailStore | Senders without a display name appear as "a@x.com <a@x.com>" in the forward header, the reply attribution and an invite answer's To |
| [116](BUG-116-forward-header-lacks-recipients-and-time-zone.md) | P4 | MailStore | The forward header leaves out To and Cc (and the date has no time zone), so the forward loses who the original went to |
| [117](BUG-117-second-new-message-reuses-window.md) | P4 | Models | A second New Message (or a second Reply to the same message) brings the first compose window forward instead of opening a new one |
| [118](BUG-118-size-estimate-walks-whole-body-each-render.md) | P4 | Models | Message Size: the estimate walks the whole body by character on every render (about 40 ms per keystroke in a 400 KB reply with a file) |
| [119](BUG-119-mark-read-or-unflag-leaves-hidden-selection.md) | P4 | MailStore | Mark as Read with the unread filter on, or Clear Flag in Flagged, leaves the messages selected after they left the list |
| [120](BUG-120-unchanged-messages-rewritten-on-save.md) | P4 | MailStore | Actions that change nothing still rewrite their rows: Mark All as Read on a read mailbox rewrites every message |
| [121](BUG-121-queued-moves-store-full-message-copies.md) | P4 | MailStore | Queued changes keep a full copy of every message: archiving an opened Inbox makes a 35 MB outbox, rewritten after one more flag |
| [122](BUG-122-mark-all-read-while-loading-misses-later-mail.md) | P4 | MailStore | Mark All as Read while launch is still loading leaves the mail loaded afterwards unread |
| [123](BUG-123-same-time-messages-swap-after-relaunch.md) | P4 | MailStore | Messages with the same time swap places in Flagged (and other mixed lists) after a relaunch |
| [124](BUG-124-every-exchange-account-named-exchange.md) | P4 | EWS | Every Exchange account is called "Exchange": two accounts can't be told apart |
| [125](BUG-125-mailbox-selected-during-check-not-checked.md) | P4 | MailStore | Selecting a mailbox while a check is running doesn't check it (README: "at once when you select a mailbox") |
| [126](BUG-126-paging-never-ends-when-server-repeats-page.md) | P4 | MailStore | Quick check and history page forever when the server answers "more" with the same SyncState |
| [127](BUG-127-folder-list-without-inbox-silently-kept.md) | P4 | EWS | If GetFolder answers the standard folders with errors, the check ends silently and the Inbox is not checked again until relaunch |
| [128](BUG-128-fixed-footer-covers-last-lines.md) | P4 | HTMLPage | A position:fixed footer/header in a mail permanently covers the message's last (or first) lines |
| [129](BUG-129-apple-mail-list-styles.md) | P4 | HTMLPage | Apple Mail dash lists show bullets, and nested numbered lists show 1. 1. 1. instead of 1. a. i. |
| [130](BUG-130-contenteditable-mail-is-editable.md) | P4 | HTMLPage | A mail with contenteditable can be edited in the message view (the reader can type into received mail) |
| [131](BUG-131-embedded-pictures-hidden-when-remote-blocked.md) | P4 | HTMLPage | With remote content blocked, embedded (data:) pictures are hidden when given via srcset/<picture> or with a leading space in src |
| [132](BUG-132-pending-search-shows-mailbox-instead-of-results.md) | P4 | MailStore | While the next search answer is on its way, the list jumps back to the plain mailbox (or "No Results") when the previous results came from memory |
| [134](BUG-134-finder-alias-attached-as-bookmark.md) | P3 | MailStore | A dropped or pasted Finder alias is attached as the alias file itself (about 940 bytes of bookmark data), not the file or folder it points to |
| [135](BUG-135-nameless-attachments-hidden-or-not-listed.md) | P3 | EWS | Attachments without a name: an attached message with no subject saves as a hidden ".eml", and an attachment Exchange sends without Name is not listed at all |
| [136](BUG-136-unsent-answer-trash-move-skipped.md) | P3 | Invite | Do Not Send a Response / Remove from Calendar skip the move to Deleted Items before the folder list is read: the answered invite comes back to the Inbox |
| [137](BUG-137-selected-message-linear-scan-per-read.md) | P3 | MailStore | Clicking a message that arrived this session takes 0.43 s: selectedMessage scans all messages on each of its 7 reads per redraw |
| [138](BUG-138-cancelled-loads-reported-as-errors.md) | P3 | MailStore | Moving on from a message before it has loaded shows "Couldn’t load message: cancelled" (also images, calendar, attachment previews) |
| [139](BUG-139-stale-server-answer-undoes-sent-change.md) | P3 | MailStore | A check answer taken before a local change, arriving after that change reached Exchange, undoes it: a moved message comes back as a ghost for good, a flag loses its colour, read turns unread |
| [140](BUG-140-body-requested-before-server-change-kept.md) | P3 | MailStore | A body requested before the server changed the message is stored as the body of the new version and never fetched again |
| [141](BUG-141-refused-erase-after-rename-restores-old-id.md) | P3 | MailStore | A refused erase queued behind a move to Trash puts the message back with its old ItemId; the next Trash check then shows it twice |
| [142](BUG-142-invite-time-drops-end-date.md) | P3 | Invite | Invite card shows only the start day for a meeting that ends on a later day |
| [143](BUG-143-unloadable-picture-spins-forever.md) | P3 | Attachments | A picture attachment that can't be loaded shows a spinner forever |
| [144](BUG-144-quick-look-shows-another-file.md) | P4 | MailStore | Space on an attachment that cannot be loaded opens Quick Look on a different attachment of the message |
| [145](BUG-145-reference-attachment-listed-but-unopenable.md) | P4 | EWS | A cloud attachment (ReferenceAttachment, OneDrive/SharePoint link) is listed like a file but every open, save or Quick Look fails with "The server sent no content" |
| [146](BUG-146-memory-search-per-keystroke-freeze.md) | P4 | MailStore | Search without the index (index build failed or still building, or "Search failed") freezes 0.6-1 s per keystroke on 180,000 messages |
| [147](BUG-147-late-quick-look-replaces-newer.md) | P4 | MailStore | Quick Look jumps back to an earlier message’s attachment when its download finishes after you looked at another message |
| [148](BUG-148-day-column-overnight-hours.md) | P4 | Invite | Day column of an overnight invite starts at 2 o'clock and the invite's slot is outside the grid |
| [149](BUG-149-allday-invite-drawn-as-24h-block.md) | P4 | Invite | All-day invite is drawn in the day column as a 24-hour hatched block from 0:00 |
| [150](BUG-150-day-column-spinner-never-stops.md) | P4 | Invite | Invite day column spins forever when the calendar can't be loaded |
| [151](BUG-151-chosen-answer-not-highlighted.md) | P4 | Invite | Answered invite: the chosen answer button isn't highlighted (the tint has no effect) |
| [152](BUG-152-vip-star-misaligns-sender.md) | P4 | MessageList | VIP star sits in the sender line, pushing the name out of line with subject and preview (and next to the unread dot) |
| [153](BUG-153-list-fonts-not-13-11.md) | P4 | MessageList | README ✅ says list rows use 13 pt / 11 pt; subject, preview and date render at 12 pt |
