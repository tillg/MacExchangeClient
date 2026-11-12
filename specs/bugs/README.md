# Bug list

Found 2026-11-12 by probe tests. Each bug file has its repro test and the failure output. All probes are in `probes/`. To run them, copy them into `Tests/MailModelTests/` and run with `--filter Probe_`. Each bug cites at least one failing probe; a few passing probes are controls. They stay out of the main suite.

Limits: results are store-level only, and the app wasn't run. Mail.app expectations marked ⚠️ are recalled, not checked. Some EWS items use response shapes not confirmed on the live server. Sync with the server is untested: there is no backend double and mocks aren't allowed.

| # | Priority | Area | Title |
|---|---|---|---|
| [001](BUG-001-legacy-attachment-names-break-cache-import-and-outbox.md) | P1 | Models | Attachment names stored by older versions no longer decode: old Cache.json can never be imported and waiting outbox changes are silently dropped |
| [002](BUG-002-hidden-selection-erased-by-second-delete.md) | P1 | MailStore | Delete keeps a selection that is no longer in the list; a second Delete erases the message from Trash unseen |
| [003](BUG-003-trash-hits-crowd-out-search-results.md) | P2 | MailStore | Indexed search: Trash/Junk hits fill the 2,000-result cap, hiding real matches and showing 'Showing the newest 2,000 results' over an empty list |
| [004](BUG-004-control-chars-break-ews-requests.md) | P2 | EWS | Control characters in subject/body/file name/invite comment make the EWS request malformed XML, so Send/Save/Answer fails |
| [005](BUG-005-parselist-quoted-display-names.md) | P2 | Models | Contact.parseList breaks quoted display names (comma inside quotes splits the contact; quotes kept in name) |
| [006](BUG-006-opened-message-vanishes-from-unread-filter.md) | P2 | MailStore | Opening a message with the unread filter on (or in the Unread mailbox) removes it from the list at once |
| [007](BUG-007-reply-all-includes-own-address-when-case-differs.md) | P2 | MailStore | Reply All keeps my own address when the original lists it in different case |
| [008](BUG-008-reply-quote-ignores-crlf-lines.md) | P2 | MailStore | Reply/forward quoting marks only the first line of a CRLF body |
| [009](BUG-009-corrupt-cache-json-blocks-database-forever.md) | P3 | MailDatabase | An unreadable Cache.json blocks creating Mail.sqlite on every launch; nothing is ever saved again |
| [010](BUG-010-iso-dates-without-z-or-with-fraction-dropped.md) | P3 | EWS | Dates with fractional seconds or without a zone suffix aren't parsed: message dated year 1, invite and calendar events dropped |
| [011](BUG-011-sanitize-misses-noncharacter-references.md) | P3 | EWS | `&#xFFFE;`/`&#xFFFF;`/surrogate references in a response still make the whole page unreadable |
| [012](BUG-012-server-field-not-normalised.md) | P3 | EWS | Server field: `http://…`, `host/EWS/Exchange.asmx`, `host/`, trailing newline or blanks give a wrong EWS URL |
| [013](BUG-013-attached-message-opens-nested-file-content.md) | P3 | EWS | Opening an attached message (.eml) can return the content of a file inside it instead of its MIME source |
| [014](BUG-014-inline-image-with-generic-content-type-not-loaded.md) | P3 | EWS | Inline pictures sent as `application/octet-stream` are never fetched, so the HTML shows a broken image |
| [015](BUG-015-parselist-semicolon-separator.md) | P3 | Models | Contact.parseList treats "a@x.com; b@y.com" as one recipient |
| [016](BUG-016-parselist-does-not-trim-newlines-or-bracket-spaces.md) | P3 | Models | Contact.parseList leaves newlines and spaces inside <> in the address |
| [017](BUG-017-preview-recomputed-over-whole-body.md) | P3 | Models | Message.preview processes the entire body on every access (80-300 ms for a 1 MB body) |
| [018](BUG-018-hasremotecontent-misses-remote-references.md) | P3 | HTMLPage | hasRemoteContent misses srcset, <link href>, poster and &quot;-quoted url(), so no Load Remote Content banner |
| [019](BUG-019-inline-image-content-type-injected-into-page.md) | P3 | HTMLPage | Inline image content type is inserted unescaped into the page, breaking out of the src attribute |
| [020](BUG-020-long-attachment-name-cannot-be-saved.md) | P3 | Models | Attachments whose name exceeds 255 bytes cannot be opened/saved (File name too long) |
| [021](BUG-021-draft-html-crlf-lines-merged.md) | P3 | Models | Draft.html merges CRLF lines into one, so quoted text arrives as one paragraph when a picture is placed |
| [022](BUG-022-draft-html-collapses-spaces.md) | P3 | Models | Draft.html collapses runs of spaces and tabs (indented text/tables lose their layout) |
| [023](BUG-023-refused-change-undoes-unrelated-later-changes.md) | P3 | MailStore | A refused server change restores the whole old message, undoing later queued changes (e.g. a move) or resurrecting an erased message |
| [024](BUG-024-junk-on-mixed-selection-swaps.md) | P3 | MailStore | Move to Junk on a mixed selection swaps each message (junk ones go to the Inbox) |
| [025](BUG-025-trash-subfolders-not-treated-as-trash.md) | P3 | MailStore | Subfolders of Trash (deleted folders) are treated as live mail – shown in conversations and in Flagged |
| [026](BUG-026-reply-all-duplicates-recipients.md) | P3 | MailStore | Reply All lists the same recipient several times |
| [027](BUG-027-reply-all-moves-cc-into-to.md) | P3 | MailStore | Reply All puts the original Cc recipients into To; Cc stays empty |
| [028](BUG-028-reply-forward-prefix-case-sensitive.md) | P3 | MailStore | Reply/Forward stack prefixes: "RE: x" becomes "Re: RE: x", "Re:x" becomes "Re: Re:x" |
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

Not counted: [design question: memory-search fallback](design-question-memory-search-fallback.md). The README documents the launch fallback as "as before", which conflicts with its own matching rules.
