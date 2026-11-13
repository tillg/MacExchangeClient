---
title: "Functional"
created: 2026-11-12
edited: 2026-11-13
---

# Functional

What a user can do today. Behaviour lives in `Sources/MailModel/MailStore.swift`; views are in
`Sources/MailReplica/`. Search: [search.md](search.md). Message rendering: [rendering.md](rendering.md). Known bugs
that change these rules: [../bugs/README.md](../bugs/README.md).

## Window and mailboxes

- One three-column window (`MessageViewer.swift`): sidebar, message list, message view. Title is the mailbox
  ("All Inboxes", "Inbox – Exchange", a folder name); subtitle is `status` if set, else "N messages, U unread".
- Toolbar: back/forward through visited mailboxes, unread filter, View Options (Show Contact Photo), New Message;
  Reply / Reply All / Forward; Archive / Delete / Junk; Move menu (every account's mailboxes, subfolders indented);
  Flag menu (click toggles red); search field.
- Sidebar (`SidebarView.swift`): **Favorites** (All Inboxes — with more than one account a disclosure group with
  each account's Inbox —, VIPs, Flagged), **Smart Mailboxes** (Unread), then per account the standard mailboxes
  Inbox, Drafts, Sent, Junk, Trash, Archive, followed by the account's own top-level folders sorted by name
  (`localizedStandardCompare`). Folders with subfolders have a disclosure triangle, closed at launch.
- Badges: Drafts shows its total; Sent, Trash and Archive show none; everything else shows unread.
- Smart mailbox rules (`contains`): All Inboxes = mailbox is `.inbox` (subfolders of Inbox don't count); VIPs = VIP
  and in Inbox; Flagged = any flag and not in `.trash` or a folder inside it (any depth: Exchange keeps deleted folders in Deleted Items); Unread = unread and in Inbox.
- Selecting a mailbox clears the selection and runs a quick check. ⌘1–⌘9 go to All Inboxes, VIPs, Flagged, then each
  account's Inbox. Right-click a mailbox: Mark All Messages as Read.
- While syncing, the sidebar bottom shows a progress bar with "Loading Mail…", "Updating Mail Storage…" or
  "Synchronizing “Exchange”".

## Message list

- `visibleMessages`: the selected mailbox's messages, newest first. With the unread filter (⌘L) only unread ones
  (and the opened message, see below).
  While searching, the list shows search results instead and ignores the unread filter ([search.md](search.md)).
- Row: unread dot, or for a VIP sender a star in the same column (accent while unread, grey when read), optional
  avatar, sender (13 pt semibold; subject, preview and date 12 pt) (for Sent and Drafts "To: " + first recipient), date (time today,
  "Yesterday", weekday within 7 days, else short date), subject, paperclip, flag, two-line preview.
- Selecting exactly one message marks it read (one main-loop turn later), and the message view loads it.
- A message that was unread when opened stays in the list with the unread filter and in Unread while it is selected
  (it is judged as unread there; sidebar counts use the real state). It leaves once the selection moves on, the
  filter is toggled or another mailbox is selected; deleted or moved, it leaves at once.
- Swipe right: Read/Unread. Swipe left: Trash, Flag (toggles orange). Right-click: Reply, Reply All, Forward (single
  message), Mark as Read/Unread, Flag colours, Archive, Move to Junk, Delete.
- Pull down past the top: quick check, with a spinner shown at least 0.8 s (`PullToRefresh.swift`).

## Actions and selection

| Action | Effect |
|---|---|
| Delete (⌘⌫) | Messages in Trash are erased (removed; server: `DeleteItem` SoftDelete); others move to the account's Trash |
| Archive (⌃⌘A) | Move to `.archive`, also when already there |
| Junk (⇧⌘J) | All to Junk if any selected message is outside Junk; if all are in Junk, all to the Inbox (Not Junk) |
| Mark as Read/Unread (⇧⌘U) | All become read if any is unread, else all unread |
| Toggle Flag (⇧⌘L) | Clears the flag if any selected message is flagged, else flags red |
| Flag ▸ colour / Clear Flag | Sets that colour on all; seven colours, red to gray |
| Mark All Messages as Read | Every message the mailbox contains |

- **Next message:** Delete (toolbar, menu bar, Delete key), Archive and Junk from the toolbar or menu bar, the Move
  menu, a drag of exactly the selection, and an invite answer on the selected invite go through `actOnSelection`: afterwards the first still-visible message after
  the last selected one is selected, else the nearest one before it, else nothing. If no selected message was in
  the list (hidden by the unread filter or a search), nothing stays selected that the action took out of the list.
  An action that changes none of the selected messages (Archive in Archive) keeps the selection as it is.
- **No hidden selection:** every delete or move (also from the context menu, a swipe or a drop) takes the selected
  messages it removes from the visible list (or erases) out of the selection. If that was the whole selection, the
  next message is selected by the rule above; otherwise the rest stays selected. A selected message that stays in
  the list stays selected. So a second Delete can never erase a message from Trash that the user didn't see there.
  Read/unread and flag changes don't move the selection.
- An action on Exchange mail that would move it to another account is reverted with the status "Exchange messages
  can't be moved to another account yet".

## Drag and drop

Rows drag as `MessageDrag` (the whole selection if the row is selected). Drop targets are sidebar rows
(`drop(_:on:)`): an account mailbox moves there (local messages also across accounts; Exchange mail is refused for
another account); Flagged flags unflagged ones red; All Inboxes moves each message to its own account's Inbox; VIPs
and Unread refuse drops. Messages already in the target, or that the drop wouldn't change (a flagged message in
Trash dropped on Flagged), are left out; when that leaves none, `drop` returns false. Resting on a closed folder for 0.7 s opens it.

## Message view and conversations

- `MessageDetailView.swift`: header (initials avatar, sender name, paperclip menu, flag, date, subject, To and Cc
  names), invite card, body, attachments. Several selected: "N messages selected".
- **Conversations** (Settings ▸ Viewing ▸ "Show messages as conversations", on by default): the selected message and
  every message of the same account with the same `conversationID`, except those in Trash (or a folder inside it), Junk or Drafts, newest
  first, each on its own card. A message from another mailbox than the selected one is labelled "Found in Sent –
  Exchange Mailbox". The view scrolls to the selected card, again after 0.6 s. The list itself is not grouped.
- **Attachments** (`AttachmentsView.swift`): pictures in place, other files as Finder icon with "name (size)".
  Double-click opens, Space opens Quick Look, drag to Finder copies, Control-click: Open Attachment, Open With, Quick
  Look, Save Attachment…, Save to Downloads Folder, View as Icon / View in Place. File ▸ Save Attachments… and Quick
  Look Attachments… (⌘Y). Files are fetched on first open into a temporary "Mail Downloads/<message>/<index>/" folder
  with the quarantine flag; saving never overwrites ("name 2.pdf"). Opening again reuses that file, edits included.
  Save, the save panel, drag-out and Forward use it only while its size and modification date are as written;
  after an app changed it (Preview filling in a form) they fetch the content again into an `Original/` folder beside it.

## Compose

- New Message (⌘N) opens a new compose window each time (as do Reply, Reply All, Forward, also twice for one message) for the first account (the toolbar button: the selected mailbox's or message's account). Fields To, Cc,
  Subject, From picker with more than one account, Message Size when files are attached. Send (⇧⌘D) needs a
  non-empty To; Save Draft (⌘S).
- Reply rules (`draft(_:to:)`). Toolbar, menu bar and context menu go through `loadedDraft`, which first fetches the
  body of a message never opened (a server summary has names without addresses and no text), so the draft has the
  addresses and the quote; without a connection the draft is built from the summary.
  - Subject gets "Re: " or "Fwd: ". A leading prefix of the same kind — `Re:`/`AW:` for replies, `Fwd:`/`Fw:`/`WG:`
    for forwards, any case, with or without one space after the colon — is replaced by it, not stacked. A prefix of
    the other kind stays (`FW: x` → `Re: FW: x`).
  - Body: an attribution line ("On <date>, Name <addr> wrote:"; just "Name" when the address isn't known) or a "Begin forwarded message:" block, then every
    line of the plain-text body (split on any line ending: `\r\n`, `\n`, `\r`) prefixed with "> ", joined with `\n`.
  - Reply: To = the sender's address; when the sender is the account's own address (compared without case), the
    original To addresses instead (each once, mine left out; if none is left, the sender's address). Reply All: To = sender and To addresses, Cc = the original Cc, both minus
    the account address (compared without case); each address once across both fields (compared without case,
    first occurrence kept, so To wins); recipients without an address are left out. Forward: To empty.
- Original attachments: Forward always loads them. Replies follow Edit ▸ Include Attachments With Replies (Never,
  default; Ask: an alert when the window opens; When Adding Recipients: on leaving To/Cc or Return, if an address with
  "@" wasn't on the original; while the original's addresses aren't known, a recipient with the name of one of its
  people counts as on it; Always). Ask and When Adding Recipients work for every reply; Always only for replies
  from the menu bar, since toolbar and context-menu replies don't pass the setting to `draft()`. The Include/Exclude Attachments button adds or removes them by hand. Send and Save are blocked
  while they load. All or none: if the original can't be loaded or one of its files can't be had, nothing is added,
  `loadingOriginal` stays set (Send and Save stay blocked), the status names the files, and the window shows "The
  original attachments couldn't be added." with Try Again and Continue Without Them.
- Attaching: Attach button, File ▸ Attach Files… (⇧⌘A), dropping or pasting files. A folder is sent as "Name.zip".
  Files sit in the text at a U+FFFC mark ([domain-model.md](domain-model.md#draft)); JPEG, PNG and GIF placed in the
  text are sent inline in an HTML body ([rendering.md](rendering.md#html-of-sent-mail)).
- Size: estimated size above the account's MailTips limit shows red "(maximum …)"; Send then asks first (Try
  Sending in Email / Cancel).
- Closing a window with user changes (not the original's files) asks "Save this message as a draft?" (Save / Cancel
  / Don't Save). Invite answers close without asking. `saveDraft` returns false while a forward's original files
  load; the sheet's Save then keeps the window open and saves and closes it once they are in (`closeWhenLoaded`).
- Send on an Exchange account (`isServer`, or one with stored mail) queues `send`, also while it has no password; then
  the status says "“…” waits in the outbox until “…” is signed in again in Settings ▸ Accounts." and it goes out
  once the account is signed in. Without a server the message is added to Sent. Save Draft likewise
  queues `saveDraft` or adds a local Drafts message (with To and Cc). A local Sent or Drafts message without a
  subject, and a draft kept after a failed send, is called "(No Subject)". A draft whose account is no longer set up
  (sample accounts go when signing in) is neither sent nor saved from another account: `send`/`saveDraft` return
  false, the status says "“…” was written from an account that is no longer set up. Choose another one in From.",
  the window stays open, shows it in an alert and shows the From picker even with one account.

## Meeting invites

- `InviteView.swift`: required and optional attendees (first 8 + "N more"), date/time and location, then Accept,
  Tentative and Decline menus (Respond with Comments…, Respond without Comments, Do Not Send a Response) and Propose
  New Time (with Tentative or Decline). The answer given is outlined in the accent colour. A cancellation shows only
  Remove from Calendar.
- Banners: "Please respond." or "You answered: …" (with the proposed time and "the organizer wasn't told"), and a
  yellow conflict note when timed, non-free calendar events overlap (the invite's own entry excluded).
- Next to the text, a day column from the Exchange calendar with overlapping events side by side
  (`DayLayout`), hours from `DayLayout.hours`, the invite's slot hatched; an all-day invite is a hatched row in the
  all-day row instead (its own all-day entry not listed again). A spinner shows until the day is loaded; when it
  can't be (no server, account paused, an error, and no day shown yet), `MailStore.unavailableDays` holds the
  message and the column says "Calendar not available".
- With Comments / Propose open a compose window to the organizer with subject "Accepted: …", "Tentative: …",
  "Declined: …" or "New Time Proposed: …"; its text becomes the comment. A proposal needs both a start and an end
  ("The proposed meeting needs both a start and an end.") and must end after it starts; otherwise nothing is queued.
  If the invite has left the store before Send (deleted by a sync, erased), `send` returns false: the status says
  "Couldn't send “…”: the invitation is no longer in your mailbox.", the window stays open with the comment and
  shows it in an alert.
- Any answer or Remove from Calendar moves the message to Trash locally at once. An invite answered while it is one
  of several selected messages leaves the selection (`keepingSelectionVisible`), so Delete can't erase it unseen.

## Settings, menus, help

- Settings ▸ Accounts: list of accounts; Add Exchange Account (email, `DOMAIN\user`, password, server). Sign In
  checks the credentials with a folder request before saving, stores the password in the Keychain, removes the
  sample accounts (never an account set up in Settings, even without a password) and runs a quick check. Signing in
  with the email, username and server of a saved account reconnects that account instead of adding another. Accounts can't be removed or edited in the app.
- Settings ▸ Viewing: conversations on/off. Settings ▸ Privacy: Download external images — Always, My organisation
  (default), Ask before downloading ([rendering.md](rendering.md)).
- Mailbox ▸ Get New Mail (⇧⌘N). Message ▸ Send (⇧⌘D) in the menu bar is always disabled; the compose toolbar has it.
- Help ▸ What's New opens a window listing `WhatsNew.days` (`Sources/MailModel/WhatsNew.swift`), newest day first.
