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
| [094](BUG-094-save-while-original-files-load-discards-message.md) | P2 | MailStore | Closing a forward while its original files are still loading: Save in the sheet throws the message away |
| [095](BUG-095-send-in-flight-at-quit-sent-again-after-relaunch.md) | P2 | MailStore | A send that is on its way when the app quits (or crashes) is sent again at the next launch |
| [096](BUG-096-unreachable-account-blocks-other-accounts-outbox.md) | P2 | MailStore | One unreachable account holds up every other account's changes and sends |
| [097](BUG-097-preconnect-reaches-sender-server.md) | P2 | HTMLPage | <link rel="preconnect"> in a blocked mail opens a connection to the sender's server, so opening the mail is reported although remote content is blocked |
| [098](BUG-098-unreachable-account-stops-other-accounts-history.md) | P3 | MailStore | One unreachable account stops the background history and background checks of every other account |
| [099](BUG-099-invite-answered-in-multiselection-erased-by-delete.md) | P3 | MailStore | An invite answered while it is part of a multi-selection stays selected in Trash; Delete then erases it |
| [100](BUG-100-mail-check-clears-couldnt-send-and-other-account-errors.md) | P3 | MailStore | Each mail check clears the status: "Couldn't send …" and another account's error disappear |
| [101](BUG-101-send-from-account-without-password.md) | P3 | MailStore | Send from an Exchange account without a Keychain password: shown in Sent though nothing is sent, or queued with no word |
| [102](BUG-102-invite-answer-comment-lost-on-network-error.md) | P3 | MailStore | Respond with Comments that fails with a network error is undone and the typed comment is lost |
| [103](BUG-103-message-changed-on-server-keeps-old-body.md) | P3 | MailStore | A draft changed on the server keeps its old loaded body: new subject, old text and files |
| [104](BUG-104-answered-invite-shows-unanswered-after-sync.md) | P3 | Invite | An invite answered here shows "Please respond" again once Exchange has moved it to Deleted Items |
| [105](BUG-105-failed-send-with-files-leaves-half-draft-in-exchange.md) | P3 | EWS | A send or Save Draft with files that fails after the message was created leaves a copy without its files in Exchange's Drafts |
| [106](BUG-106-meta-refresh-about-blank-wipes-message.md) | P3 | HTMLPage | A mail with <meta http-equiv="refresh" content="0;url=about:blank"> (or a link to about:blank) replaces its own body with an empty page |
| [107](BUG-107-autofocus-collapses-message.md) | P3 | HTMLPage | A mail with an autofocus form field shrinks to a few pixels: the page scrolls to the field at load and the height is measured relative to that scroll |
| [108](BUG-108-measure-ignores-body-padding-and-out-of-flow.md) | P3 | HTMLPage | Height counts only the wrapper's box: body padding and absolutely positioned content are cut off |
| [109](BUG-109-height-not-remeasured-after-page-changes.md) | P3 | HTMLPage | The body's height is never re-measured when the page grows after load (lazy images, <details>, interactive mail): the end is cut off |
| [110](BUG-110-viewport-relative-heights-feed-back.md) | P3 | HTMLPage | Mail with window-relative heights (MailChimp height="100%" table, 100vh) is measured against the view's own height: after widening the window it never gets shorter, and 100vh blocks push the end out |
| [111](BUG-111-apple-mail-quotes-without-quote-bar.md) | P3 | HTMLPage | Apple Mail quotes (<blockquote type="cite">) show as a plain 40px indent instead of Mail's quote bar |
| [112](BUG-112-apple-mail-pictures-overflow-window.md) | P3 | HTMLPage | Pictures sent from Apple Mail (img.Apple-web-attachment) show at full pixel width, far wider than the window |
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
