# MacExchangeClient

<img src="docs/icon.png" width="128" alt="App icon: a white envelope on a pink rounded square">

A native macOS mail client in SwiftUI. It starts as a faithful replica of the Apple Mail main window, and the goal is to connect it to real mail servers.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/dark.png">
  <img alt="Three-column mail window: mailboxes sidebar, message list, message view" src="docs/screenshots/light.png">
</picture>

> **Status:** reads and changes mail on on-prem Exchange over EWS. Without an account it shows built-in sample messages. See [Roadmap](#roadmap).

## Features

- **Exchange accounts over EWS:** sign in under Settings ▸ Accounts with email, `DOMAIN\user`, password and server, as in iOS Mail. Inbox, Drafts, Sent, Junk, Deleted Items and Archive are synced, and so are your own mail folders and subfolders. What you look at drives the order, as described under [How mail is fetched](#how-mail-is-fetched). The password is kept in the Keychain. If it is missing there, the account and its mail stay, the status says the password is needed, and changes wait; signing in again with the same email, username and server connects the same account.

- **Meeting invites, as in Outlook:** for each invite you see:
  - when and where, with the required and optional attendees;
  - Accept, Tentative and Decline menus, as in Outlook: Respond with Comments, Respond without Comments, or Do Not Send a Response (only the calendar changes). With Comments opens a message window to the organizer, with the subject Exchange will use ("Declined: …"); its text becomes the comment;
  - Propose New Time, together with Tentative or Decline, in the same message window with a new start and end;
  - an answered invite moves to Trash right away, as Exchange will do, and the next message is selected;
  - "Please respond" until you have answered, and a yellow note when the meeting overlaps other events;
  - the invite's day from your Exchange calendar next to the text, with overlapping events side by side and the invite's slot hatched (an all-day invite in the all-day row; "Calendar not available" when the calendar can't be read);
  - a cancellation ("Canceled:" / "Abgesagt:") offers only Remove from Calendar, as in Outlook: the meeting leaves the calendar (nobody is told) and the message moves to Trash;
  - invitations and cancellations you sent yourself (in Sent, or from your own address) show no answer buttons, as in Outlook.

  Attendee answer icons are missing: your copy of an invite reports every attendee's answer as unknown.
- **HTML mail:** shown as the sender laid it out, on a white page also in dark mode unless the mail colours its own page (`<body bgcolor text>` apply, as in Mail). Mail without its own fonts uses Mail's default, Helvetica 14, with Mail's margins. Quotes from Apple Mail and iPhone (`<blockquote type="cite">`) get Mail's quote bar, as in Mail's MUIWebDocument.css (⚠️ the bar and text colours of the three levels are recalled, not read: Mail fills them in at run time). Images, styles and fonts from the web follow Outlook's "Download external images" (Settings ▸ Privacy): by default they load for senders in your organisation (your account's mail domain and its subdomains). Other mail shows Load Remote Content first, so opening it doesn't tell the sender; until then the mail's `<link>` elements are disabled too, since WebKit opens connections for hints like `preconnect` despite the content policy. Images load straight from the sender's server, with no privacy relay like Mail's. The app runs no JavaScript in mail, and links open in your browser. Images attached to the message and shown in its text (`cid:`, such as signature logos) load from Exchange when you open the message; they are kept in memory only, not in the cache. As in Mail, the body appears once it has loaded, together with these images, never first as plain text or without its pictures; a spinner shows if that takes longer than 0.4s. The list, search and replies use the plain-text version, which Exchange sends along
- **Conversations:** a message shows with the rest of its Exchange conversation (`ConversationId`): replies, forwards and what you sent, from every mailbox of the account except Trash (and folders inside it), Junk and Drafts, newest first, each on its own card. Messages from another mailbox say where they were found ("Found in Sent – Work Mailbox"). Turn it off under Settings ▸ Viewing to see each message by itself. The list itself is not grouped. A database from before conversations, and mail imported from the old Cache.json, syncs every folder once more from the start so existing mail learns its conversation; local IDs, bodies and flag colours are kept. Once a folder's sync from the start is complete, mail it no longer lists (deleted or moved elsewhere meanwhile) is removed here too, except mail with a change still waiting to be sent, which goes once that change is done. Replies and forwards written in this app are sent as new messages without `In-Reply-To`/`References`, so whether Exchange puts them in the original's conversation is up to the server
- **Attachments, as in Mail:** shown below the text. Pictures appear in place, other files as their Finder icon with name and size. Double-click opens a file. Space shows Quick Look, and dragging to the Finder saves a copy. Control-click gives Mail's menu: Open Attachment, Open With, Quick Look Attachment, Save Attachment…, Save to Downloads Folder, and View as Icon / View in Place for pictures. The paperclip in the header shows the count; its menu saves one file or all of them, or opens Quick Look. File ▸ Save Attachments… asks for a folder, and File ▸ Quick Look Attachments… (⌘Y) shows them all. Content loads from Exchange only when you open a file. It goes to a temporary "Mail Downloads" folder, not the cache. If you change an opened file there (a form filled in with Preview), opening it again shows your copy, but saving, dragging out and forwarding use the file as it came in the mail. An attached message opens as a `.eml` file, and a link to a cloud file (OneDrive, SharePoint) as a web location that opens the link in the browser. Saving never replaces a file: a second copy becomes "name 2.pdf".
- **Three-column window** with a mailboxes sidebar, a message list and a message view, using Mail's toolbar layout and SF Symbols
- **Favorites and smart mailboxes:** All Inboxes, VIPs, Flagged, Unread, then each account's Inbox, Drafts, Sent, Junk, Trash and Archive, with unread badges
- **Folder trees, as in Mail:** each account's own folders follow its standard mailboxes, sorted by name. Subfolders sit under their parent (for example Inbox ▸ Projects ▸ Launch), behind a disclosure triangle. With more than one account, Favorites ▸ All Inboxes opens into each account's Inbox. Folders are move and drop targets, and the Move menu lists them indented under their parent. From Exchange you get every mail folder below the mailbox root (read 1000 at a time, Exchange's limit per request), without calendar, contacts, tasks, Outbox and hidden folders. The folder list is read once per launch, so a folder created elsewhere shows up after a relaunch. Mail in a subfolder of Inbox doesn't count towards All Inboxes, as in Mail
- **Message actions:** reply, reply all, forward, archive, delete, junk, flag in seven colours, mark read or unread. After an action the next message is selected, as in Mail; a message that leaves the list (also by swipe or context menu, or by Mark as Read or Clear Flag while only unread or flagged mail is shown) never stays selected, so a second Delete can't erase it from Trash unseen
- **Drag & drop:** drag messages onto a mailbox to move them, also to another account. Resting on a closed mailbox for a moment opens it, so its subfolders can be reached. Drop them on Flagged to flag them, or on All Inboxes to put each back in its own Inbox
- **Search** across the whole account (not Trash, folders inside Trash, or Junk), plus an unread filter. Like Mail and Outlook it matches the start of words: `meet` finds "meeting", `eting` doesn't. Every word you type must match, in any of subject, sender, To, Cc, the server's preview or a loaded body. Case and accents don't matter (`muller` finds "Müller"), and `gartner` finds `till.gartner@…`. Exchange mail is searched in the database's full-text index, off the main thread, 150 ms after you stop typing; results show the newest 2,000 hits. Sample data search memory, and so does every launch until all stored mail has loaded (and, on the first launch after the update, the index is built), with the same rules except that a word may also match inside a word
- **Compose window** with reply quoting, Send and Save Draft. To and Cc take recipients separated by commas or semicolons, as Outlook writes them; a name with a comma in it, quoted (`"Doe, John" <john@x.com>`) or not (`Doe, John <john@x.com>`), stays one recipient. Closing a message you changed without sending it asks first, with Mail's sheet: "Save this message as a draft?" (Save / Don't Save / Cancel). Save while a forward's original files are still loading keeps the window open and saves and closes it once they are in. Files that come from the original by themselves don't count as a change, and an invite answer closes without asking. Quitting the app doesn't ask yet
- **Attaching files:** Attach (paperclip) in the compose toolbar, File ▸ Attach Files… (⇧⌘A), or drop files on the window, the text included (Finder files, and pictures from Photos as file promises). A folder goes as a zip of it (Folder.zip). A Finder alias goes as the file or folder it points to. Files sit in the text, as in Mail: pictures shown in place (scaled to the window width), other files as their icon with name and size. Drop them where you want them (while dragging, a caret shows where they will go, as in Mail), drag them to another place, cut and paste them, or delete them like a character. Attach and ⇧⌘A put files at the insertion point, the original's files go at the end. Pictures placed in the text go out in their place: the message is then sent as HTML (a `<div>` per line, as Mail writes it) with the pictures as inline attachments it references by `cid:`. Other files are ordinary attachments, so recipients see them in the attachment list, not at their place in the text (Exchange's HTML body can only place pictures). Only JPEG, PNG and GIF go inline; other picture types (HEIC from an iPhone, TIFF) show in place while composing but go as ordinary attachments, since many clients can't draw them. Without pictures in the text the message stays plain text. Forward takes the original's attachments along. Replies follow Edit ▸ Include Attachments With Replies: Never (the default here), Ask, When Adding Recipients (once you leave To/Cc, or press Return, with someone added who wasn't on the original) or Always. The Include/Exclude Attachments button in the compose toolbar adds or removes the original's files by hand. The header shows the Message Size once files are attached, in red with "(maximum …)" when it is over the limit Exchange reports for the account (MailTips). Sending over the limit asks first (Try Sending in Email / Cancel). Mail Drop isn't possible: it uploads to iCloud and needs an Apple Account sign-in, and there is no public API for other apps. On Exchange a message with files is saved in Drafts, the files are added, and then it is sent (the order Microsoft documents for EWS). A forward can't be sent until the original's files have loaded; if they can't be, the window says so and offers Try Again or Continue Without Them.
- **Pull to refresh:** pull the message list down past its top (the bounce) to check for new mail in the Inbox and the mailbox on screen, as Get New Mail (⇧⌘N) does. A spinner shows above the list until the check is done. Short lists bounce too, as in Mail
- **Swipe actions:** swipe right for Unread, left for Trash or Flag
- **Menu bar and shortcuts** taken from Mail's own `MainMenu.nib`
- **Help ▸ What's New:** a window with the change log, a date and what was added that day, in plain words. There is no help book, so Help has no "MailReplica Help" item
- **Light and dark mode**
- **Own app icon:** Mail's envelope icon in pink, drawn in code (`AppIcon.swift`). `MAIL_ICON_EXPORT=icon.png` writes it as a PNG. `run.sh` wraps the build in `MailReplica.app` with that icon, so Activity Monitor and system dialogs show it too

## Getting started

You need macOS 14 or later and Swift 6. Command Line Tools are enough; Xcode is not needed.

```sh
git clone https://github.com/tillg/MacExchangeClient.git
cd MacExchangeClient
./run.sh          # build and launch .build/MailReplica.app
./run.sh build    # build only (the bare binary and the .app)
./run.sh test     # run the model tests
```

Each `./run.sh` build counts the build number one up (kept in `.build-number`, not in git). About MailReplica shows it as “Version 0.1 (N)”, with the build time below.


<details>
<summary>Why <code>run.sh</code> and not <code>swift run</code>?</summary>

In the macOS 27 SDK, `@State` is a macro whose plugin (`SwiftUIMacros`) ships only with Xcode. So `run.sh` builds the app against the macOS 26.5 SDK. The tests use the default SDK, because the Swift Testing macros live there, and get their own build folder (`.build/tests`) so the two setups don't spoil each other's cache. With Xcode installed, `swift run` works as is.
</details>

### Connecting to Exchange

Open Settings (⌘,) ▸ Accounts and sign in. The server can be a host name (`mail.example.com`, expanded to `https://mail.example.com/EWS/Exchange.asmx`) or a full EWS URL. Spaces and line breaks around it and a trailing `/` don't matter, and `http://` is changed to `https://`, so the password never travels unencrypted. The app checks the credentials before saving anything.

Changes to Exchange mail show at once and are then written to the server in order: read state (without sending read receipts), flags, moves (Archive, Junk, Trash, drag & drop), deleting from Trash (recoverable on the server, like Outlook), Send and Save Draft.
- Exchange knows only *flagged*, so flag colours stay on this Mac.
- If the server refuses a change, it is undone and the reason shows under the window title until another notice replaces it. A successful check clears only a notice about that account's own connection (its failed check, offline, busy). When it refuses only some of the messages in a change (one was deleted there meanwhile), only those are undone; erasing a message that is already gone counts as done.
- Offline, changes wait until the next refresh. When only one account's server can't be reached, only that account's changes wait; the others go out. The same holds when Exchange is busy (it asks to wait, and your changes aren't sent again before then) or something in between answers with an error page instead of Exchange. A message that fails to send is never resent automatically. It is kept in Drafts on this Mac instead, with its attachments, also after a relaunch. A send that was on its way when the app quit or crashed isn't sent again either: at the next launch it is kept in Drafts, and the status asks you to check Sent.
- Exchange messages can't be dragged to another account yet.

Exchange mail, sync positions, the folder tree and unsent changes are kept in a SQLite database, `~/Library/Application Support/MailReplica/Mail.sqlite`, readable only by you. There is one row per message, like Mail's Envelope Index, so:

- **Launch:** the Inboxes load first and show at once, about 0.1s for 2,870 messages. The other mailboxes follow in the background, about 4s for 180,000 messages on a busy machine, while “Loading Mail…” shows in the sidebar. The Inbox is checked with the server meanwhile. Other mailboxes are synced only once their mail is in memory, and changes waiting for Exchange go out after that.
- **Saving:** changes are written every 15 seconds and on quit, off the main thread, only what changed: one flag change is one row, a few milliseconds.
- **Upgrading:** the first launch with the database moves the old `Cache.json` into it, which takes a while for a big cache (31s for 180,000 messages on a busy machine). The sidebar shows “Updating Mail Storage…” meanwhile. The database is built under a temporary name and gets its real name only once the count matches. Quit midway, and the next launch imports again. Afterwards the old file is renamed to `Cache.json.imported` (`Cache.json.imported-2` if that name is taken); delete it once you're happy. A `Cache.json` that can't be read is renamed to `Cache.json.unreadable` instead (never deleted), the database starts empty and mail is downloaded again from the server. To go back, delete `Mail.sqlite*` and rename `Cache.json.imported` to `Cache.json`.

- **Search index:** an SQLite FTS5 index over subject, sender, To, Cc, preview and body, updated with each write. The first launch after the update builds it after the Inbox has loaded (about 1.3s for 180,000 messages; it adds about 57 MB to a 164 MB database). Since mail is saved every 15 seconds, mail that arrived or changed in the last 15 seconds may be missing from search until the next save; the search runs again after each save. Hits are checked against memory, so a message you just deleted or moved leaves the results at once.

Messages are still all held in memory, and the list and counts work on that, as before. Search asks the index for matching IDs and shows those messages as they are in memory. Sample data is never stored. Delete `Mail.sqlite` (and its `-wal` and `-shm` files) to start fresh.

`MAIL_SAMPLE_DATA=1 ./run.sh` shows the sample data even when an account is set up.

**Keychain prompt after every build:** `run.sh` signs with your "Apple Development" certificate when there is one. It has a Team ID, so after one "Always Allow" the Keychain recognises every later build and stops asking for the Exchange password. Without it, it falls back to the self-signed "MailReplica Dev" from `./make-signing-identity.sh` (or ad hoc), and then each new build asks once: a certificate without a Team ID gives the Keychain nothing stable to recognise. To get the certificate without a paid account: install Xcode once (`xcodes install 27.2 --experimental-unxip --empty-trash`; don't select it, the build uses the Command Line Tools), add your Apple ID under Settings ▸ Accounts, then Manage Certificates… ▸ + ▸ Apple Development. Xcode can be deleted afterwards; the certificate stays in the keychain.

### How mail is fetched

What's on screen comes first:

1. **Quick check:** every 15 seconds, and at once when you select a mailbox. It covers only the Inbox and the selected mailbox. A fully synced folder is asked only for changes, one small request of about 0.05s. If Exchange no longer accepts the folder's sync position (`ErrorInvalidSyncStateData`, e.g. after a mailbox move), the folder syncs once more from the start. A folder still syncing gets its newest 50 messages, about 0.1s.
2. **Bodies:** loaded when you open a message.
3. **History, in the background:** first the newest 200 messages of every folder. Then each folder's full contents, one page of 512 at a time. The selected mailbox goes first, your own folders come after the standard ones, and Sent comes last. While it runs, the sidebar shows "Synchronizing “Exchange”" with a progress bar based on the server's message counts. It never holds up the quick check.

4. **Folders not on screen:** once history is done, fully synced folders are also asked for changes, one small request each.

If Exchange rejects the password, the app stops sending requests for that account until you relaunch, because repeated wrong passwords lock domain accounts. A folder whose history fails is skipped, and the error stays under the window title. While one account's server can't be reached, its history waits for the next check and the other accounts' history and checks go on.

A change you made that hasn't reached the server yet is kept when a sync reports the old state. Sidebar counts and the message list are computed once per change, so a mailbox with 70,000 messages stays smooth.

### Keyboard shortcuts

| Action | Keys | | Action | Keys |
|---|---|---|---|---|
| New message | ⌘N | | Archive | ⌃⌘A |
| Get Mail | ⇧⌘N | | Delete | ⌘⌫ |
| Reply | ⌘R | | Junk | ⇧⌘J |
| Reply All | ⇧⌘R | | Read / Unread | ⇧⌘U |
| Forward | ⇧⌘F | | Toggle flag | ⇧⌘L |
| Send | ⇧⌘D | | Unread filter | ⌘L |
| Attach files | ⇧⌘A | | Quick Look attachments | ⌘Y |
| Quick Look one attachment | Space | | | |
| Go to mailbox | ⌘1–9 | | | |

## Project layout

```
Sources/
  MailModel/        MailStore (@MainActor @Observable), the models, MailDatabase (SQLite), the drag payload and the MailBackend protocol
  EWS/              MailBackend over Exchange Web Services, Keychain and account settings
  MailReplica/      SwiftUI views, MailCommands (menu bar), DebugSnapshot
Tests/
  MailModelTests/   Swift Testing suites for MailStore, the database, the drag payload and EWS requests and parsing (139 tests, plus live tests against a real server)
docs/screenshots/   README images
run.sh              build / launch / test
```

Views stay thin. Every action is a method on `MailStore`, and each one has a test.

`MailStore` talks to servers only through the `MailBackend` protocol: folders, newest messages, sync with an opaque token, and message bodies. EWS is one implementation; Microsoft Graph will be another, with the token holding a Graph delta link. The data store doesn't change.

The live EWS tests run only with `EWS_USER` (`DOMAIN\user`) and `EWS_SERVER` set and the password in the Keychain (service `MailReplica-EWS`, account = username). Otherwise they are skipped. The read test only reads. The write test also needs `EWS_WRITE_TEST=1`. It works only inside the folder `MailReplica-Test` (created if missing), on a message it creates there itself, and never sends mail. `EWS_DEBUG=1` logs which sign-in method was used. `EWS_PROBE=1` lists which fields a real invite carries, never values. `EWS_TIMING=1` prints read-only timings and folder sizes, never mail content. `MAIL_CACHE_PROBE=1` times loading your real `Cache.json` and moving a copy of it into SQLite, and prints only sizes and counts. `MAIL_BENCH=/path/copy.sqlite` times launch, building the search index, search and saving on a copy of the database (make it with `sqlite3 "file:…/Mail.sqlite?mode=ro" "VACUUM INTO '/path/copy.sqlite'"`; the copy is changed), and prints only timings and counts. Built with `-Xswiftc -DBENCH_OLD` in a worktree of an older commit, the same file times the version before search. Run the live tests on their own (`--filter EWSLive`): the performance tests hold the main thread and would skew their timings.

### Screenshots without screen recording

The app can save a PNG of its window and quit. This checks the UI without screen-recording permission:

```sh
MAIL_SNAPSHOT=$PWD/tmp/snap.png .build/debug/MailReplica
MAIL_SNAPSHOT=$PWD/tmp/snap-dark.png MAIL_SNAPSHOT_DARK=1 .build/debug/MailReplica
```

`MAIL_SNAPSHOT_SUBJECT="Q4 numbers review"` selects a message by subject (here the sample invite); `"30% off everything this weekend 🌊"` is the sample HTML newsletter. HTML bodies are drawn into the PNG once they have loaded. `MAIL_SNAPSHOT_HTML=mail.html` shows that file as the selected message's HTML body, to check how a particular mail renders. `MAIL_SNAPSHOT_ANSWER=decline` (or `accept`, `tentative`, `propose`) opens the answer window for the selected invite and captures that window. `MAIL_SNAPSHOT_PROGRESS=0.3` shows the progress bar. `MAIL_SNAPSHOT_PULL=1` acts as if the message list had been pulled down, to show the refresh spinner (AppKit doesn't bounce for made-up scroll events, so the pull itself can't be acted out). `MAIL_SNAPSHOT_SIZE=1280x800` sets the window size first; the README screenshots use it, scaled to 1× with `sips -Z 1280`. `MAIL_SNAPSHOT_DROP=a.jpg:b.txt` (with `MAIL_SNAPSHOT_ANSWER=forward`) drops those files onto the message text through a real pasteboard, at character `MAIL_SNAPSHOT_DROP_AT` (default 0). `MAIL_SNAPSHOT_EDIT=move` then cuts the first file and pastes it at the end (through RTFD), `delete` deletes it; both print the files the text holds afterwards. `MAIL_SNAPSHOT_DRAG_AT=8` points a file drag at character 8 through the same code as the pointer, captures the drop caret and checks its pixels (prints `DRAG ok` or `DRAG FAILED`). `MAIL_SNAPSHOT_CLOSE=1` closes the opened window as its close button does and prints whether it asked; `MAIL_SNAPSHOT_CLOSE=Save` (or `Don’t Save`, `Cancel`) then clicks that button and prints whether the window closed and the number of drafts before and after. Use `MAIL_SAMPLE_DATA=1` so no real mail ends up in a screenshot.

## How faithful is it?

The details come from Mail.app's own resources in `/System/Applications/Mail.app/Contents/Resources`: nibs, `MainWindow.toolbar` and `*.loctable`.

✅ read from the bundle · ⚠️ estimated

| Area | What the replica does | Source |
|---|---|---|
| Window | Sidebar, message list, message view | ✅ nibs `MailboxesViewController`, `MessageListListLayoutViewController`, `MessageViewController` |
| Toolbar | toggle sidebar · back/forward · filter · view options · compose ‖ reply/reply all/forward · archive/delete/junk · move · flag ‖ search | ✅ `MainWindow.toolbar` default set and SF Symbol names |
| Sidebar | Favorites, Smart Mailboxes, per-account mailboxes, badges | ✅ `Sidebar*.icns` names · ⚠️ badge rules |
| Folder tree | Own folders after the standard ones, by name; subfolders behind disclosure triangles, closed at launch; a closed folder shows only its own count; All Inboxes opens into one Inbox per account | ⚠️ from memory of Mail, not read from the bundle |
| Flags | Red, Orange, Yellow, Green, Blue, Purple, Gray | ✅ `MainMenu.nib` |
| Shortcuts | See table above | ✅ `MainMenu.nib` key equivalents |
| Attachments | Context menu items and order; File ▸ Save Attachments…, Quick Look Attachments… ⌘Y; "name (size)" | ✅ `ViewAttachmentContextMenu.nib`, `MainMenu.nib`, `Localizable.loctable` |
| Compose attachments | Attach button, paperclip and tooltip; Attach Files… ⇧⌘A | ✅ `ComposeWindow.toolbar`, `Localizable.loctable`, `MainMenu.nib` |
| Compose attachment layout | Files in the text where dropped (Mail's Edit ▸ Attachments ▸ Insert Attachments at End is in `MainMenu.nib`; off by default, from memory); forward includes attachments | ✅ menu item; ⚠️ Attach inserting at the insertion point and the original's files at the end, icon look; the sent HTML (`<div>` per line, body style) from memory of Mail's output; non-picture files not placed in the sent mail |
| Replies and size | Include Attachments With Replies (Never/Ask/When Adding Recipients/Always), Include/Exclude Attachments button, "Message Size:", "%@ (maximum %@)", the Try Sending in Email button | ✅ `MainMenu.nib`, `ComposeWindow.toolbar`, `ComposeViewControllerWK2.loctable`, `Compose.loctable` · ⚠️ default Never, the Ask dialog's wording, the over-limit alert's title and text, folders as zip, the size estimate |
| Attachment layout | Pictures in place, other files as icons below the text; the header paperclip with count and its menu; Space, drag-out and double-click; the "name 2" rule for duplicates | ⚠️ Apple's Mail User Guide and memory of Mail, not read from the bundle |
| List row | Unread dot (a star for VIPs, in the same column), bold sender, relative date, subject, 2-line preview, flag, paperclip, optional contact photo | ⚠️ drawn in code · ⚠️ fonts 13 pt sender, 12 pt subject, preview and date (not checked against Mail) |
| Behaviour | Marked read when shown (with the unread filter or in Unread it stays in the list until the selection moves on); Delete goes to the account's Trash and deleting from Trash erases; Junk toggles; next message selected after an action; drag & drop as described above | ⚠️ tested in `MailStoreTests` |

## Roadmap

- [x] Main window, actions, compose, shortcuts
- [x] Drag & drop between mailboxes and accounts
- [x] `MailBackend` protocol under `MailStore`
- [x] Reading mail from on-prem Exchange over EWS
- [x] Flags, read state, moves, deletes and sending written back to Exchange
- [ ] Push for new mail (EWS notifications) instead of the 15-second quick check
- [x] Local cache on disk, so a launch doesn't sync everything again
- [x] HTML message view
- [x] Inline images in HTML mail
- [x] Opening attachments
- [x] Adding attachments to new mail
- [x] Pictures keep their place in the sent mail (HTML body with inline pictures)
- [x] Custom folders and subfolders, as a tree
- [ ] Microsoft Graph backend, once the mailbox is reachable there

**Not planned for now:** mail categories (removed: not used here), rules, conversation threading, rich-text compose, Remind Me, Follow Up, Mute, and the separate message window on double-click.
