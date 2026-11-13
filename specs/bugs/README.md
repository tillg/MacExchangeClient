# Bug list

Open bugs, each with its repro and the failure output. Found by probe tests: round 4 on 2026-11-12, round 5 on
2026-11-13 (BUG-154…255, 102 bugs from 14 hunters in areas: conversations, EWS sync and requests, search and storage,
rendering and compose, UI snapshots, the view layer, scale and races, dates and zones, text and encoding, attachments,
folders, accounts and settings, fidelity with Mail.app's bundle). Fixed bugs are removed from this list; see git log
(`git log --grep BUG-`) and DECISIONS.md.

- **Probes** are in `probes/` (`Probe_R5*Tests.swift` for round 5). To run them, copy one into `Tests/MailModelTests/`
  and run with `--filter Probe_R5…`; they stay out of the main suite. A few passing probes are controls.
- **View-layer bugs** use the harness in `probes-views/` (`run-harness.sh build`, then a scenario), which runs the
  app's real views with sample data, no account and no network.
- **UI-only bugs** cite a `tools/snapshot.sh` command and a PNG in `png/`.
- Priorities: P1 data loss/crash/security, P2 wrong in everyday use, P3 visible edge case, P4 cosmetic or rare.
  Expectations marked ⚠️ are recalled, not checked. Sync is tested over a loopback server with scripted EWS answers
  (no mocks); some response shapes are not confirmed on a live server.

| # | Priority | Area | Title |
|---|---|---|---|
| [084](BUG-084-ipf-note-subclass-folders-hidden.md) | P4 | EWS | Mail folders whose class is a subclass of IPF.Note (e.g. IPF.Note.OutlookHomepage) are left out of the folder tree |
| [104](BUG-104-answered-invite-shows-unanswered-after-sync.md) | P3 | Invite | An invite answered here shows "Please respond" again once Exchange has moved it to Deleted Items |
| [146](BUG-146-memory-search-per-keystroke-freeze.md) | P4 | MailStore | Search without the index (index build failed or still building, or "Search failed") freezes 0.6-1 s per keystroke on 180,000 messages |
| [158](BUG-158-delete-in-folder-inside-trash-moves-to-trash.md) | P4 | MailStore / actions | Delete in a folder inside Trash moves the mail to Trash instead of erasing it |
| [159](BUG-159-invite-answer-selection-depends-on-hidden-member.md) | P4 | MailStore / conversations | Answering an invite moves the selection to another conversation, but only when the selection holds the invite rather than its row |
| [161](BUG-161-background-check-ignores-throttling.md) | P3 | Sync | Exchange throttling during the background check of off-screen folders doesn't set the account aside: every other folder is asked again |
| [162](BUG-162-mail-folder-in-non-mail-folder-shown-or-archive.md) | P4 | EWS | A mail folder inside Contacts, Calendar or Tasks shows at the top level, and one named Archive becomes the account's Archive |
| [163](BUG-163-archive-removed-on-server-keeps-mail.md) | P3 | Sync | An Archive folder deleted on the server keeps its mail and sync position in Archive for good |
| [164](BUG-164-throttled-send-does-not-hold-account.md) | P3 | Outbox | A send that Exchange throttles doesn't hold back the account's other changes: they go out at once, inside the back-off |
| [165](BUG-165-wcf-fault-without-code-undoes-change.md) | P3 | EWS | A SOAP fault without an Exchange ResponseCode (IIS/WCF internal error) undoes the change as "refused" (deferred) |
| [166](BUG-166-folder-list-failure-undoes-queued-move.md) | P3 | Outbox | A queued move is undone as "refused" when reading the folder list fails |
| [167](BUG-167-two-refused-changes-leave-wrong-state.md) | P3 | Outbox | Two refused changes of the same message leave it in the state of the first change, which the server never had |
| [168](BUG-168-refused-folder-stops-newest-of-others.md) | P4 | Sync | One folder that Exchange refuses in the history's first step stops the newest-200 fetch for all the account's other folders |
| [171](BUG-171-thai-halfwidth-kana-words-not-found.md) | P3 | search | A word inside Thai text (or half-width katakana) isn't found by search |
| [173](BUG-173-arabic-hebrew-vowel-marks.md) | P4 | search | Arabic and Hebrew words with vowel marks aren't found when typed without them |
| [174](BUG-174-georgian-mtavruli-not-indexed.md) | P4 | search | Georgian written in capitals (Mtavruli) isn't found by search |
| [178](BUG-178-subtitle-1-messages.md) | P4 | UI / MessageViewer | The window subtitle says "1 messages" for a mailbox with one message |
| [179](BUG-179-compose-from-row-centred.md) | P4 | UI / ComposeView | Compose window: the "From:" row is centred instead of lined up with To, Cc and Subject |
| [180](BUG-180-header-date-wraps.md) | P4 | UI / MessageDetailView | Message header: the date breaks onto two lines in a narrow message pane |
| [181](BUG-181-invite-text-squeezed.md) | P4 | UI / InviteView | Invite: the fixed 300 pt day column squeezes the message text to a few words per line |
| [182](BUG-182-junk-button-label-in-junk.md) | P4 | UI / MessageViewer, MailCommands, MessageListView | Junk button, menu and context menu keep saying "Junk" / "Move to Junk" in the Junk mailbox, where they move mail to the Inbox |
| [184](BUG-184-new-viewer-window-mirrors.md) | P3 | UI / MessageViewer | File ▸ New Viewer Window opens a second window that always shows the same mailbox and selection as the first (deferred) |
| [185](BUG-185-flagged-badge-unread.md) | P4 | UI / SidebarView | Flagged in the sidebar shows no count while flagged messages are read |
| [187](BUG-187-reply-all-note-to-self-empty-to.md) | P4 | compose | Reply All to a note sent only to myself opens with an empty To |
| [191](BUG-191-video-never-loads-after-load-remote-content.md) | P4 | rendering | A web video counts as remote content, but Load Remote Content never loads it (no media-src in the policy) |
| [194](BUG-194-dotfile-attachment-saved-hidden.md) | P4 | attachments | An attachment named ".something.pdf" is saved as a hidden file the user can't find (deferred: conflicts with an existing test) |
| [195](BUG-195-recipient-group-and-comment-syntax.md) | P4 | compose | Recipients written with RFC 5322 group syntax or a comment become invalid addresses ("Team: a@x.com", "a@x.com (Ann)") |
| [196](BUG-196-content-id-not-a-msg-id.md) | P4 | compose / sent HTML | Placed pictures are sent with a Content-ID without "@" (bare UUID) |
| [197](BUG-197-blocked-picture-source-broken-box.md) | P4 | rendering | With remote content blocked, <picture> with a web <source> and <input type=image> show WebKit's broken-image box |
| [199](BUG-199-whatsnew-date-day-early-west-of-utc.md) | P4 | UI / WhatsNewView | Help ▸ What's New dates each day one day early on a Mac west of UTC (2026-11-13 shown as Thursday, 12 November) |
| [201](BUG-201-when-line-runs-backwards-on-clock-change.md) | P4 | invites | On the night the clocks go back, an invite's when line reads "at 2:30 – 2:15", as if it ended before it starts |
| [202](BUG-202-recurring-invite-shown-as-one-off.md) | P3 | invites / EWS | A recurring meeting's invite is shown as a one-off meeting: nothing says it repeats (deferred) |
| [203](BUG-203-reply-stacks-numbered-or-indented-prefix.md) | P4 | compose | Reply to "Re[2]: …" or to a subject with a leading blank (" Re: …") stacks a second "Re:" |
| [204](BUG-204-html-source-line-breaks-kept.md) | P4 | ews / plain text of HTML | Text of an HTML-only mail keeps the HTML source's line breaks: paragraphs break mid-sentence and every <br> gives a blank line in quotes |
| [205](BUG-205-block-elements-run-together.md) | P4 | ews / plain text of HTML | Text of an HTML-only mail runs blocks together: "Original textMy answer" after </blockquote>, <hr>, or an unclosed <p> |
| [206](BUG-206-gt-in-attribute-leaks-markup.md) | P4 | ews / plain text of HTML | Text of an HTML-only mail shows tag remains when an attribute value contains ">" (alt="->", title="a > b") |
| [207](BUG-207-c1-numeric-references-become-controls.md) | P4 | ews / plain text of HTML | Text of an HTML-only mail loses ’, € and – written as &#146; &#128; &#150; (they become invisible control characters) |
| [208](BUG-208-non-utf8-byte-fails-whole-response.md) | P4 | ews / transport | A message whose text holds one non-UTF-8 byte or a raw control character never opens ("Unreadable EWS response" on every try) |
| [209](BUG-209-content-type-parameters-not-stripped.md) | P4 | ews / attachments | An attachment content type with parameters ("application/octet-stream; name=logo.png") hides an inline logo and drops an unnamed file's extension |
| [210](BUG-210-cid-placeholders-in-preview-and-quote.md) | P3 | ews body / preview / compose | ⚠️ "[cid:image001.png@01D…]" from Exchange's text version shows in the list preview and is quoted in replies (deferred) |
| [211](BUG-211-colon-in-attachment-name-shows-as-slash.md) | P4 | attachments | ⚠️ An attachment with ":" in its name (attached message "Re: Budget") is saved as "Re/ Budget.eml" in the Finder |
| [212](BUG-212-attachment-named-original-cant-be-saved.md) | P4 | attachments | An attachment named "Original" can't be saved once an app has changed the opened copy |
| [213](BUG-213-invisible-characters-kept-in-address.md) | P4 | compose / recipients | An address pasted with a BOM or word joiner around it keeps the invisible character and goes to an address that doesn't exist |
| [222](BUG-222-conversation-view-rebuilds-list-twice-on-open.md) | P3 | MailStore | With conversations on (the default), opening the next unread message in a large mailbox rebuilds the list twice: 0.37-0.94 s per click in Archive (30,000) |
| [224](BUG-224-check-before-stored-state-read-keeps-deleted-mail.md) | P3 | Launch | Clicking a mailbox while "Loading Mail…" reads the database starts the history sync early; mail deleted on the server while the app was closed then stays forever |
| [225](BUG-225-silent-server-holds-up-other-accounts.md) | P3 | MailStore | An account whose server doesn't answer (on-prem Exchange off the VPN) holds up the other accounts' new mail and changes for up to 60 s per check (deferred) |
| [226](BUG-226-reply-to-message-deleted-while-body-loads.md) | P4 | MailStore | Reply to an unopened message that is deleted on the server while its body loads opens an empty message from the first account |
| [227](BUG-227-include-attachments-menu-order.md) | P4 | MailModel / IncludeAttachments, MailCommands | Edit ▸ Include Attachments With Replies lists Never, Ask, When Adding Recipients, Always; Mail lists Always, Never, When Adding Recipients, Ask |
| [228](BUG-228-message-menu-structure.md) | P4 | UI / MailCommands | Message menu differs from MainMenu.nib: "Mark as Read/Unread", Toggle Flag outside the Flag submenu, Move to Junk after Archive, Delete in Message instead of Edit |
| [229](BUG-229-view-menu-filter-back-forward.md) | P4 | UI / MailCommands, MessageViewer | View menu: Enable Message Filter is not in a Filter submenu, and Back ⇧⌘[ / Forward ⇧⌘] are missing though the toolbar has them |
| [230](BUG-230-mailbox-menu-favorites.md) | P4 | UI / MailCommands | Mailbox menu: ⌘1–⌘9 mailboxes sit at the top level instead of under Go to Favorite Mailbox, and Get New Mail has its own group |
| [231](BUG-231-toolbar-view-options-symbol-flag-tooltip.md) | P4 | UI / MessageViewer | Toolbar: View Options shows line.3.horizontal instead of Mail's ellipsis.circle; the Flag tooltip lacks the colour ("Flag selected messages as Red") |
| [232](BUG-232-compose-send-symbol-position.md) | P4 | UI / ComposeView | Compose toolbar: Send is a paper plane at the leading edge; Mail's Send is arrow.up at the trailing edge |
| [233](BUG-233-ask-include-dialog-wording.md) | P4 | UI / ComposeView | Include-attachments Ask dialog adds a "?" to Mail's title and spells "Don't Include" with a straight apostrophe |
| [234](BUG-234-unread-smart-mailbox-icon.md) | P4 | UI / SidebarView | Sidebar: the Unread smart mailbox shows a bare gear; Mail's smart mailbox icon is a folder with a gear |
| [235](BUG-235-message-context-menu-order.md) | P4 | UI / MessageListView | Message list context menu: Move to Junk and Delete come after Archive; in Mail they follow Mark as Read, before Flag, and Move to is missing |
| [236](BUG-236-cloud-attachment-body-refetched.md) | P4 | attachments / EWS | A message with a cloud attachment (OneDrive/SharePoint link) fetches its body again every time it is shown |
| [237](BUG-237-attachment-change-on-server-ignored.md) | P3 | Sync / attachments | A file added to or removed from a message on the server (a draft edited in Outlook) never shows: the old attachment list and paperclip stay |
| [238](BUG-238-forward-of-vanished-original-drops-files.md) | P3 | compose / forward | A forward whose original is gone while its files load is released without them, without a word |
| [240](BUG-240-opened-copy-stale-after-message-changed.md) | P4 | attachments / Mail Downloads | After a message changed on the server, Open and Save still give the old version of a file with the same name |
| [241](BUG-241-symlink-to-alias-attaches-bookmark.md) | P4 | compose / attaching files | A symbolic link to a Finder alias is attached as the alias's bookmark bytes, not the file it points to |
| [244](BUG-244-malformed-server-other-host.md) | P4 | Accounts / ExchangeAccount | A mistyped server (ftp://, https:/, https//, ?x, #x, port 99999) becomes a URL to another host or path instead of "Invalid server" |
| [246](BUG-246-bare-ipv6-invalid.md) | P4 | Accounts / ExchangeAccount | An IPv6 address typed without brackets (2001:db8::1) is "Invalid server" |
| [247](BUG-247-organisation-domain-spelling.md) | P4 | Privacy / RemoteImages | "My organisation" treats the same domain as foreign when it is spelled differently (bücher.de vs xn--bcher-kva.de, or work.com.) |
| [249](BUG-249-conversations-off-keeps-read-members.md) | P4 | MailStore / Viewing settings | Turning conversations off with the unread filter on keeps an opened conversation's other messages in the list, read and unselected |
| [250](BUG-250-one-row-two-messages-nothing-open.md) | P4 | MailStore / search, conversations | Two results of one conversation selected in a search become one selected row after clearing it, but nothing opens ("2 messages selected", Reply disabled) |
| [251](BUG-251-title-not-searching.md) | P4 | MailStore / MessageViewer | While searching, the window title and subtitle describe the mailbox, not the search results |
| [253](BUG-253-queued-move-into-deleted-folder-loses-message.md) | P3 | Outbox / folders | A move queued offline into a folder that is then deleted on the server makes the message vanish from the app; the status says "There is no  folder |
| [254](BUG-254-refused-move-restores-into-deleted-folder.md) | P3 | Outbox / folders | A refused move out of a folder deleted on the server puts the message back into that folder, where it is invisible but still in Flagged and search |
| [255](BUG-255-archive-without-folder-says-exchange-refused.md) | P4 | MailStore / actions | Archive in an Exchange account without an Archive folder moves the message, then jumps it back with "Exchange refused a change", though nothing was sent |
