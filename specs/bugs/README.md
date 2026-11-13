# Bug list

Found 2026-11-12 by probe tests. Each bug file has its repro test and the failure output. All probes are in `probes/`. To run them, copy them into `Tests/MailModelTests/` and run with `--filter Probe_`. Each bug cites at least one failing probe; a few passing probes are controls. They stay out of the main suite.

Limits: results are store-level only, and the app wasn't run. Mail.app expectations marked ⚠️ are recalled, not checked. Some EWS items use response shapes not confirmed on the live server. Sync with the server is untested: there is no backend double and mocks aren't allowed.

| # | Priority | Area | Title |
|---|---|---|---|
| [084](BUG-084-ipf-note-subclass-folders-hidden.md) | P4 | EWS | Mail folders whose class is a subclass of IPF.Note (e.g. IPF.Note.OutlookHomepage) are left out of the folder tree |
| [104](BUG-104-answered-invite-shows-unanswered-after-sync.md) | P3 | Invite | An invite answered here shows "Please respond" again once Exchange has moved it to Deleted Items |
| [146](BUG-146-memory-search-per-keystroke-freeze.md) | P4 | MailStore | Search without the index (index build failed or still building, or "Search failed") freezes 0.6-1 s per keystroke on 180,000 messages |
| [154](BUG-154-mark-all-read-keeps-hidden-selection.md) | P3 | MailStore / selection | Mark All as Read with the unread filter (or in Unread) leaves the selected messages selected after they leave the list |
| [155](BUG-155-non-row-selection-dropped-by-actions.md) | P2 | MailStore / conversations | After a reply arrives in the open conversation, flagging, marking or swiping its row clears the selection |
| [156](BUG-156-comma-only-sender-name-crashes-list.md) | P1 | Models / ConversationRow | A sender named "," (or ", ") in a conversation crashes the app |
| [157](BUG-157-same-first-name-senders-shown-as-one.md) | P3 | Models / ConversationRow | Two different senders with the same first name show as one sender's full name |
| [158](BUG-158-delete-in-folder-inside-trash-moves-to-trash.md) | P4 | MailStore / actions | Delete in a folder inside Trash moves the mail to Trash instead of erasing it |
| [159](BUG-159-invite-answer-selection-depends-on-hidden-member.md) | P4 | MailStore / conversations | Answering an invite moves the selection to another conversation, but only when the selection holds the invite rather than its row |
| [160](BUG-160-conversation-first-names-wrong-for-corporate-names.md) | P3 | Models / ConversationRow | The conversation row shows "Jan (mgm-tp)" / "Sergio Luis" / "Jan Jikeli" instead of first names |
| [161](BUG-161-background-check-ignores-throttling.md) | P3 | Sync | Exchange throttling during the background check of off-screen folders doesn't set the account aside: every other folder is asked again |
| [162](BUG-162-mail-folder-in-non-mail-folder-shown-or-archive.md) | P4 | EWS | A mail folder inside Contacts, Calendar or Tasks shows at the top level, and one named Archive becomes the account's Archive |
| [163](BUG-163-archive-removed-on-server-keeps-mail.md) | P3 | Sync | An Archive folder deleted on the server keeps its mail and sync position in Archive for good |
| [164](BUG-164-throttled-send-does-not-hold-account.md) | P3 | Outbox | A send that Exchange throttles doesn't hold back the account's other changes: they go out at once, inside the back-off |
| [165](BUG-165-wcf-fault-without-code-undoes-change.md) | P3 | EWS | A SOAP fault without an Exchange ResponseCode (IIS/WCF internal error) undoes the change as "refused" |
| [166](BUG-166-folder-list-failure-undoes-queued-move.md) | P3 | Outbox | A queued move is undone as "refused" when reading the folder list fails |
| [167](BUG-167-two-refused-changes-leave-wrong-state.md) | P3 | Outbox | Two refused changes of the same message leave it in the state of the first change, which the server never had |
| [168](BUG-168-refused-folder-stops-newest-of-others.md) | P4 | Sync | One folder that Exchange refuses in the history's first step stops the newest-200 fetch for all the account's other folders |
| [169](BUG-169-account-address-not-trimmed.md) | P3 | EWS | An email pasted with a blank keeps the blank in the account's address: your own invitations become answerable, and MailTips asks for the wrong address |
| [170](BUG-170-rejected-password-not-paused-mailtips-move.md) | P3 | EWS | A rejected password seen by MailTips or by the move after an unsent answer doesn't pause the account, so the wrong password is sent again |
| [171](BUG-171-thai-halfwidth-kana-words-not-found.md) | P3 | search | A word inside Thai text (or half-width katakana) isn't found by search |
| [172](BUG-172-memory-search-keeps-punctuation-words.md) | P3 | search | Memory search requires punctuation the index ignores; an invisible character alone lists all mail |
| [173](BUG-173-arabic-hebrew-vowel-marks.md) | P4 | search | Arabic and Hebrew words with vowel marks aren't found when typed without them |
| [174](BUG-174-georgian-mtavruli-not-indexed.md) | P4 | search | Georgian written in capitals (Mtavruli) isn't found by search |
| [175](BUG-175-damaged-database-never-recovered.md) | P3 | storage | A damaged Mail.sqlite stops all saving for good; it's never set aside |
| [176](BUG-176-huge-file-crashes-save.md) | P3 | storage | Saving a draft file or pending send of 2 GB or more crashes the app |
| [177](BUG-177-import-sends-outbox-before-cache-renamed.md) | P2 | storage | Importing Cache.json sends its waiting mail before the import is done; quitting then sends it twice |
| [178](BUG-178-subtitle-1-messages.md) | P4 | UI / MessageViewer | The window subtitle says "1 messages" for a mailbox with one message |
| [179](BUG-179-compose-from-row-centred.md) | P4 | UI / ComposeView | Compose window: the "From:" row is centred instead of lined up with To, Cc and Subject |
| [180](BUG-180-header-date-wraps.md) | P4 | UI / MessageDetailView | Message header: the date breaks onto two lines in a narrow message pane |
| [181](BUG-181-invite-text-squeezed.md) | P4 | UI / InviteView | Invite: the fixed 300 pt day column squeezes the message text to a few words per line |
| [182](BUG-182-junk-button-label-in-junk.md) | P4 | UI / MessageViewer, MailCommands, MessageListView | Junk button, menu and context menu keep saying "Junk" / "Move to Junk" in the Junk mailbox, where they move mail to the Inbox |
| [183](BUG-183-mailbox-menu-crash-7-accounts.md) | P2 | UI / MailCommands | With 7 or more accounts the app crashes building the Mailbox menu (⌘10 shortcut) |
| [184](BUG-184-new-viewer-window-mirrors.md) | P3 | UI / MessageViewer | File ▸ New Viewer Window opens a second window that always shows the same mailbox and selection as the first |
| [185](BUG-185-flagged-badge-unread.md) | P4 | UI / SidebarView | Flagged in the sidebar shows no count while flagged messages are read |
